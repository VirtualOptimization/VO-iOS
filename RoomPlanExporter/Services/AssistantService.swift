import Foundation

// MARK: - AI 배치 상담 (Claude API, tool use)
//
// 좌표·면적 계산은 절대 여기서 하지 않는다 — Claude는 사용자 의도를 이해해서 tool을
// 호출할지 판단하고, 결과를 자연어로 설명하는 역할만 한다. 실제 계산은 RoomFitCalculator가
// 결정론적으로 수행한다 (AssistantViewModel이 tool_use를 받아 호출).
//
// Claude API 키는 앱에 두지 않는다 (앱을 뜯으면 키가 그대로 노출됨) — 로그인 토큰으로 우리
// 서버를 호출하고, 서버가 자기 키로 Claude에 중계한다. 모델과 토큰 상한도 서버가 정한다.

actor AssistantService {

    private let endpoint = URL(string: "\(APIConfig.baseURL)/assistant/messages")!

    struct TurnResult {
        let assistantContent: [[String: Any]]   // 다음 턴에 그대로 대화 기록으로 넣을 원본 content
        let text: String?                       // 이번 턴의 최종 텍스트 답변 (있을 때만)
        let toolUses: [(id: String, name: String, input: [String: Any])]
    }

    /// 대화 히스토리(messages)를 보내고 한 턴의 응답을 받는다. tool_use가 있으면 text는 nil일 수 있다.
    func send(messages: [[String: Any]], system: String) async throws -> TurnResult {
        guard let accessToken = KeychainTokenStore.get(.accessToken) else {
            throw AssistantError.apiError
        }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30

        let body: [String: Any] = [
            "system": system,
            "messages": messages,
            "tools": Self.toolDefinitions
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            print("❌ AI 배치 상담 \((response as? HTTPURLResponse)?.statusCode ?? -1): \(msg)")
            throw AssistantError.apiError
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw AssistantError.invalidResponse
        }

        var text = ""
        var toolUses: [(id: String, name: String, input: [String: Any])] = []
        for block in content {
            guard let type = block["type"] as? String else { continue }
            switch type {
            case "text":
                text += (block["text"] as? String) ?? ""
            case "tool_use":
                guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
                toolUses.append((id, name, block["input"] as? [String: Any] ?? [:]))
            default:
                break
            }
        }
        return TurnResult(assistantContent: content, text: text.isEmpty ? nil : text, toolUses: toolUses)
    }

    // MARK: - Tool 정의 (F02 배치 제안 / F03 가구 제외 시뮬레이션)

    static let toolDefinitions: [[String: Any]] = [
        [
            "name": "suggest_placement",
            "description": "사용자가 방에 넣고 싶어하는 가구의 실제 치수(cm)를 받아, 현재 스캔된 방 안에서 기존 가구와 겹치지 않고 벽 밖으로 나가지 않는 위치를 찾는다. 좌표 계산은 이 tool이 전담하므로 직접 추정하지 말고 반드시 호출한다.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "width_cm": ["type": "number", "description": "가구의 가로 폭 (cm)"],
                    "depth_cm": ["type": "number", "description": "가구의 세로 깊이 (cm)"]
                ],
                "required": ["width_cm", "depth_cm"]
            ]
        ],
        [
            "name": "simulate_without",
            "description": "방에 있는 특정 가구를 실제로 지우지 않고, 뺐다고 가정했을 때 확보되는 바닥 면적과 방 전체 대비 비율을 계산한다.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "furniture_query": ["type": "string", "description": "제외해볼 가구를 가리키는 한국어 표현. 예: '책상', '침대', '옷장'"]
                ],
                "required": ["furniture_query"]
            ]
        ]
    ]
}

enum AssistantError: LocalizedError {
    case apiError
    case invalidResponse
    case roomLoadFailed

    var errorDescription: String? {
        switch self {
        case .apiError:       return "AI 배치 상담 요청이 실패했어요"
        case .invalidResponse: return "응답을 이해하지 못했어요"
        case .roomLoadFailed:  return "방 데이터를 불러오지 못했어요"
        }
    }
}
