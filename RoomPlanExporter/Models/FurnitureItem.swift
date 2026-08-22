import Foundation

struct FurnitureItem: Codable, Identifiable {
    let id: UUID
    var name: String
    let thumbnailFileName: String
    var modelFileName: String?   // Documents/FurnitureModels/<uuid>.usdz or .glb
    let capturedAt: Date
    var serverModelId: Int?      // 서버 가구 보관함에 등록된 model_id (등록 안 됐으면 nil)
    var modelKey: String?        // 서버가 발급한 model_key

    /// 가로/세로/높이 (cm). LiDAR 스캔 항목은 재구성된 3D 모델 바운딩 박스에서 자동 계산되고,
    /// 사진 보관함으로 등록한 항목은 사용자가 직접 입력한 값이 들어간다.
    var widthCm: Double?
    var depthCm: Double?
    var heightCm: Double?

    init(id: UUID = UUID(), name: String,
         thumbnailFileName: String, modelFileName: String? = nil,
         capturedAt: Date = Date(), serverModelId: Int? = nil, modelKey: String? = nil,
         widthCm: Double? = nil, depthCm: Double? = nil, heightCm: Double? = nil) {
        self.id = id
        self.name = name
        self.thumbnailFileName = thumbnailFileName
        self.modelFileName = modelFileName
        self.capturedAt = capturedAt
        self.serverModelId = serverModelId
        self.modelKey = modelKey
        self.widthCm = widthCm
        self.depthCm = depthCm
        self.heightCm = heightCm
    }

    var hasModel: Bool { modelFileName != nil }

    var dimensionText: String? {
        guard let widthCm, let depthCm, let heightCm else { return nil }
        return String(format: "%.0f × %.0f × %.0f cm", widthCm, depthCm, heightCm)
    }
}
