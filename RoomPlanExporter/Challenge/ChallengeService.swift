import Foundation

struct ChallengeEvent: Decodable {
    let eventId: Int
    let name: String
    let isActive: Bool
    let maxAttempts: Int
    let maxScore: Double
    let criteria: [ChallengeCriterion]
    let disqualifyRules: [String]
    enum CodingKeys: String, CodingKey {
        case eventId = "event_id", name, isActive = "is_active"
        case maxAttempts = "max_attempts", maxScore = "max_score"
        case criteria, disqualifyRules = "disqualify_rules"
    }
}

struct ChallengeCriterion: Decodable, Identifiable {
    let key: String
    let title: String
    let maxScore: Double
    let description: String
    var id: String { key }
    enum CodingKeys: String, CodingKey {
        case key, title, maxScore = "max_score", description
    }
}

struct ChallengeRegistration: Decodable {
    let participantToken: String
    let remainingAttempts: Int
    enum CodingKeys: String, CodingKey {
        case participantToken = "participant_token", remainingAttempts = "remaining_attempts"
    }
}

struct ChallengeRoom {
    let detail: RoomVersionDetail
    let remainingAttempts: Int
}

private struct ChallengeRoomResponse: Decodable {
    let start: RoomVersionDetail
    let remainingAttempts: Int
    enum CodingKeys: String, CodingKey {
        case start, remainingAttempts = "remaining_attempts"
    }
}

struct ChallengeScore: Codable {
    let attemptId: Int
    let totalScore: Double
    let maxScore: Double
    let disqualified: Bool
    let breakdown: [String: Double]?
    let hints: [String]
    let beatAI: Bool
    let aiScore: Double?
    let rank: Int?
    let totalRanked: Int
    let remainingAttempts: Int
    enum CodingKeys: String, CodingKey {
        case attemptId = "attempt_id", totalScore = "total_score", maxScore = "max_score"
        case disqualified, breakdown, hints, beatAI = "beat_ai", aiScore = "ai_score", rank
        case totalRanked = "total_ranked", remainingAttempts = "remaining_attempts"
    }
}

struct ChallengeLeaderboard: Decodable {
    let eventId: Int
    let totalRanked: Int
    let aiScore: Double?
    let entries: [ChallengeLeaderboardEntry]
    enum CodingKeys: String, CodingKey {
        case eventId = "event_id", totalRanked = "total_ranked", aiScore = "ai_score", entries
    }
}

struct ChallengeLeaderboardEntry: Decodable, Identifiable {
    let rank: Int
    let name: String
    let totalScore: Double
    let elapsedSeconds: Int?
    var id: Int { rank }
    enum CodingKeys: String, CodingKey {
        case rank, name, totalScore = "total_score", elapsedSeconds = "elapsed_seconds"
    }
}

private struct RegistrationBody: Encodable {
    let name: String
    let phone: String
    let privacyConsent = true
    enum CodingKeys: String, CodingKey { case name, phone, privacyConsent = "privacy_consent" }
}

struct ChallengeParticipantSession: Decodable {
    let remainingAttempts: Int
    let latestResult: ChallengeScore?
    let elapsedSeconds: Int?
    enum CodingKeys: String, CodingKey {
        case remainingAttempts = "remaining_attempts", latestResult = "latest_result", elapsedSeconds = "elapsed_seconds"
    }
}

struct ChallengeObjectEdit: Codable {
    let identifier: String
    let transform: [[Float]]

    init(pose: FurniturePoseEdit) {
        identifier = pose.identifier
        let x = pose.center[0], y = pose.center[1], z = pose.center[2]
        let yaw = pose.rotation.count > 1 ? pose.rotation[1] : pose.rotation[0]
        let c = cos(yaw), s = sin(yaw)
        transform = [
            [c, 0, s, 0],
            [0, 1, 0, 0],
            [-s, 0, c, 0],
            [x, y, z, 1],
        ]
    }
}

private struct SubmissionBody: Encodable {
    let elapsedSeconds: Int
    let iosObjects: [ChallengeObjectEdit]
    enum CodingKeys: String, CodingKey {
        case elapsedSeconds = "elapsed_seconds", iosObjects = "ios_objects"
    }
}

protocol ChallengeServing {
    func event() async throws -> ChallengeEvent
    func register(name: String, phone: String) async throws -> ChallengeRegistration
    func session(token: String) async throws -> ChallengeParticipantSession
    func room(token: String) async throws -> ChallengeRoom
    func submit(token: String, elapsed: Int, objects: [ChallengeObjectEdit], key: UUID) async throws -> ChallengeScore
    func leaderboard() async throws -> ChallengeLeaderboard
}

struct ChallengeService: ChallengeServing {
    let eventId: Int
    private var base: URL {
        URL(string: "\(APIConfig.baseURL)/events/\(eventId > 0 ? String(eventId) : "current")")!
    }

    private func request(_ path: String = "", method: String = "GET", token: String? = nil,
                         body: Data? = nil, idempotencyKey: String? = nil,
                         queryItems: [URLQueryItem] = []) async throws -> Data {
        var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        if !queryItems.isEmpty { components.queryItems = queryItems }
        var req = URLRequest(url: components.url!)
        req.httpMethod = method
        req.timeoutInterval = 45
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { req.httpBody = body; req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let idempotencyKey { req.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw APIError(statusCode: 0, detail: "서버에 연결할 수 없어요.")
        }
        guard (200...299).contains(status) else { throw APIError.from(statusCode: status, data: data) }
        return data
    }

    func event() async throws -> ChallengeEvent {
        try JSONDecoder().decode(ChallengeEvent.self, from: await request())
    }

    func register(name: String, phone: String) async throws -> ChallengeRegistration {
        let body = try JSONEncoder().encode(RegistrationBody(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                                             phone: phone.filter { $0 >= "0" && $0 <= "9" }))
        return try JSONDecoder().decode(ChallengeRegistration.self,
                                        from: await request("participants", method: "POST", body: body))
    }

    func session(token: String) async throws -> ChallengeParticipantSession {
        try JSONDecoder().decode(ChallengeParticipantSession.self, from: await request("session", token: token))
    }

    func room(token: String) async throws -> ChallengeRoom {
        let data = try await request("challenge", token: token)
        let response = try JSONDecoder().decode(ChallengeRoomResponse.self, from: data)
        guard response.start.effectiveDataUrl != nil else {
            throw APIError(statusCode: 0, detail: "방 배치 파일이 없어요.")
        }
        return ChallengeRoom(detail: response.start, remainingAttempts: response.remainingAttempts)
    }

    func submit(token: String, elapsed: Int, objects: [ChallengeObjectEdit], key: UUID) async throws -> ChallengeScore {
        let body = try JSONEncoder().encode(SubmissionBody(elapsedSeconds: elapsed, iosObjects: objects))
        return try JSONDecoder().decode(ChallengeScore.self,
               from: await request("attempts", method: "POST", token: token, body: body,
                                   idempotencyKey: key.uuidString))
    }

    func leaderboard() async throws -> ChallengeLeaderboard {
        try JSONDecoder().decode(ChallengeLeaderboard.self,
                                 from: await request("leaderboard", queryItems: [URLQueryItem(name: "limit", value: "20")]))
    }
}
