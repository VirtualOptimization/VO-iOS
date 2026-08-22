import Foundation

// MARK: - 가구 보관함 서버 API

struct FurnitureModel: Codable, Identifiable {
    var id: Int { modelId }
    let modelId:   Int
    let modelKey:  String
    let name:      String?
    let status:    String
    let glbUrl:    String?
    let usdzUrl:   String?
    let width, depth, height: Double
    let createdAt: String?
    let updatedAt: String?
    let uploadUrl:         String?
    let uploadS3Key:       String?
    let uploadContentType: String?

    enum CodingKeys: String, CodingKey {
        case modelId   = "model_id"
        case modelKey  = "model_key"
        case name, status
        case glbUrl    = "glb_url"
        case usdzUrl   = "usdz_url"
        case width, depth, height
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case uploadUrl         = "upload_url"
        case uploadS3Key       = "upload_s3_key"
        case uploadContentType = "upload_content_type"
    }
}

struct FurnitureModelUsdzConversion: Decodable {
    let modelId:    Int
    let modelKey:   String
    let status:     String
    let glbUrl:     String?
    let usdzUrl:    String
    let usdzS3Key:  String

    enum CodingKeys: String, CodingKey {
        case modelId   = "model_id"
        case modelKey  = "model_key"
        case status
        case glbUrl    = "glb_url"
        case usdzUrl   = "usdz_url"
        case usdzS3Key = "usdz_s3_key"
    }
}

actor FurnitureModelService {

    private let base = "\(APIConfig.baseURL)/furniture/models"

    // MARK: 내 가구 목록 조회 (GET /furniture/models)

    func fetchModels(accessToken: String) async throws -> [FurnitureModel] {
        struct Res: Decodable { let models: [FurnitureModel] }
        var req = URLRequest(url: URL(string: base)!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        try check(response, data)
        return try decode(Res.self, from: data).models
    }

    // MARK: 내 가구 등록 (POST /furniture/models/register) – presigned 업로드 URL을 함께 받음

    func registerModel(name: String?, modelFilename: String,
                       width: Double, depth: Double, height: Double,
                       accessToken: String) async throws -> FurnitureModel {
        struct Req: Encodable {
            let name: String?
            let modelFilename: String
            let width, depth, height: Double
            enum CodingKeys: String, CodingKey {
                case name
                case modelFilename = "model_filename"
                case width, depth, height
            }
        }
        var req = URLRequest(url: URL(string: "\(base)/register")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(
            Req(name: name, modelFilename: modelFilename, width: width, depth: depth, height: height)
        )
        let (data, response) = try await URLSession.shared.data(for: req)
        try check(response, data)
        return try decode(FurnitureModel.self, from: data)
    }

    // MARK: GLB 파일을 presigned URL로 직접 업로드 (S3 PUT)

    func uploadFile(presignedURL: String, data: Data, contentType: String) async throws {
        guard let url = URL(string: presignedURL) else { throw OptimizerError.invalidResponse }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        req.timeoutInterval = 120
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            print("❌ 가구 GLB S3 PUT 실패: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            throw OptimizerError.serverError
        }
    }

    // MARK: 업로드 완료 확인 + GLB 변환 (POST /furniture/models/{model_id}/complete)

    func completeUpload(modelId: Int, accessToken: String) async throws -> FurnitureModel {
        var req = URLRequest(url: URL(string: "\(base)/\(modelId)/complete")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        try check(response, data)
        return try decode(FurnitureModel.self, from: data)
    }

    // MARK: GLB → USDZ 서버 변환 (POST /furniture/models/{model_id}/convert-usdz)

    func convertToUsdz(modelId: Int, accessToken: String) async throws -> FurnitureModelUsdzConversion {
        var req = URLRequest(url: URL(string: "\(base)/\(modelId)/convert-usdz")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        try check(response, data)
        return try decode(FurnitureModelUsdzConversion.self, from: data)
    }

    // MARK: 내 가구 삭제 (DELETE /furniture/models/{model_id})

    func deleteModel(modelId: Int, accessToken: String) async throws {
        var req = URLRequest(url: URL(string: "\(base)/\(modelId)")!)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        try check(response, data)
    }

    // MARK: - Helpers

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw APIError.from(statusCode: code, data: data)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
