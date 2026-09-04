import Foundation
import RealityKit
import SceneKit
import UIKit

// MARK: - 가구 캡처 / 저장 / 서버 동기화

extension ScanViewModel {

    /// 서버 목록과 대조해, 다른 곳에서 삭제된 항목의 serverModelId 연결을 정리 (best-effort, 목록 자체는 로컬 기준 유지)
    func syncFurnitureWithServer() {
        guard let accessToken = KeychainTokenStore.get(.accessToken) else { return }
        Task {
            guard let remoteModels = try? await FurnitureModelService().fetchModels(accessToken: accessToken) else { return }
            let remoteIds = Set(remoteModels.map(\.modelId))
            var changed = false
            for idx in savedFurniture.indices {
                if let modelId = savedFurniture[idx].serverModelId, !remoteIds.contains(modelId) {
                    savedFurniture[idx].serverModelId = nil
                    savedFurniture[idx].modelKey = nil
                    changed = true
                }
            }
            if changed { persistFurniture() }
        }
    }

    /// LiDAR 캡처(ObjectCaptureSession) 완료 → 처리 흐름:
    /// 1) PhotogrammetrySession으로 실측 스케일 재구성 — 단, 그 결과물 자체는 쓰지 않고 **치수 측정 용도로만** 사용
    ///    (온디바이스 포토그래메트리 결과물 품질이 들쭉날쭉해서 최종 비주얼로는 안 씀)
    /// 2) 촬영된 사진 중 대표 한 장을 Meshy AI로 보내 깔끔한 비주얼 모델 생성
    /// 3) 1)에서 측정한 실측 치수에 맞게 2)의 결과물을 리스케일
    /// → LiDAR = 정확한 실측, Meshy = 깔끔한 비주얼, 두 장점을 합친 결과물.
    func processLidarScan(imagesDirectory: URL, thumbnail: UIImage) {
        guard PhotogrammetrySession.isSupported else {
            print("❌ PhotogrammetrySession 미지원 기기")
            furnitureProgressText = "이 기기는 3D 변환을 지원하지 않아요"
            return
        }
        phase = .furnitureProcessing(thumbnail)
        // PhotogrammetrySession은 메인 스레드에서 실행하면 크래시 → Task.detached
        furnitureGenerationTask = Task.detached { [weak self] in
            do {
                guard let imageData = Self.representativeImageData(in: imagesDirectory) else {
                    throw FurnitureRescaleError.loadFailed
                }

                // 치수 측정(온디바이스)과 Meshy AI 생성(서버)은 서로 다른 입력을 쓰는 독립적인 작업이라
                // 순차로 기다릴 필요 없이 동시에 진행 — 전체 대기 시간이 둘 중 더 오래 걸리는 쪽으로 줄어듦.
                async let dimsTask = Self.measureDimensions(imagesDirectory: imagesDirectory) { progress in
                    await MainActor.run { self?.furnitureProgressText = "치수 측정: \(progress)" }
                }
                async let meshyTask = MeshyService().process(imageData: imageData) { progress in
                    await MainActor.run { self?.furnitureProgressText = "3D 생성: \(progress)" }
                }
                let (dims, rawURL) = try await (dimsTask, meshyTask)

                await MainActor.run { self?.furnitureProgressText = "실측 치수에 맞춰 크기 조정 중..." }
                let finalURL = try Self.rescaledUSDZ(
                    from: rawURL,
                    widthMeters:  dims.width,
                    depthMeters:  dims.depth,
                    heightMeters: dims.height
                )
                try? FileManager.default.removeItem(at: rawURL)
                try? FileManager.default.removeItem(at: imagesDirectory)

                await MainActor.run { self?.phase = .furnitureModelReady(finalURL, thumbnail) }
            } catch {
                guard !Task.isCancelled else { return }   // 사용자가 취소한 경우 – 이미 이전 화면으로 이동했으므로 조용히 종료
                print("❌ LiDAR+Meshy 실패: \(error)")
                await MainActor.run { self?.furnitureProgressText = error.localizedDescription }
                try? await Task.sleep(for: .seconds(3))
                await MainActor.run { self?.phase = .furnitureMethodPicker }
            }
        }
    }

