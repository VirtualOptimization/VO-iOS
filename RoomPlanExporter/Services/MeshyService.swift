import Foundation

// MARK: - Meshy AI Image → 3D Service
// 발급: https://app.meshy.ai → API Keys
// 문서: https://docs.meshy.ai/en/api/image-to-3d
//
// 최신 Image-to-3D API는 단일 요청으로 지오메트리+텍스처를 한 번에 생성함
// (예전 preview→refine 2단계 방식은 폐기됨).

struct MeshyService {

    // ⚠️ 직접 하드코딩하지 말 것 — Configuration/Secrets.xcconfig의 MESHY_API_KEY로 주입됨
    static var apiKey: String = Bundle.main.object(forInfoDictionaryKey: "MeshyAPIKey") as? String ?? ""

    private let base = "https://api.meshy.ai/openapi/v1/image-to-3d"

    // MARK: - 공개 진입점

    func process(
        imageData: Data,
        onProgress: @Sendable @escaping (String) async -> Void
    ) async throws -> URL {
        await onProgress("이미지 업로드 중...")
        let dataURI = "data:image/jpeg;base64,\(imageData.base64EncodedString())"

        await onProgress("3D 변환 요청 중...")
        let taskId = try await createTask(imageDataURI: dataURI)

        let modelURL = try await poll(taskId: taskId, onProgress: onProgress)

        await onProgress("모델 다운로드 중...")
        return try await downloadModel(from: modelURL)
    }

    // MARK: - 태스크 생성 (POST /image-to-3d) — 지오메트리+텍스처 단일 요청

    private struct CreateResp: Decodable {
        let result: String
    }

    private func createTask(imageDataURI: String) async throws -> String {
        var req = URLRequest(url: URL(string: base)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(Self.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "image_url": imageDataURI,
            "should_texture": true,
            "enable_pbr": true
        ])
        req.timeoutInterval = 60

        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp, data)
        return try decode(CreateResp.self, from: data).result
    }

    // MARK: - 폴링 (GET /image-to-3d/{id}, 5초 간격, 최대 10분)

    private struct StatusResp: Decodable {
        let status: String
        let progress: Int?
        let modelUrls: ModelUrls?
        struct ModelUrls: Decodable {
            let glb: String?
            let usdz: String?
        }
        enum CodingKeys: String, CodingKey {
            case status, progress
            case modelUrls = "model_urls"
        }
    }

    private func poll(
        taskId: String,
        onProgress: @Sendable @escaping (String) async -> Void
    ) async throws -> URL {
        var req = URLRequest(url: URL(string: "\(base)/\(taskId)")!)
        req.setValue("Bearer \(Self.apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30

        for attempt in 1...120 {
            try await Task.sleep(for: .seconds(5))
            let (data, resp) = try await URLSession.shared.data(for: req)
            try check(resp, data)
            let st = try decode(StatusResp.self, from: data)

            switch st.status {
            case "SUCCEEDED":
                // usdz 우선 — RealityKit/SceneKit이 GLB를 네이티브로 못 읽어서 앱 내 미리보기가
                // GLB로는 실패함(noImporter). 없으면 glb로 폴백(그 경우 미리보기는 깨질 수 있음).
                let urlStr = st.modelUrls?.usdz ?? st.modelUrls?.glb
                guard let s = urlStr, let u = URL(string: s) else { throw MeshyError.noModel }
                return u
            case "FAILED", "CANCELED":
                throw MeshyError.failed(st.status)
            default:
                let pct = st.progress ?? min(attempt, 90)
                await onProgress("3D 변환 중... \(pct)%")
            }
        }
        throw MeshyError.timeout
    }

    // MARK: - 모델 다운로드

    private func downloadModel(from remote: URL) async throws -> URL {
        var req = URLRequest(url: remote)
        req.timeoutInterval = 60
        let (tmp, _) = try await URLSession.shared.download(for: req)
        let ext = remote.pathExtension.isEmpty ? "glb" : remote.pathExtension
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).\(ext)")
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    // MARK: - Helpers

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw MeshyError.httpError(-1) }
        guard (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            print("❌ Meshy \(http.statusCode): \(msg)")
            throw MeshyError.httpError(http.statusCode)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

// MARK: - Errors

enum MeshyError: LocalizedError {
    case httpError(Int)
    case noModel
    case failed(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .httpError(let c): return "서버 오류 (\(c))"
        case .noModel:          return "모델 파일이 없어요"
        case .failed(let s):    return "변환 실패 (\(s))"
        case .timeout:          return "시간 초과 (10분)"
        }
    }
}
