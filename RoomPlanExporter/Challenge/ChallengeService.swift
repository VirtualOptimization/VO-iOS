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

    var strengths: [String] {
        var messages: [String] = []
        if let safety = breakdown?["safety"], safety >= 24 {
            messages.append(safety >= 30 ? "출입과 가구 사용 공간 항목에서 만점을 받았어요." : "출입과 가구 사용 공간 항목에서 좋은 점수를 받았어요.")
        }
        if let principles = breakdown?["principles"], principles >= 24 {
            messages.append(principles >= 30 ? "가구 배치 원칙을 잘 지켜 만점을 받았어요." : "가구의 위치와 방향이 배치 원칙에 잘 맞는 편이에요.")
        }
        if beatAI {
            messages.append("AI 배치보다 넓은 사용 가능 공간을 확보했어요.")
        } else if let space = breakdown?["space"], space >= 32 {
            messages.append(space >= 40 ? "공간 활용 항목에서 만점을 받았어요." : "공간 활용 항목에서 좋은 점수를 받았어요.")
        }
        return messages
    }

    var improvements: [String] {
        var messages: [String] = []
        if hints.contains("가구끼리 겹쳐 있어요") {
            messages.append("가구끼리 겹쳐 있는 부분이 있어 사용하기 불편할 수 있어요.")
        }
        if hints.contains("가구가 방 밖으로 나가 있어요") {
            messages.append("가구 일부가 방 밖에 놓여 있어 배치가 아쉬워요.")
        }
        if let safety = breakdown?["safety"], safety < 30 {
            if let door = breakdown?["door_clearance"], door < 15 {
                messages.append("문 앞 통행 공간이 가구로 막힌 부분이 있어 아쉬워요.")
            }
            if let use = breakdown?["furniture_use"], use < 15 {
                messages.append("가구를 사용하기 위한 주변 공간이 충분하지 않은 부분이 있어요.")
            }
            if messages.isEmpty { messages.append("출입과 가구 사용 공간 항목의 점수가 아쉬워요.") }
        }
        if let principles = breakdown?["principles"], principles < 30 {
            let findings: [String: String] = [
                "침대 머리를 벽에 붙여보세요": "침대 머리가 벽에서 떨어져 있어 배치 원칙 점수가 줄었어요.",
                "침대 머리가 문 있는 벽에 있어요": "침대 머리가 문이 있는 벽에 놓인 점이 아쉬워요.",
                "누웠을 때 문이 앞에 보이면 더 좋아요": "침대에서 문이 정면으로 보이지 않는 점이 아쉬워요.",
                "옷장은 문 쪽 벽에 두면 좋아요": "옷장이 문 맞은편 벽에 놓인 점이 아쉬워요.",
                "책상이 문 있는 벽을 등지고 있어요": "책상이 문이 있는 벽을 등지고 있는 점이 아쉬워요."
            ]
            let details = hints.compactMap { findings[$0] }
            messages += details.isEmpty ? ["가구의 위치와 방향에서 배치 원칙에 맞지 않는 부분이 있어요."] : details
        }
        if let space = breakdown?["space"], space < 40 {
            messages.append("사용 가능한 빈 공간을 더 확보할 여지가 있어요.")
        }
        return messages
    }

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

/// Placement guidance follows the same rules as the server scoring system.
struct ChallengePlacementHint: Identifiable {
    let title: String
    let items: [String]
    var id: String { title }

    static let sections: [ChallengePlacementHint] = [
        .init(title: "침대 위치와 방향", items: [
            "침대 머리를 벽에 붙여보세요.",
            "침대 머리는 문이 있는 벽을 피해 배치해보세요.",
            "누웠을 때 문이 앞에 보이도록 방향을 잡아보세요."
        ]),
        .init(title: "옷장과 책상", items: [
            "옷장은 문 맞은편 벽보다 문 쪽 벽에 배치해보세요.",
            "책상은 문이 있는 벽을 등지지 않도록 배치해보세요."
        ]),
        .init(title: "이동과 가구 사용 공간", items: [
            "문 앞을 비워 출입할 수 있는 통로를 확보해주세요.",
            "침대 옆은 한쪽이라도 65cm 정도 비워두면 좋아요.",
            "책상·테이블 앞은 75cm, 옷장 앞은 90cm, 수납장 앞은 70cm 정도의 사용 공간을 확보해보세요."
        ]),
        .init(title: "공간 활용", items: [
            "가구 사이에 흩어진 빈 공간보다 실제로 이동하고 사용할 수 있는 공간을 확보해보세요.",
            "가구끼리 겹치거나 방 밖으로 나가지 않도록 확인해주세요."
        ])
    ]
}
