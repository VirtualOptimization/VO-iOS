import Foundation

// MARK: - 인증 서버 API

struct UserInfo: Codable {
    let userId:         Int
    let loginId:        String
    let email:          String
    let nickname:       String
    let isEmailVerified: Bool

    enum CodingKeys: String, CodingKey {
        case userId          = "user_id"
        case loginId         = "login_id"
        case email
        case nickname
        case isEmailVerified = "is_email_verified"
    }
}

struct TokenPair {
    let accessToken:  String
    let refreshToken: String
}

actor AuthService {

    private let base = "\(APIConfig.baseURL)/auth"

    // MARK: 이메일 인증번호 발송 (POST /auth/email/send-code)

    func sendEmailCode(email: String) async throws {
        struct Req: Encodable { let email: String }
        let (data, response) = try await post("\(base)/email/send-code", body: Req(email: email))
        try check(response, data)
    }

    // MARK: 이메일 인증번호 확인 (POST /auth/email/verify)

    func verifyEmailCode(email: String, code: String) async throws -> Bool {
        struct Req: Encodable { let email: String; let code: String }
        struct Res: Decodable { let verified: Bool }
        let (data, response) = try await post("\(base)/email/verify", body: Req(email: email, code: code))
        try check(response, data)
        return try decode(Res.self, from: data).verified
    }

    // MARK: 회원가입 완료 (POST /auth/signup)

    func signUp(loginId: String, password: String, passwordConfirm: String, email: String, nickname: String) async throws -> UserInfo {
        struct Req: Encodable { let loginId, password, passwordConfirm, email, nickname: String
            enum CodingKeys: String, CodingKey {
                case loginId = "login_id", password
                case passwordConfirm = "password_confirm"
                case email, nickname
            }
        }
        let (data, response) = try await post(
            "\(base)/signup",
            body: Req(loginId: loginId, password: password, passwordConfirm: passwordConfirm, email: email, nickname: nickname)
        )
        try check(response, data)
        return try decode(UserInfo.self, from: data)
    }

    // MARK: 로그인 (POST /auth/login)

    func login(loginId: String, password: String) async throws -> TokenPair {
        struct Req: Encodable { let loginId, password: String
            enum CodingKeys: String, CodingKey { case loginId = "login_id", password }
        }
        struct Res: Decodable {
            let accessToken, refreshToken: String
            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token", refreshToken = "refresh_token"
            }
        }
        let (data, response) = try await post("\(base)/login", body: Req(loginId: loginId, password: password))
        try check(response, data)
        let res = try decode(Res.self, from: data)
        return TokenPair(accessToken: res.accessToken, refreshToken: res.refreshToken)
    }

    // MARK: 액세스 토큰 재발급 (POST /auth/refresh)

    func refresh(refreshToken: String) async throws -> String {
        struct Req: Encodable { let refreshToken: String
            enum CodingKeys: String, CodingKey { case refreshToken = "refresh_token" }
        }
        struct Res: Decodable { let accessToken: String
            enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
        }
        let (data, response) = try await post("\(base)/refresh", body: Req(refreshToken: refreshToken))
        try check(response, data)
        return try decode(Res.self, from: data).accessToken
    }

    // MARK: 로그아웃 (POST /auth/logout)

    func logout(refreshToken: String) async throws {
        struct Req: Encodable { let refreshToken: String
            enum CodingKeys: String, CodingKey { case refreshToken = "refresh_token" }
        }
        let (data, response) = try await post("\(base)/logout", body: Req(refreshToken: refreshToken))
        try check(response, data)
    }

    // MARK: 내 정보 조회 (GET /auth/me)

    func me(accessToken: String) async throws -> UserInfo {
        var req = URLRequest(url: URL(string: "\(base)/me")!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        try check(response, data)
        return try decode(UserInfo.self, from: data)
    }

    // MARK: - Helpers

    private func post<T: Encodable>(_ urlString: String, body: T) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: URL(string: urlString)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        return try await URLSession.shared.data(for: req)
    }

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
