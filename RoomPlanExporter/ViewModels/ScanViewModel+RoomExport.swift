import Foundation
import RoomPlan
import SceneKit
import UIKit
import simd

// MARK: - RoomPlan 캡처 데이터 → 로컬 JSON/USDZ 익스포트

extension ScanViewModel {

    /// 로컬 임시 폴더에 스캔 데이터 저장
    /// - returns: (폴더 URL, Room.usdz 생성 여부, Room_empty.usdz 생성 여부)
    func saveRoomData(room: CapturedRoom) throws -> (folderURL: URL, usdzExists: Bool, emptyUsdzExists: Bool) {
        let fm = FileManager.default
        let ts = Int(Date().timeIntervalSince1970)
        let exportFolder = URL(filePath: NSTemporaryDirectory()).appending(path: "ScanExport_\(ts)")
        try fm.createDirectory(at: exportFolder, withIntermediateDirectories: true)

        let mp = try? CapturedRoom.ModelProvider.load()

        let usdzURL = exportFolder.appending(path: "Room.usdz")
        try? room.export(to: usdzURL, modelProvider: mp, exportOptions: [.parametric, .mesh, .model])
        let usdzExists = fm.fileExists(atPath: usdzURL.path())
        if !usdzExists { print("⚠️ Room.usdz 익스포트 실패 – usdz 없이 업로드") }

        // 빈 방 USDZ: Room.usdz를 SceneKit으로 로드 → 가구 제거 + 문/창문 배경색 처리
        let emptyUsdzURL = exportFolder.appending(path: "Room_empty.usdz")
        if usdzExists {
            makeEmptyUSDZ(from: usdzURL, output: emptyUsdzURL, room: room)
        }
        let emptyUsdzExists = fm.fileExists(atPath: emptyUsdzURL.path())
        print(emptyUsdzExists ? "✅ Room_empty.usdz 생성 완료" : "⚠️ Room_empty.usdz 생성 실패")

        let objects = room.objects.map { obj -> FurnitureData in
            let t = obj.transform
            let modelFileName = (try? mp?.modelFileURL(for: obj))?.lastPathComponent
            return FurnitureData(
                identifier:    obj.identifier.uuidString,
                category:      String(describing: obj.category),
                modelFileName: modelFileName,
                center:        [t.columns.3.x, t.columns.3.y, t.columns.3.z],
                dimensions:    [obj.dimensions.x, obj.dimensions.y, obj.dimensions.z],
                frontVector:   [-t.columns.2.x, -t.columns.2.y, -t.columns.2.z],
                backVector:    [ t.columns.2.x,  t.columns.2.y,  t.columns.2.z],
                rightVector:   [ t.columns.0.x,  t.columns.0.y,  t.columns.0.z],
                leftVector:    [-t.columns.0.x, -t.columns.0.y, -t.columns.0.z],
                upVector:      [ t.columns.1.x,  t.columns.1.y,  t.columns.1.z],
                obbVertices:   calcOBBVertices(obj),
                transform:     matrixToArray(t)
            )
        }

        let floorY = room.floors.first?.transform.columns.3.y ?? 0
        let payload = RoomPayload(
            scannedAt:        ISO8601DateFormatter().string(from: Date()),
            coordinateSystem: "RoomPlan (Y-up, meters, floor Y≈\(String(format: "%.2f", floorY))",
            objectCount:      objects.count,
            objects:          objects,
            walls:            room.walls.map   { surfaceData($0) },
            floors:           room.floors.map  { surfaceData($0) },
            doors:            room.doors.map   { surfaceData($0) },
            windows:          room.windows.map { surfaceData($0) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(payload).write(to: exportFolder.appending(path: "room_data.json"))

        return (exportFolder, usdzExists, emptyUsdzExists)
    }

    private func surfaceData(_ s: CapturedRoom.Surface) -> SurfaceData {
        let t = s.transform
        return SurfaceData(
            center:     [t.columns.3.x, t.columns.3.y, t.columns.3.z],
            dimensions: [s.dimensions.x, s.dimensions.y],
            transform:  matrixToArray(t)
        )
    }

    private func calcOBBVertices(_ obj: CapturedRoom.Object) -> [[Float]] {
        let e = obj.dimensions; let t = obj.transform
        let (hx, hy, hz) = (e.x / 2, e.y / 2, e.z / 2)
        let corners: [SIMD4<Float>] = [
            [-hx,-hy,-hz,1],[ hx,-hy,-hz,1],[-hx, hy,-hz,1],[ hx, hy,-hz,1],
            [-hx,-hy, hz,1],[ hx,-hy, hz,1],[-hx, hy, hz,1],[ hx, hy, hz,1]
        ]
        return corners.map { v in let w = t * v; return [w.x, w.y, w.z] }
    }

    private func matrixToArray(_ m: simd_float4x4) -> [[Float]] {
        [
            [m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w],
            [m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w],
            [m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w],
            [m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w]
        ]
    }

    // MARK: - Room_empty.usdz 생성
    // Room.usdz를 SceneKit으로 로드, 가구 노드를 위치/이름으로 제거하고 재저장

    /// Room.usdz → SceneKit: 가구 제거 + 문/창문 배경색(베이지) 재질 교체 → room_empty.usdz 저장.
    /// SceneKit 재저장 시 OcclusionMaterial이 깨져 검정이 되므로, 배경색으로 교체해 뚫린 것처럼 보이게.
    private func makeEmptyUSDZ(from source: URL, output: URL, room: CapturedRoom) {
        guard let scene = try? SCNScene(url: source, options: nil) else {
            print("⚠️ Empty USDZ: SCNScene 로드 실패"); return
        }

        let furnitureCenters: [SIMD3<Float>] = room.objects.map {
            SIMD3($0.transform.columns.3.x, $0.transform.columns.3.y, $0.transform.columns.3.z)
        }

        let structuralKeywords: Set<String> = ["wall", "floor", "ceiling"]
        let doorWindowKeywords: Set<String>  = ["door", "window", "opening"]
        let furnitureKeywords:  Set<String>  = [
            "chair", "table", "sofa", "bed", "storage", "television", "tv",
            "refrigerator", "washer", "dryer", "washerdryer", "toilet", "bathtub",
            "sink", "stove", "oven", "dishwasher", "fireplace", "stairs", "screen", "object"
        ]

        let bgMat: SCNMaterial = {
            let m = SCNMaterial()
            m.diffuse.contents = UIColor(red: 0.96, green: 0.94, blue: 0.90, alpha: 1.0)
            m.lightingModel = .constant
            return m
        }()

        func applyBgMaterial(to node: SCNNode) {
            if node.geometry != nil { node.geometry?.materials = [bgMat] }
            node.childNodes.forEach { applyBgMaterial(to: $0) }
        }

        func process(_ parent: SCNNode) {
            var toRemove: [SCNNode] = []
            for child in parent.childNodes {
                let name = child.name?.lowercased() ?? ""
                if structuralKeywords.contains(where: { name.contains($0) }) {
                    process(child)
                } else if doorWindowKeywords.contains(where: { name.contains($0) }) {
                    applyBgMaterial(to: child)
                    process(child)
                } else if furnitureKeywords.contains(where: { name.contains($0) }) {
                    toRemove.append(child)
                } else {
                    let wp  = child.worldPosition
                    let pos = SIMD3<Float>(Float(wp.x), Float(wp.y), Float(wp.z))
                    let isFurniture = furnitureCenters.contains { fc in
                        let d = pos - fc; return d.x*d.x + d.y*d.y + d.z*d.z < 0.49
                    }
                    if isFurniture { toRemove.append(child) } else { process(child) }
                }
            }
            toRemove.forEach { $0.removeFromParentNode() }
        }

        process(scene.rootNode)
        let ok = scene.write(to: output, options: nil, delegate: nil, progressHandler: nil)
        print(ok ? "✅ Room_empty.usdz 저장 완료" : "⚠️ Room_empty.usdz 저장 실패")
    }
}

// MARK: - Local JSON Models (private)

private struct FurnitureData: Encodable {
    let identifier, category: String
    let modelFileName: String?
    let center, dimensions: [Float]
    let frontVector, backVector, rightVector, leftVector, upVector: [Float]
    let obbVertices: [[Float]]
    let transform: [[Float]]
}

private struct SurfaceData: Encodable {
    let center, dimensions: [Float]
    let transform: [[Float]]
}

private struct RoomPayload: Encodable {
    let scannedAt, coordinateSystem: String
    let objectCount: Int
    let objects: [FurnitureData]
    let walls, floors, doors, windows: [SurfaceData]
}
