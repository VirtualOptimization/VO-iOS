import Foundation

// MARK: - 공용 서버 설정

enum APIConfig {
    static let baseURL = "http://3.27.164.214/api"
}

// MARK: - 공용 에러 응답 ({"detail": "..."} 형태)

struct APIErrorResponse: Decodable {
    let detail: String
}

/// 서버가 내려주는 `detail` 메시지를 우선 노출하는 공용 에러.
struct APIError: LocalizedError {
    let statusCode: Int
    let detail: String?

    var errorDescription: String? { detail ?? "서버 오류가 발생했습니다 (\(statusCode))" }

    /// HTTP 응답 + 바디에서 APIError를 생성 (2xx가 아닐 때만 호출)
    static func from(statusCode: Int, data: Data) -> APIError {
        if let detail = try? JSONDecoder().decode(APIErrorResponse.self, from: data).detail {
            return APIError(statusCode: statusCode, detail: detail)
        }
        // FastAPI validation failures use a list of {loc, msg, type} entries.
        if let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errors = body["detail"] as? [[String: Any]],
           let message = errors.first?["msg"] as? String {
            return APIError(statusCode: statusCode,
                            detail: message.replacingOccurrences(of: "Value error, ", with: ""))
        }
        return APIError(statusCode: statusCode, detail: nil)
    }
}
