import Foundation
import RoomPlan
import SceneKit
import simd

// MARK: - ScanPhase

enum ScanPhase {
    case main
    case guide
    case countdown
    case scanning
    case result(CapturedRoom)                                         // 스캔 완료 – 저장 전
    case uploading(CapturedRoom)                                      // S3 파일 업로드 중
    case uploadComplete(CapturedRoom, confirmCode: String)            // 업로드 완료 – 확인 코드 표시
    case processing(CapturedRoom, confirmCode: String)                // 최적화 파이프라인 폴링 중
    case optimized(CapturedRoom, RoomVersionDetail)                    // 최적화 완료 – 결과 비교
    case inquiry                                                      // 확인 코드 입력
    case inquiryLoading(confirmCode: String)                          // 공간 조회 중
    case inquiryResult(ScanDetail)                                    // 조회 / 최적화 완료 결과
}

extension ScanPhase: Equatable {
    static func == (lhs: ScanPhase, rhs: ScanPhase) -> Bool {
        switch (lhs, rhs) {
        case (.main, .main), (.guide, .guide), (.countdown, .countdown),
             (.scanning, .scanning), (.inquiry, .inquiry): return true
        case (.result, .result), (.uploading, .uploading),
             (.uploadComplete, .uploadComplete), (.processing, .processing),
             (.optimized, .optimized), (.inquiryLoading, .inquiryLoading),
             (.inquiryResult, .inquiryResult): return true
        default: return false
        }
    }
}

// MARK: - ScanViewModel

@MainActor
final class ScanViewModel: ObservableObject {
    @Published var phase: ScanPhase = .main
    @Published var countdownValue: Int = 3
    @Published var isOptimizing: Bool = false   // 최적화 진행 중 여부

    private let optimizer = RoomOptimizerService()

    /// 최적화 요청 시 필요한 S3 키 (새 스캔 후 저장 시 채워짐)
    private(set) var pendingConfirmCode: String? = nil
    private(set) var pendingUploadedKeys: [String] = []

    // MARK: Navigation

    func showGuide() { phase = .guide }

    func startCountdown() {
        countdownValue = 3
        phase = .countdown
        Task {
            for i in stride(from: 3, through: 1, by: -1) {
                countdownValue = i
                try? await Task.sleep(for: .seconds(1))
            }
            phase = .scanning
        }
    }

    func scanCompleted(_ room: CapturedRoom) { phase = .result(room) }
    func retake() {
        pendingConfirmCode = nil
        pendingUploadedKeys = []
        phase = .main
    }
    func showInquiry() { phase = .inquiry }

    func saveAndUpload(room: CapturedRoom) {
        phase = .uploading(room)
        Task {
            do {
                // 1. 로컬 저장
                print("📁 [1/4] 로컬 저장 시작")
                let (folderURL, usdzExists, emptyUsdzExists) = try saveRoomData(room: room)
                print("📁 [1/4] 로컬 저장 완료 – USDZ=\(usdzExists), Empty=\(emptyUsdzExists)")

                // 2. 업로드 세션 시작
                print("🌐 [2/4] 업로드 세션 시작 (includeRoomUsdz=\(usdzExists), includeEmpty=\(emptyUsdzExists))")
                let startResp = try await optimizer.startScanUpload(includeRoomUsdz: usdzExists,
                                                                      includeRoomEmptyUsdz: emptyUsdzExists)
                let confirmCode = startResp.confirmCode
                print("🌐 [2/4] 세션 시작 완료 – confirmCode=\(confirmCode), 슬롯 \(startResp.uploads.count)개")

                // 3. 각 슬롯 파일을 S3에 PUT (room_data_json, room_usdz 두 슬롯)
                var uploadedKeys: [String] = []
                for (i, slot) in startResp.uploads.enumerated() {
                    print("☁️ [3/4] S3 업로드 [\(i+1)/\(startResp.uploads.count)] \(slot.logicalName)")
                    let data = try readFileData(logicalName: slot.logicalName, folderURL: folderURL)
                    try await optimizer.uploadFileToS3(
                        presignedURL: slot.presignedURL,
                        data: data,
                        contentType: slot.contentType
                    )
                    uploadedKeys.append(slot.s3Key)
                    print("☁️ [3/4] 업로드 완료 \(slot.logicalName) (\(data.count) bytes)")
                }

                pendingConfirmCode  = confirmCode
                pendingUploadedKeys = uploadedKeys

                print("🎉 [4/4] 업로드 완료 → UploadCompleteView")
                phase = .uploadComplete(room, confirmCode: confirmCode)

            } catch {
                print("❌ 업로드 실패 (\(type(of: error))): \(error)")
                phase = .result(room)
            }
        }
    }

