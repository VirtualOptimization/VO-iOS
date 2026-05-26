/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
The sample app's primary view.
*/

import SwiftUI
import RoomPlan
import simd

// MARK: - AppState

enum AppState {
    case idle
    case scanning
    case viewing(CapturedRoom)                              // USDZ 보여주기
    case uploading(CapturedRoom)                            // 저장 중
    case readyToOptimize(CapturedRoom, confirmCode: String) // 저장 완료
    case optimizing(CapturedRoom, confirmCode: String)      // 최적화 중
    case optimized(CapturedRoom, [OptimizedObject])         // 최적화 완료
    case error(String)
}

// MARK: - ModelProvider Extension

extension CapturedRoom.ModelProvider {
    enum CatalogError: LocalizedError {
        case cannotFindCatalog
        var errorDescription: String? {
            switch self {
            case .cannotFindCatalog: return "Cannot Find Catalog"
            }
        }
    }
    static func load() throws -> CapturedRoom.ModelProvider {
        guard let catalogURL = Bundle.main.url(forResource: "RoomPlanCatalog", withExtension: "bundle") else {
            throw CatalogError.cannotFindCatalog
        }
        return try RoomPlanCatalog.load(at: catalogURL)
    }
}

// MARK: - ContentView

struct ContentView: View {

    @State private var appState: AppState = .idle
    private let optimizer = RoomOptimizerService()

    // MARK: - Body