    /// 사진 한 장 → Meshy AI로 3D 모양 생성 → 사용자가 입력한 실측 치수(cm)로 리스케일
    func startFurnitureAIProcessing(imageData: Data, thumbnail: UIImage,
                                     widthCm: Double, depthCm: Double, heightCm: Double) {
        phase = .furnitureProcessing(thumbnail)
        furnitureGenerationTask = Task.detached { [weak self] in
            do {
                let rawURL = try await MeshyService().process(imageData: imageData) { progress in
                    await MainActor.run { self?.furnitureProgressText = progress }
                }

                await MainActor.run { self?.furnitureProgressText = "실제 치수에 맞춰 크기 조정 중..." }
                let finalURL = try Self.rescaledUSDZ(
                    from: rawURL,
                    widthMeters:  widthCm  / 100,
                    depthMeters:  depthCm  / 100,
                    heightMeters: heightCm / 100
                )
                try? FileManager.default.removeItem(at: rawURL)

                await MainActor.run { self?.phase = .furnitureModelReady(finalURL, thumbnail) }
            } catch {
                guard !Task.isCancelled else { return }   // 사용자가 취소한 경우 – 이미 이전 화면으로 이동했으므로 조용히 종료
                print("❌ Meshy 실패: \(error)")
                await MainActor.run { self?.furnitureProgressText = error.localizedDescription }
                try? await Task.sleep(for: .seconds(3))
                await MainActor.run { self?.phase = .furnitureMethodPicker }
            }
        }
    }

