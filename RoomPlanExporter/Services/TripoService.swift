import Foundation

// MARK: - Tripo3D Image → 3D Service (API v3)
// 발급: https://platform.tripo3d.ai → API Keys (키는 tsk_로 시작 — tcli_로 시작하는 키는
//       REST API용이 아니라 다른 용도의 클라이언트 ID라 여기 쓰면 인증이 안 됨)
// 문서: https://developers.tripo3d.ai (베이스: https://openapi.tripo3d.ai/v3)
//
// v3부터 모든 응답이 {"code":0,"data":{...}} 성공 / {"code":N,"message","suggestion"} 실패로
// 감싸져있고, 이미지 참조 방식도 파일 업로드(POST /files) → file_token → 태스크 생성으로 바뀜.

struct TripoService {

    // ⚠️ 직접 하드코딩하지 말 것 — Configuration/Secrets.xcconfig의 TRIPO_API_KEY로 주입됨
    static var apiKey: String = Bundle.main.object(forInfoDictionaryKey: "TripoAPIKey") as? String ?? ""

    private let base = "https://openapi.tripo3d.ai/v3"

    // MARK: - 공개 진입점

    /// imageData(JPEG) → 다운로드된 모델 파일 URL (USDZ, RealityKit에서 바로 로드 가능)
    func process(
        imageData: Data,
        onProgress: @Sendable @escaping (String) async -> Void
    ) async throws -> URL {
        await onProgress("이미지 업로드 중...")
        let fileToken = try await uploadFile(imageData)

        await onProgress("3D 변환 요청 중...")
        let taskId = try await createTask(fileToken: fileToken)
        _ = try await waitForSuccess(taskId: taskId, onProgress: onProgress)

        // Tripo 생성 결과는 기본 GLB — RealityKit/SceneKit이 GLB를 직접 못 읽으므로
        // 서버 변환 API로 USDZ를 따로 받는다.
        await onProgress("USDZ로 변환 중...")
        let convertTaskId = try await createConvertTask(sourceTaskId: taskId)
        let output = try await waitForSuccess(taskId: convertTaskId, onProgress: onProgress)
        guard let s = output.modelUrl, let modelURL = URL(string: s) else { throw TripoError.noModel }

        await onProgress("모델 다운로드 중...")
        return try await downloadModel(from: modelURL)
    }

    // MARK: - 공용 응답 래퍼

    private struct Envelope<T: Decodable>: Decodable {
        let code: Int
        let data: T?
        let message: String?
        let suggestion: String?
    }

    // MARK: - Step 1: 파일 업로드 (POST /files)

    private struct FileTokenData: Decodable {
        let fileToken: String
        enum CodingKeys: String, CodingKey { case fileToken = "file_token" }
    }