    var body: some View {
        switch appState {

        case .idle:
            idleView

        case .scanning:
            RoomCaptureViewControllerRepresentable(
                onFinish: { appState = .viewing($0) },
                onCancel: { appState = .idle }
            )
            .ignoresSafeArea()

        case .error(let msg):
            Text("").alert(msg, isPresented: .constant(true)) {
                Button("확인") { appState = .idle }
            }

        default:
            if let room = currentRoom {
                ZStack(alignment: .topLeading) {
                    RoomViewerView(capturedRoom: room, optimizedObjects: currentOptimizedObjects)

                    // 다시 스캔하기 버튼
                    Button(action: { appState = .idle }) {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                            Text("다시 스캔하기")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                    .padding(.top, 56).padding(.leading, 16)

                    // 확인 코드 뱃지
                    if let code = currentConfirmCode {
                        VStack {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                                Text("코드: \(code)")
                                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.top, 56)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    }

                    // 하단 버튼
                    VStack {
                        Spacer()
                        bottomButtons(room: room).padding(.bottom, 48)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: - 하단 버튼 (상태별)

    @ViewBuilder
    private func bottomButtons(room: CapturedRoom) -> some View {
        switch appState {

        case .viewing:
            Button(action: { saveAndUpload(room: room) }) {
                Label("저장하기", systemImage: "square.and.arrow.up")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 40).padding(.vertical, 16)
                    .background(.green, in: Capsule())
            }

        case .uploading:
            HStack(spacing: 8) {
                ProgressView().tint(.white)
                Text("저장 중...").foregroundStyle(.white).font(.subheadline)
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
            .background(.ultraThinMaterial, in: Capsule())

        case .readyToOptimize(_, let code):
            Button(action: { requestOptimize(room: room, confirmCode: code) }) {
                Label("최적화 요청", systemImage: "sparkles")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 40).padding(.vertical, 16)
                    .background(.blue, in: Capsule())
            }

        case .optimizing:
            HStack(spacing: 8) {
                ProgressView().tint(.white)
                Text("최적화 중...").foregroundStyle(.white).font(.subheadline)
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
            .background(.ultraThinMaterial, in: Capsule())

        case .optimized:
            Label("최적화 완료", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 24).padding(.vertical, 14)
                .background(.ultraThinMaterial, in: Capsule())

        default:
            EmptyView()
        }
    }

    // MARK: - 시작 화면

    var idleView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "camera.metering.matrix")
                .font(.system(size: 60)).foregroundStyle(.blue)
            Text("공간 스캔 & 배치 최적화")
                .font(.title2.weight(.semibold))
            Text("LiDAR로 방을 스캔하면\n가구 배치를 자동으로 최적화해드려요")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button(action: { appState = .scanning }) {
                Label("스캔 시작", systemImage: "camera.fill")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
            .controlSize(.large).padding(.horizontal, 40)
            Spacer()
        }
        .padding()
    }

    // MARK: - AppState 헬퍼

    private var currentRoom: CapturedRoom? {
        switch appState {
        case .viewing(let r):                  return r
        case .uploading(let r):                return r
        case .readyToOptimize(let r, _):       return r
        case .optimizing(let r, _):            return r
        case .optimized(let r, _):             return r
        default:                               return nil
        }
    }

    private var currentOptimizedObjects: [OptimizedObject]? {
        if case .optimized(_, let objs) = appState { return objs }
        return nil
    }

    private var currentConfirmCode: String? {
        switch appState {
        case .readyToOptimize(_, let code): return code
        case .optimizing(_, let code):      return code
        case .optimized:                    return nil  // 최적화 완료 후엔 숨김
        default:                            return nil
        }
    }

    // MARK: - 저장 & 업로드

    private func saveAndUpload(room: CapturedRoom) {
        appState = .uploading(room)
        Task {
            do {
                let folderURL = try saveRoomData(room: room)
                let response = try await optimizer.uploadScanZip(folderURL: folderURL)
                print("✅ 업로드 완료 | confirm_code: \(response.confirmCode)")
                appState = .readyToOptimize(room, confirmCode: response.confirmCode)
            } catch {
                print("❌ 저장 실패: \(error.localizedDescription)")
                appState = .error("저장 실패: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - 최적화 요청

    private func requestOptimize(room: CapturedRoom, confirmCode: String) {
        appState = .optimizing(room, confirmCode: confirmCode)
        Task {
            do {
                let objects = try await optimizer.requestOptimize(confirmCode: confirmCode)
                appState = .optimized(room, objects)
            } catch {
                appState = .error("최적화 실패: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - 로컬 파일 저장

    private func saveRoomData(room: CapturedRoom) throws -> URL {
        let fm = FileManager.default
        let ts = Int(Date().timeIntervalSince1970)
        let exportFolder = URL(filePath: NSTemporaryDirectory()).appending(path: "ScanExport_\(ts)")
        let modelsFolder = exportFolder.appending(path: "Models")

        try fm.createDirectory(at: exportFolder, withIntermediateDirectories: true)
        try fm.createDirectory(at: modelsFolder, withIntermediateDirectories: true)

        // ModelProvider 한 번만 로드
        let mp = try? CapturedRoom.ModelProvider.load()

        // 가구별 usdc 복사
        var copiedModels: [String: String] = [:]
        if let mp {
            for obj in room.objects {
                guard let src = try? mp.modelFileURL(for: obj) else { continue }
                let dst = modelsFolder.appending(path: src.lastPathComponent)
                if !fm.fileExists(atPath: dst.path()) { try? fm.copyItem(at: src, to: dst) }
                copiedModels[obj.identifier.uuidString] = src.lastPathComponent
            }
        }

        // Room.usdz
        let usdzURL = exportFolder.appending(path: "Room.usdz")
        try? room.export(to: usdzURL, modelProvider: mp, exportOptions: [.parametric, .mesh, .model])

        // Room_empty.usdz (가구 제거)
        // CapturedRoom은 Codable을 공식 지원하지 않으므로 실패 시 건너뜀
        let emptyURL = exportFolder.appending(path: "Room_empty.usdz")
        do {
            let data = try JSONEncoder().encode(room)
            if var json = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                json["objects"] = []
                let d2 = try JSONSerialization.data(withJSONObject: json)
                let emptyRoom = try JSONDecoder().decode(CapturedRoom.self, from: d2)
                try emptyRoom.export(to: emptyURL, exportOptions: .parametric)
                print("✅ Room_empty.usdz 저장")
            }
        } catch {
            print("⚠️ Room_empty.usdz 생성 실패: \(error)")
        }

        // room_data.json
        let objects = room.objects.map { obj -> FurnitureData in
            let t = obj.transform
            return FurnitureData(
                identifier:   obj.identifier.uuidString,
                category:     String(describing: obj.category),
                modelFileName: copiedModels[obj.identifier.uuidString],
                center:       [t.columns.3.x, t.columns.3.y, t.columns.3.z],
                dimensions:   [obj.dimensions.x, obj.dimensions.y, obj.dimensions.z],
                frontVector:  [-t.columns.2.x, -t.columns.2.y, -t.columns.2.z],
                backVector:   [ t.columns.2.x,  t.columns.2.y,  t.columns.2.z],
                rightVector:  [ t.columns.0.x,  t.columns.0.y,  t.columns.0.z],
                leftVector:   [-t.columns.0.x, -t.columns.0.y, -t.columns.0.z],
                upVector:     [ t.columns.1.x,  t.columns.1.y,  t.columns.1.z],
                obbVertices:  calcOBBVertices(obj),
                transform:    matrixToArray(t)
            )
        }

        let floorY = room.floors.first?.transform.columns.3.y ?? 0
        let payload = RoomPayload(
            scannedAt:        ISO8601DateFormatter().string(from: Date()),
            coordinateSystem: "RoomPlan (Y-up, meters, floor Y≈\(String(format: "%.2f", floorY))",
            objectCount:      objects.count,
            objects:          objects,
            walls:            room.walls.map  { sdata($0) },
            floors:           room.floors.map { sdata($0) },
            doors:            room.doors.map  { sdata($0) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(payload).write(to: exportFolder.appending(path: "room_data.json"))
        print("✅ room_data.json 저장")

        return exportFolder
    }

    private func sdata(_ s: CapturedRoom.Surface) -> SurfaceData {
        let t = s.transform
        return SurfaceData(
            center:     [t.columns.3.x, t.columns.3.y, t.columns.3.z],
            dimensions: [s.dimensions.x, s.dimensions.y],
            transform:  matrixToArray(t)
        )
    }

    private func calcOBBVertices(_ obj: CapturedRoom.Object) -> [[Float]] {
        let e = obj.dimensions; let t = obj.transform
        let (hx, hy, hz) = (e.x/2, e.y/2, e.z/2)
        let corners: [SIMD4<Float>] = [
            [-hx,-hy,-hz,1],[ hx,-hy,-hz,1],[-hx, hy,-hz,1],[ hx, hy,-hz,1],
            [-hx,-hy, hz,1],[ hx,-hy, hz,1],[-hx, hy, hz,1],[ hx, hy, hz,1]
        ]
        return corners.map { v in let w = t*v; return [w.x, w.y, w.z] }
    }

    private func matrixToArray(_ m: simd_float4x4) -> [[Float]] {
        [
            [m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w],
            [m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w],
            [m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w],
            [m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w]
        ]
    }
}

// MARK: - JSON 모델 (room_data.json 구조)

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
    let walls, floors, doors: [SurfaceData]
}

// MARK: - Preview

struct ContentView_Previews: PreviewProvider {
    static var previews: some View { ContentView() }
}
