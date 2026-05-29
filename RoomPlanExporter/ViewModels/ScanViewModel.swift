import Foundation
import RoomPlan
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
    case optimized(CapturedRoom, [OptimizedObject])                   // 최적화 완료 – 결과 비교
    case inquiry                                                      // 확인 코드 입력
    case inquiryLoading(confirmCode: String)                          // 공간 조회 중
    case inquiryResult(ScanDetail)                                    // 조회 / 최적화 완료 결과
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
                print("📁 [1/5] 로컬 저장 시작")
                let (folderURL, modelFilenames, usdzExists) = try saveRoomData(room: room)
                print("📁 [1/5] 로컬 저장 완료 – 모델 \(modelFilenames.count)개, USDZ=\(usdzExists)")

                // 2. 업로드 세션 시작
                print("🌐 [2/5] 업로드 세션 시작 (includeRoomUsdz=\(usdzExists))")
                let startResp = try await optimizer.startScanUpload(
                    modelFilenames: modelFilenames,
                    includeRoomUsdz: usdzExists
                )
                let confirmCode = startResp.confirmCode
                print("🌐 [2/5] 세션 시작 완료 – confirmCode=\(confirmCode), 슬롯 \(startResp.uploads.count)개")

                // 3. 각 슬롯 파일을 S3에 PUT
                var uploadedKeys: [String] = []
                for (i, slot) in startResp.uploads.enumerated() {
                    print("☁️ [3/5] S3 업로드 [\(i+1)/\(startResp.uploads.count)] \(slot.logicalName)")
                    let data = try readFileData(logicalName: slot.logicalName, folderURL: folderURL)
                    try await optimizer.uploadFileToS3(
                        presignedURL: slot.presignedURL,
                        data: data,
                        contentType: slot.contentType
                    )
                    uploadedKeys.append(slot.s3Key)
                    print("☁️ [3/5] 업로드 완료 \(slot.logicalName) (\(data.count) bytes)")
                }

                // 4. complete → origin 버전 확정 (pipeline은 사용자가 버튼으로 직접 요청)
                print("✅ [4/5] complete 호출 – confirmCode=\(confirmCode)")
                let completeResp = try await optimizer.completeScanUpload(
                    confirmCode: confirmCode,
                    uploadedKeys: uploadedKeys
                )
                print("✅ [4/5] complete 완료 – pipelineStarted=\(completeResp.pipelineStarted) (최적화는 버튼으로 요청)")

                // 최적화 버튼을 위해 키 보관
                pendingConfirmCode   = confirmCode
                pendingUploadedKeys  = uploadedKeys

                // 5. UploadCompleteView로 이동 (확인 코드 표시 + 최적화 버튼 제공)
                print("🎉 [5/5] 업로드 완료 → UploadCompleteView")
                phase = .uploadComplete(room, confirmCode: confirmCode)

            } catch {
                print("❌ 업로드 실패 (\(type(of: error))): \(error)")
                phase = .result(room)
            }
        }
    }

    /// logical_name → 실제 파일 Data 매핑
    private func readFileData(logicalName: String, folderURL: URL) throws -> Data {
        let fileURL: URL
        switch logicalName {
        case "room_data_json":
            fileURL = folderURL.appending(path: "room_data.json")
        case "room_usdz":
            fileURL = folderURL.appending(path: "Room.usdz")
        default:
            // "model_chair_01.usdc" → "Models/chair_01.usdc"
            if logicalName.hasPrefix("model_") {
                let filename = String(logicalName.dropFirst("model_".count))
                fileURL = folderURL.appending(path: "Models/\(filename)")
            } else {
                throw OptimizerError.invalidResponse
            }
        }
        return try Data(contentsOf: fileURL)
    }

    /// /versions 폴링 → "optimized" 버전이 나타나면 완료 (5초 간격, 최대 5분)
    private func pollUntilComplete(confirmCode: String) async throws {
        for attempt in 1...60 {
            try await Task.sleep(for: .seconds(5))
            let detail = try await optimizer.fetchRoomVersions(confirmCode: confirmCode)
            print("⏳ 폴링 \(attempt)/60 – 버전: \(detail.versions.map(\.versionType))")
            if detail.versions.contains(where: { $0.versionType == "optimized" }) {
                return  // optimized 버전 등장 → 완료
            }
        }
        throw OptimizerError.timeout
    }

    /// GET /rooms/{code}/optimized → data_url JSON → OptimizedObject 배열
    private func fetchOptimizedObjects(confirmCode: String) async throws -> [OptimizedObject] {
        let versionDetail = try await optimizer.fetchVersionDetail(
            confirmCode: confirmCode,
            versionType: "optimized"
        )
        guard let dataURLStr = versionDetail.dataUrl,
              let dataURL = URL(string: dataURLStr) else { return [] }

        let (jsonData, _) = try await URLSession.shared.data(from: dataURL)
        let payload = try JSONDecoder().decode(RoomDataPayload.self, from: jsonData)

        return payload.objects.compactMap { obj -> OptimizedObject? in
            guard let matrix = obj.simdTransform,
                  let identifier = UUID(uuidString: obj.identifier) else { return nil }
            return OptimizedObject(
                identifier: identifier,
                category:   obj.category,
                center:     SIMD3(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z),
                rotation:   simd_quatf(matrix)
            )
        }
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

                // 3. 서버 optimized JSON → OptimizedObject 배열 파싱 → OptimizedResultView
                let objects = try await fetchOptimizedObjects(confirmCode: confirmCode)
                print("📦 최적화 오브젝트 \(objects.count)개 – OptimizedResultView로 이동")
                phase = .optimized(room, objects)

            } catch {
                print("❌ 최적화 요청 실패: \(error)")
                // 에러 시 UploadCompleteView로 복귀
                phase = .uploadComplete(room, confirmCode: confirmCode)
            }
        }
    }

    // MARK: Room Data Export

    /// 로컬 임시 폴더에 스캔 데이터 저장
    /// - returns: (폴더 URL, 복사된 모델 파일명 목록, Room.usdz 생성 여부)
    private func saveRoomData(room: CapturedRoom) throws -> (folderURL: URL, modelFilenames: [String], usdzExists: Bool) {
        let fm = FileManager.default
        let ts = Int(Date().timeIntervalSince1970)
        let exportFolder = URL(filePath: NSTemporaryDirectory()).appending(path: "ScanExport_\(ts)")
        let modelsFolder = exportFolder.appending(path: "Models")

        try fm.createDirectory(at: exportFolder, withIntermediateDirectories: true)
        try fm.createDirectory(at: modelsFolder, withIntermediateDirectories: true)

        let mp = try? CapturedRoom.ModelProvider.load()
        var copiedModels: [String: String] = [:]
        var modelFilenames: [String] = []

        if let mp {
            for obj in room.objects {
                guard let src = try? mp.modelFileURL(for: obj) else { continue }
                let filename = src.lastPathComponent
                let dst = modelsFolder.appending(path: filename)
                if !fm.fileExists(atPath: dst.path()) { try? fm.copyItem(at: src, to: dst) }
                copiedModels[obj.identifier.uuidString] = filename
                if !modelFilenames.contains(filename) { modelFilenames.append(filename) }
            }
        }

        let usdzURL = exportFolder.appending(path: "Room.usdz")
        try? room.export(to: usdzURL, modelProvider: mp, exportOptions: [.parametric, .mesh, .model])
        let usdzExists = fm.fileExists(atPath: usdzURL.path())
        if !usdzExists { print("⚠️ Room.usdz 익스포트 실패 – usdz 없이 업로드") }

        let objects = room.objects.map { obj -> FurnitureData in
            let t = obj.transform
            return FurnitureData(
                identifier:    obj.identifier.uuidString,
                category:      String(describing: obj.category),
                modelFileName: copiedModels[obj.identifier.uuidString],
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
            walls:            room.walls.map  { surfaceData($0) },
            floors:           room.floors.map { surfaceData($0) },
            doors:            room.doors.map  { surfaceData($0) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(payload).write(to: exportFolder.appending(path: "room_data.json"))

        return (exportFolder, modelFilenames, usdzExists)
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
    let walls, floors, doors: [SurfaceData]
}