    private func uploadFile(_ data: Data) async throws -> String {
        let boundary = UUID().uuidString
        var req = URLRequest(url: try url("/files"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(Self.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = multipart(name: "file", filename: "furniture.jpg", mime: "image/jpeg",
                                 data: data, boundary: boundary)
        req.timeoutInterval = 60

        let (body, resp) = try await URLSession.shared.data(for: req)
        let env: Envelope<FileTokenData> = try checkAndDecode(resp, body)
        guard let fileToken = env.data?.fileToken else { throw TripoError.noModel }
        return fileToken
    }

    // MARK: - Step 2: 변환 태스크 생성 (POST /generation/image-to-model)

    private struct TaskIdData: Decodable {
        let taskId: String
        enum CodingKeys: String, CodingKey { case taskId = "task_id" }
    }

    // v3 API가 요구하는 필수 model 파라미터. 서버가 허용 목록을 에러로 알려줌:
    // P1-20260311 / v2.5-20250123 / v3.0-20250812 / v3.1-20260211 — 그 중 최신 v3 계열로 고정.
    private static let modelVersion = "v3.1-20260211"

    private func createTask(fileToken: String) async throws -> String {
        var req = URLRequest(url: try url("/generation/image-to-model"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(Self.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "file": ["type": "jpg", "file_token": fileToken],
            "model": Self.modelVersion
        ])
        req.timeoutInterval = 30

        let (body, resp) = try await URLSession.shared.data(for: req)
        let env: Envelope<TaskIdData> = try checkAndDecode(resp, body)
        guard let taskId = env.data?.taskId else { throw TripoError.noModel }
        return taskId
    }

    // MARK: - Step 3: GLB → USDZ 서버 변환 (POST /models/convert)

    private func createConvertTask(sourceTaskId: String) async throws -> String {
        var req = URLRequest(url: try url("/models/convert"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(Self.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "input": sourceTaskId,
            "format": "USDZ"
        ])
        req.timeoutInterval = 30

        let (body, resp) = try await URLSession.shared.data(for: req)
        let env: Envelope<TaskIdData> = try checkAndDecode(resp, body)
        guard let taskId = env.data?.taskId else { throw TripoError.noModel }
        return taskId
    }

    // MARK: - 완료까지 폴링 (GET /tasks/{id}, 5초 간격, 최대 5분) — 생성/변환 태스크 공용

    private struct TaskStatusData: Decodable {
        let status: String
        let progress: Int?
        let output: Output?
        struct Output: Decodable {
            let modelUrl: String?
            enum CodingKeys: String, CodingKey { case modelUrl = "model_url" }
        }
    }

    private func waitForSuccess(
        taskId: String,
        onProgress: @Sendable @escaping (String) async -> Void
    ) async throws -> TaskStatusData.Output {
        var req = URLRequest(url: try url("/tasks/\(taskId)"))
        req.setValue("Bearer \(Self.apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30

        for attempt in 1...60 {
            try await Task.sleep(for: .seconds(5))
            let (body, resp) = try await URLSession.shared.data(for: req)
            let env: Envelope<TaskStatusData> = try checkAndDecode(resp, body)
            guard let st = env.data else { throw TripoError.noModel }

            switch st.status {
            case "success":
                return st.output ?? TaskStatusData.Output(modelUrl: nil)
            case "failed", "cancelled":
                throw TripoError.failed(st.status)
            default:
                let pct = st.progress ?? min(attempt * 2, 90)
                await onProgress("3D 변환 중... \(pct)%")
            }
        }
        throw TripoError.timeout
    }

    // MARK: - Step 4: 모델 다운로드

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

    private func url(_ path: String) throws -> URL {
        guard let u = URL(string: base + path) else { throw TripoError.badURL }
        return u
    }

    /// HTTP 상태 + v3 공용 응답 래퍼(code/message/suggestion)를 함께 검사 후 data를 꺼낸다.
    private func checkAndDecode<T: Decodable>(_ response: URLResponse, _ data: Data) throws -> Envelope<T> {
        guard let http = response as? HTTPURLResponse else { throw TripoError.httpError(-1) }
        guard (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            print("❌ Tripo \(http.statusCode): \(msg)")
            if let body = try? JSONDecoder().decode(TripoErrorBody.self, from: data) {
                let suggestion = body.suggestion.map { " (\($0))" } ?? ""
                throw TripoError.failed((body.message ?? "요청 실패") + suggestion)
            }
            throw TripoError.httpError(http.statusCode)
        }
        let env = try JSONDecoder().decode(Envelope<T>.self, from: data)
        if env.code != 0 {
            let suggestion = env.suggestion.map { " (\($0))" } ?? ""
            throw TripoError.failed((env.message ?? "요청 실패") + suggestion)
        }
        return env
    }

    private struct TripoErrorBody: Decodable {
        let code: Int?
        let message: String?
        let suggestion: String?
    }

    private func multipart(name: String, filename: String, mime: String,
                           data: Data, boundary: String) -> Data {
        var body = Data()
        func s(_ str: String) { body.append(str.data(using: .utf8)!) }
        s("--\(boundary)\r\n")
        s("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        s("Content-Type: \(mime)\r\n\r\n")
        body.append(data)
        s("\r\n--\(boundary)--\r\n")
        return body
    }
}

// MARK: - Errors

enum TripoError: LocalizedError {
    case badURL
    case httpError(Int)
    case noModel
    case failed(String?)
    case timeout

    var errorDescription: String? {
        switch self {
        case .badURL:              return "잘못된 URL"
        case .httpError(let c):   return "서버 오류 (\(c))"
        case .noModel:             return "모델 파일이 없어요"
        case .failed(let m):       return m ?? "변환 실패"
        case .timeout:             return "시간 초과 (5분)"
        }
    }
}