    /// logical_name → 실제 파일 Data 매핑 (room_data_json, room_usdz 두 슬롯만)
    private func readFileData(logicalName: String, folderURL: URL) throws -> Data {
        let fileURL: URL
        switch logicalName {
        case "room_data_json":  fileURL = folderURL.appending(path: "room_data.json")
        case "room_usdz":       fileURL = folderURL.appending(path: "Room.usdz")
        case "room_empty_usdz": fileURL = folderURL.appending(path: "Room_empty.usdz")
        default:                throw OptimizerError.invalidResponse
        }
        return try Data(contentsOf: fileURL)
    }

    /// GET /rooms/{code}/optimized 폴링 → data_url(normalized.json) 나오면 바로 완료 (5초 간격, 최대 10분)
    private func pollUntilComplete(confirmCode: String) async throws {
        for attempt in 1...120 {
            try await Task.sleep(for: .seconds(5))
            do {
                let detail = try await optimizer.fetchVersionDetail(
                    confirmCode: confirmCode, versionType: "optimized")
                if detail.dataUrl != nil {
                    print("✅ 폴링 \(attempt)/120 – normalized.json 확인됨, GLB 안 기다리고 진행")
                    return
                }
            } catch {
                // 아직 없음 – 계속 폴링
            }
            print("⏳ 폴링 \(attempt)/120 – optimized 아직 없음")
        }
        throw OptimizerError.timeout
    }


    // MARK: Inquiry (공간 조회)

    func fetchByCode(confirmCode: String) {
        let code = confirmCode.trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty else { return }
        phase = .inquiryLoading(confirmCode: code)
        Task {
            do {
                let detail = try await optimizer.fetchRoomVersions(confirmCode: code)
                phase = .inquiryResult(detail)
            } catch {
                print("❌ 조회 실패: \(error)")
                phase = .inquiry
            }
        }
    }

    func deleteVersion(confirmCode: String, versionId: String, from detail: ScanDetail) {
        Task {
            do {
                try await optimizer.deleteVersion(confirmCode: confirmCode, versionId: versionId)
                let updated = ScanDetail(
                    roomId:      nil,
                    confirmCode: detail.confirmCode,
                    createdAt:   detail.createdAt,
                    versions:    detail.versions.filter { $0.versionId != versionId }
                )
                phase = .inquiryResult(updated)
            } catch {
                print("❌ 삭제 실패: \(error)")
            }
        }
    }

    // MARK: 최적화 요청 (UploadCompleteView 버튼)

    /// /complete 호출 → 파이프라인 시작 → 폴링 → 최적화 JSON 파싱 → OptimizedResultView
    func requestOptimization(room: CapturedRoom, confirmCode: String) {
        guard !isOptimizing else { return }
        isOptimizing = true
        // 즉시 로딩 화면으로 전환
        phase = .processing(room, confirmCode: confirmCode)
        Task {
            defer { isOptimizing = false }
            do {
                // 1. POST /api/rooms/{confirmCode}/complete → 파이프라인 트리거
                print("🚀 최적화 요청 – confirmCode=\(confirmCode)")
                let resp = try await optimizer.completeScanUpload(
                    confirmCode: confirmCode,
                    uploadedKeys: pendingUploadedKeys
                )
                print("🚀 pipelineStarted=\(resp.pipelineStarted)")

                // pipelineStarted=false → 파이프라인 미시작 (BE ARN 미설정 등)
                // 폴링해도 optimized가 /versions에 절대 안 뜨므로 즉시 복귀
                guard resp.pipelineStarted else {
                    print("⚠️ pipelineStarted=false – BE의 Step Functions ARN 설정 필요")
                    phase = .uploadComplete(room, confirmCode: confirmCode)
                    return
                }

                // 2. optimized가 /versions에 뜰 때까지 폴링 (5초 간격, 최대 5분)
                print("⏳ 최적화 폴링 시작...")
                try await pollUntilComplete(confirmCode: confirmCode)
                print("✅ 최적화 완료")

                // 3. optimized 버전 상세 → OptimizedResultView (FurnitureRealityKitView가 직접 렌더링)
                let versionDetail = try await optimizer.fetchVersionDetail(
                    confirmCode: confirmCode, versionType: "optimized")
                print("📦 최적화 버전 상세 취득 – OptimizedResultView로 이동")
                phase = .optimized(room, versionDetail)

            } catch {
                print("❌ 최적화 요청 실패: \(error)")
                // 에러 시 UploadCompleteView로 복귀
                phase = .uploadComplete(room, confirmCode: confirmCode)
            }
        }
    }

    // MARK: Room Data Export

    /// 로컬 임시 폴더에 스캔 데이터 저장
    /// - returns: (폴더 URL, Room.usdz 생성 여부, Room_empty.usdz 생성 여부)
    private func saveRoomData(room: CapturedRoom) throws -> (folderURL: URL, usdzExists: Bool, emptyUsdzExists: Bool) {
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
