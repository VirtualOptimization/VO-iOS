import Foundation

struct ChallengeEvent: Decodable {
    let eventId: Int
    let name: String
    let isActive: Bool
    let maxAttempts: Int
    let maxScore: Double
    let criteria: [ChallengeCriterion]
    let disqualifyRules: [String]
    var penaltyRules: [String]? = nil
    enum CodingKeys: String, CodingKey {
        case eventId = "event_id", name, isActive = "is_active"
        case maxAttempts = "max_attempts", maxScore = "max_score"
        case criteria, disqualifyRules = "disqualify_rules", penaltyRules = "penalty_rules"
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

    /// Nil means an older result did not report the extra penalty.
    var placementPenalty: Double? {
        guard let value = breakdown?["penalty"], value.isFinite, value >= 0 else { return nil }
        return value
    }

    var strengths: [String] {
        var messages: [String] = []
        if let door = breakdown?["door_clearance"], door >= 12 {
            messages.append(door >= 15 ? "문 앞 통행 공간 항목에서 15점 만점을 받았어요." : "문 앞 통행 공간 항목에서 좋은 점수를 받았어요.")
        }
        if let use = breakdown?["furniture_use"], use >= 12 {
            messages.append(use >= 15 ? "가구 사용 공간 항목에서 15점 만점을 받았어요." : "가구 주변의 사용 공간 항목에서 좋은 점수를 받았어요.")
        }
        if breakdown?["door_clearance"] == nil, breakdown?["furniture_use"] == nil,
           let safety = breakdown?["safety"], safety >= 24 {
            messages.append(safety >= 30 ? "안전·동선 항목에서 30점 만점을 받았어요." : "안전·동선 항목에서 좋은 점수를 받았어요.")
        }
        if let principles = breakdown?["principles"], principles >= 24 {
            messages.append(principles >= 30 ? "생활 원칙 항목에서 30점 만점을 받았어요." : "가구의 위치와 방향을 평가하는 생활 원칙 항목에서 좋은 점수를 받았어요.")
        }
        if beatAI {
            messages.append("사용 가능한 여유 공간이 AI 배치보다 넓어요.")
        } else if let space = breakdown?["space"], space >= 32 {
            messages.append(space >= 40 ? "여유 공간 항목에서 40점 만점을 받았어요." : "이동하고 사용할 수 있는 여유 공간 항목에서 좋은 점수를 받았어요.")
        }
        if placementPenalty == 0 {
            messages.append("가구 겹침·방 밖 배치로 인한 추가 감점이 없어요.")
        }
        return messages
    }

    private var placementFindings: [String] {
        hints.compactMap { hint in
            let overlap = hint.replacingOccurrences(
                of: #"^가구 ([0-9]+)쌍이 겹쳐 있어요 \(-([0-9]+)점\)$"#,
                with: "가구 $1쌍이 겹쳐 $2점 감점됐어요.", options: .regularExpression)
            if overlap != hint { return overlap }
            let outside = hint.replacingOccurrences(
                of: #"^가구 ([0-9]+)개가 방 밖으로 나가 있어요 \(-([0-9]+)점\)$"#,
                with: "가구 $1개가 방 밖으로 나가 $2점 감점됐어요.", options: .regularExpression)
            if outside != hint { return outside }
            // Older saved results have no count or penalty amount.
            if hint == "가구끼리 겹쳐 있어요" { return "가구끼리 겹쳐 있는 부분이 있어 사용하기 불편할 수 있어요." }
            if hint == "가구가 방 밖으로 나가 있어요" { return "가구 일부가 방 밖에 놓여 있어 배치가 아쉬워요." }
            return nil
        }
    }

    var improvements: [String] {
        var messages = placementFindings
        if let penalty = placementPenalty, penalty > 0, messages.isEmpty {
            messages.append("가구 겹침·방 밖 배치로 총 \(String(format: "%.0f", penalty))점 추가 감점됐어요.")
        }
        if let safety = breakdown?["safety"], safety < 30 {
            var safetyMessages: [String] = []
            if let door = breakdown?["door_clearance"], door < 15 {
                safetyMessages.append("문 앞이 가구로 막힌 부분이 있어 통행 공간 점수가 줄었어요.")
            }
            if let use = breakdown?["furniture_use"], use < 15 {
                safetyMessages.append("침대 옆이나 책상·수납장 앞의 사용 공간이 부족한 부분이 있어요.")
            }
            messages += safetyMessages.isEmpty ? ["안전·동선 항목에서 만점을 받지 못했어요."] : safetyMessages
        }
        if let principles = breakdown?["principles"], principles < 30 {
            let findings: [String: String] = [
                "침대 머리를 벽에 붙여보세요": "침대 머리가 벽에서 떨어져 있어 생활 원칙 점수가 줄었어요.",
                "침대 머리가 문 있는 벽에 있어요": "침대 머리가 문이 있는 벽에 놓여 생활 원칙 점수가 줄었어요.",
                "누웠을 때 문이 앞에 보이면 더 좋아요": "침대에서 문이 앞쪽에 있지 않아 생활 원칙 점수가 줄었어요.",
                "옷장은 문 쪽 벽에 두면 좋아요": "옷장이 문 맞은편 벽에 놓여 생활 원칙 점수가 줄었어요.",
                "책상이 문 있는 벽을 등지고 있어요": "책상이 문이 있는 벽을 등지고 있어 생활 원칙 점수가 줄었어요."
            ]
            let details = hints.compactMap { findings[$0] }
            messages += details.isEmpty ? ["가구의 위치와 방향에서 생활 원칙을 충족하지 못한 부분이 있어요."] : details
        }
        if let space = breakdown?["space"], space < 40 {
            messages.append("넓게 연결된 여유 공간이 기준보다 작아 공간 점수가 줄었어요.")
        }
        // One furniture type can produce the same finding more than once.
        var seen = Set<String>()
        return messages.filter { seen.insert($0).inserted }
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

    static let defaultPenaltyRules = ["겹친 가구 한 쌍마다 -5점", "방 밖으로 나간 가구 하나마다 -5점"]

    static func criterionDescription(key: String, fallback: String) -> String {
        switch key {
        case "safety": "문 앞 통행 공간 15점과 가구 사용 공간 15점을 합산해요.\n필요한 공간을 확보한 비율에 따라 부분 점수를 받아요."
        case "principles": "침대 머리와 문의 관계, 옷장·책상의 위치와 방향을 평가해요.\n방에 있는 가구에 적용되는 원칙의 충족률로 계산해요."
        case "space": "폭 약 80cm의 이동 공간을 확보할 수 있는 가장 큰 연결 공간을 AI 배치와 비교해요.\nAI 수준이면 40점이며, 더 넓어도 40점이 상한이에요."
        default: fallback
        }
    }

    static let sections: [ChallengePlacementHint] = [
        .init(title: "안전·동선 · 30점", items: [
            "문 앞을 비워, 드나드는 길을 막지 마세요."
        ]),
        .init(title: "생활 원칙 · 30점", items: [
            "옷장은 문 맞은편 벽을 피해 놓으세요."
        ]),
        .init(title: "여유 공간 · 40점", items: [
            "빈 공간이 나뉘지 않게, 넓은 공간 하나로 연결해주세요."
        ])
    ]
}