    /// LiDAR로 촬영된 이미지 세트를 PhotogrammetrySession으로 재구성해서 실측 바운딩 박스(m)만 측정.
    /// 재구성된 USDZ 자체는 쓰지 않고 측정 직후 삭제한다 (최종 비주얼은 Meshy가 담당).
    nonisolated private static func measureDimensions(
        imagesDirectory: URL,
        onProgress: @Sendable @escaping (String) async -> Void
    ) async throws -> (width: Double, depth: Double, height: Double) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)_measure.usdz")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var config = PhotogrammetrySession.Configuration()
        config.featureSensitivity = .high
        let photoSession = try PhotogrammetrySession(input: imagesDirectory, configuration: config)
        let request = PhotogrammetrySession.Request.modelFile(url: tempURL, detail: .reduced)
        try photoSession.process(requests: [request])

        var completed = false
        for try await output in photoSession.outputs {
            switch output {
            case .processingComplete:
                completed = true
            case .requestProgress(_, let fraction):
                await onProgress("가구 치수 측정 중... \(Int(fraction * 100))%")
            case .requestError(_, let error):
                throw error
            default: break
            }
        }
        guard completed else { throw FurnitureRescaleError.loadFailed }

        let scene = try SCNScene(url: tempURL, options: nil)
        let (minVec, maxVec) = scene.rootNode.boundingBox
        let width  = Double(maxVec.x - minVec.x)
        let height = Double(maxVec.y - minVec.y)
        let depth  = Double(maxVec.z - minVec.z)
        guard width > 0.0001, height > 0.0001, depth > 0.0001 else {
            throw FurnitureRescaleError.invalidBounds
        }
        return (width, depth, height)
    }

    /// LiDAR 캡처 중 저장된 사진들(heic/jpg/png) 중 대표 한 장을 골라 JPEG Data로 변환 (Meshy 업로드용)
    nonisolated private static func representativeImageData(in imagesDirectory: URL) -> Data? {
        let exts: Set<String> = ["heic", "jpg", "jpeg", "png"]
        guard let files = try? FileManager.default.contentsOfDirectory(at: imagesDirectory, includingPropertiesForKeys: nil) else {
            return nil
        }
        guard let firstURL = files
            .filter({ exts.contains($0.pathExtension.lowercased()) })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            .first else { return nil }
        guard let image = UIImage(contentsOfFile: firstURL.path) else { return nil }
        return image.jpegData(compressionQuality: 0.85)
    }

    /// Meshy AI/Tripo3D가 만든 모델(GLB/USDZ, 임의 스케일)을 로드해서 바운딩 박스를 사용자 입력 실측 치수(m)에
    /// 맞춰 리스케일한 뒤 새 USDZ로 저장. SceneKit은 이미 Room USDZ 후처리(makeEmptyUSDZ)에도 쓰고 있어
    /// USDZ 입력은 확실히 되고, glTF/glb도 iOS 13+부터 SceneKit이 읽을 수 있다고 문서화되어 있음 —
    /// 다만 Tripo3D가 실제로 내려주는 파일로는 아직 확인 못 했으니 첫 테스트에서 로드 실패하면 여기부터 볼 것.
    nonisolated private static func rescaledUSDZ(from sourceURL: URL, widthMeters: Double, depthMeters: Double, heightMeters: Double) throws -> URL {
        let scene: SCNScene
        do {
            scene = try SCNScene(url: sourceURL, options: nil)
        } catch {
            throw FurnitureRescaleError.loadFailed
        }
        let (minVec, maxVec) = scene.rootNode.boundingBox
        let currentWidth  = Double(maxVec.x - minVec.x)
        let currentHeight = Double(maxVec.y - minVec.y)
        let currentDepth  = Double(maxVec.z - minVec.z)
        guard currentWidth > 0.0001, currentHeight > 0.0001, currentDepth > 0.0001 else {
            throw FurnitureRescaleError.invalidBounds
        }

        scene.rootNode.scale = SCNVector3(
            Float(widthMeters  / currentWidth),
            Float(heightMeters / currentHeight),
            Float(depthMeters  / currentDepth)
        )

        // SCNScene.write(to:)는 rootNode.scale 같은 노드 트랜스폼을 USDZ로 내보낼 때 반영하지 않는다
        // (직접 테스트로 확인: scale 적용 후 write→재로드하면 원본 크기 그대로 돌아옴).
        // flattenedClone()으로 스케일을 지오메트리 정점에 직접 구워넣은 새 노드를 만들어야
        // 내보낸 파일의 실제 바운딩 박스가 의도한 실측 치수와 일치한다.
        let flattened = scene.rootNode.flattenedClone()
        let outputScene = SCNScene()
        outputScene.rootNode.addChildNode(flattened)

        let fm = FileManager.default
        let modelsDir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FurnitureModels")
        try? fm.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        let outputURL = modelsDir.appendingPathComponent("\(UUID().uuidString).usdz")

        guard outputScene.write(to: outputURL, options: nil, delegate: nil, progressHandler: nil) else {
            throw FurnitureRescaleError.writeFailed
        }
        return outputURL
    }

    /// 가구 3D 생성 취소 (생성 화면의 "취소" 버튼)
    func cancelFurnitureGeneration() {
        furnitureGenerationTask?.cancel()
        furnitureGenerationTask = nil
        phase = .furnitureMethodPicker
    }

    func saveFurniture(image: UIImage, name: String) {
        saveFurnitureWithModel(image: image, name: name, modelURL: nil)
    }

    func saveFurnitureWithModel(image: UIImage, name: String, modelURL: URL?) {
        let thumbName = "\(UUID().uuidString).jpg"
        if let data = image.jpegData(compressionQuality: 0.85) {
            try? data.write(to: thumbnailsDirectory().appendingPathComponent(thumbName))
        }
        // 모델 파일: Documents/FurnitureModels/ 에 이미 있으므로 파일명만 저장
        let modelName = modelURL.map { $0.lastPathComponent }
        let item = FurnitureItem(name: name, thumbnailFileName: thumbName, modelFileName: modelName)
        savedFurniture.append(item)
        persistFurniture()
        phase = .furnitureList

        if let modelURL {
            registerFurnitureWithServer(itemId: item.id, modelURL: modelURL, name: name)
        }
    }

    /// 가구 보관함 서버 등록 (best-effort, 실패해도 로컬 저장은 유지됨):
    /// 1) 치수 등록 → presigned 업로드 URL 수신
    /// 2) 로컬 3D 모델 파일을 그 URL로 PUT 업로드
    /// 3) 업로드 완료 확인
    /// 4) 서버에서 GLB → USDZ 변환 (다른 기기/플랫폼에서도 쓸 수 있는 정식 usdz_url 확보)
    private func registerFurnitureWithServer(itemId: UUID, modelURL: URL, name: String) {
        guard let accessToken = KeychainTokenStore.get(.accessToken) else {
            furnitureSyncError = "로그인이 만료됐어요. 다시 로그인하면 서버에도 저장돼요 (로컬 저장은 유지됩니다)"
            return
        }
        Task {
            do {
                let entity = try await Entity.load(contentsOf: modelURL)
                let bounds = entity.visualBounds(relativeTo: nil)
                let service = FurnitureModelService()

                // RealityKit 바운딩 박스는 미터 단위 (LiDAR 깊이 데이터로 재구성된 실측 스케일)
                let widthMeters  = Double(bounds.extents.x)
                let depthMeters  = Double(bounds.extents.z)
                let heightMeters = Double(bounds.extents.y)

                var model = try await service.registerModel(
                    name: name,
                    modelFilename: modelURL.lastPathComponent,
                    width:  widthMeters,
                    depth:  depthMeters,
                    height: heightMeters,
                    accessToken: accessToken
                )
                print("✅ 가구 등록됨 – modelId=\(model.modelId)")

                if let uploadURLString = model.uploadUrl {
                    let fileData = try Data(contentsOf: modelURL)
                    let contentType = model.uploadContentType ?? "application/octet-stream"
                    try await service.uploadFile(presignedURL: uploadURLString, data: fileData, contentType: contentType)
                    print("✅ 가구 모델 파일 업로드 완료 (\(fileData.count) bytes)")

                    model = try await service.completeUpload(modelId: model.modelId, accessToken: accessToken)
                    print("✅ 가구 업로드 확인 완료 – status=\(model.status)")

                    let conversion = try await service.convertToUsdz(modelId: model.modelId, accessToken: accessToken)
                    print("✅ 가구 서버 USDZ 변환 완료 – usdz_url=\(conversion.usdzUrl)")
                }

                guard let idx = savedFurniture.firstIndex(where: { $0.id == itemId }) else { return }
                savedFurniture[idx].serverModelId = model.modelId
                savedFurniture[idx].modelKey = model.modelKey
                savedFurniture[idx].widthCm = widthMeters * 100
                savedFurniture[idx].depthCm = depthMeters * 100
                savedFurniture[idx].heightCm = heightMeters * 100
                persistFurniture()
            } catch {
                print("⚠️ 가구 서버 등록 실패 (로컬 저장은 유지됨): \(error)")
                furnitureSyncError = "가구를 서버에 동기화하지 못했어요 (로컬 저장은 유지됩니다): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
        }
    }

    func modelURL(for item: FurnitureItem) -> URL? {
        guard let fileName = item.modelFileName else { return nil }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FurnitureModels")
            .appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func updateFurnitureName(_ name: String, id: UUID) {
        guard let idx = savedFurniture.firstIndex(where: { $0.id == id }) else { return }
        savedFurniture[idx].name = name
        persistFurniture()
    }

    func deleteFurniture(_ item: FurnitureItem) {
        let fileURL = thumbnailsDirectory().appendingPathComponent(item.thumbnailFileName)
        try? FileManager.default.removeItem(at: fileURL)
        savedFurniture.removeAll { $0.id == item.id }
        persistFurniture()

        if let modelId = item.serverModelId, let accessToken = KeychainTokenStore.get(.accessToken) {
            Task {
                try? await FurnitureModelService().deleteModel(modelId: modelId, accessToken: accessToken)
            }
        }
    }

    func persistFurniture() {
        let snapshot = savedFurniture
        let url = furnitureListURL()
        Task.detached {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url)
        }
    }

    func thumbnailImage(for item: FurnitureItem) -> UIImage? {
        UIImage(contentsOfFile: thumbnailsDirectory().appendingPathComponent(item.thumbnailFileName).path)
    }

    // MARK: Furniture Persistence

    func thumbnailsDirectory() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FurnitureThumbnails")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func furnitureListURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("furniture_list.json")
    }

    func loadFurnitureList() throws -> [FurnitureItem] {
        let data = try Data(contentsOf: furnitureListURL())
        return try JSONDecoder().decode([FurnitureItem].self, from: data)
    }
}

// MARK: - Errors

enum FurnitureRescaleError: LocalizedError {
    case loadFailed
    case invalidBounds
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .loadFailed:     return "생성된 모델을 불러오지 못했어요"
        case .invalidBounds:  return "모델 크기를 측정할 수 없어요"
        case .writeFailed:    return "모델을 저장하지 못했어요"
        }
    }
}
