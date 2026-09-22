import Foundation

// MARK: - ChatMessage

struct ChatMessage: Identifiable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
}

// MARK: - AssistantViewModel
//
// 대화 상태 + Claude tool-use 루프를 담당한다. 실제 계산은 절대 여기서 하지 않고
// RoomFitCalculator에 위임 — 이 클래스는 "언제 tool을 호출했고 그 결과를 어떻게
// 대화에 다시 넣을지"만 관리한다.

@MainActor
final class AssistantViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isLoading: Bool = false
    @Published var isRoomLoading: Bool = true
    @Published var errorText: String? = nil
    /// simulate_without이 마지막으로 가리킨 가구 — 3D 뷰에서 이 식별자를 실제로 숨긴다.
    @Published var hiddenFurnitureIdentifiers: Set<String> = []

    private let service = AssistantService()
    private let dataURLString: String
    private var room: RoomDataPayload?
    private var apiMessages: [[String: Any]] = []

    private let systemPrompt = """
    당신은 V-O 앱의 'AI 배치 상담'이에요. 사용자가 LiDAR로 스캔한 실제 방 데이터를 바탕으로 \
    가구를 어디에 놓을 수 있는지, 특정 가구를 빼면 공간이 얼마나 넓어지는지 자연어로 설명해요. \
    좌표나 면적 계산은 절대 스스로 추정하지 말고, 반드시 suggest_placement / simulate_without \
    tool을 호출해서 받은 결과만 근거로 답변해요. 정중한 한국어 존댓말로 2~3문장 이내로 짧게 답해요.
    """

    init(dataURLString: String) {
        self.dataURLString = dataURLString
    }

    func loadRoomIfNeeded() async {
        guard room == nil, let url = URL(string: dataURLString) else {
            isRoomLoading = false
            errorText = AssistantError.roomLoadFailed.errorDescription
            return
        }
        isRoomLoading = true
        defer { isRoomLoading = false }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            room = try JSONDecoder().decode(RoomDataPayload.self, from: data)
        } catch {
            print("❌ AI 배치 상담 방 데이터 로드 실패: \(error)")
            errorText = AssistantError.roomLoadFailed.errorDescription
        }
    }

    /// 채팅 모드를 나갈 때 숨겨둔 가구를 다시 보이게 복원
    func showAllFurniture() {
        hiddenFurnitureIdentifiers = []
    }

    func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoading, room != nil else { return }
        inputText = ""
        messages.append(ChatMessage(role: .user, text: text))
        apiMessages.append(["role": "user", "content": [["type": "text", "text": text]]])

        Task {
            isLoading = true
            defer { isLoading = false }
            await runTurn()
        }
    }

    /// tool_use가 나오면 로컬에서 계산해 결과를 다시 넣고, 최종 텍스트가 나올 때까지 반복.
    /// 무한 루프 방지를 위해 최대 5회로 제한.
    private func runTurn() async {
        guard let room else { return }
        do {
            for _ in 0..<5 {
                let result = try await service.send(messages: apiMessages, system: systemPrompt)

                if !result.toolUses.isEmpty {
                    apiMessages.append(["role": "assistant", "content": result.assistantContent])

                    let toolResultBlocks: [[String: Any]] = result.toolUses.map { use in
                        let summary = executeTool(name: use.name, input: use.input, room: room)
                        return ["type": "tool_result", "tool_use_id": use.id, "content": summary]
                    }
                    apiMessages.append(["role": "user", "content": toolResultBlocks])
                    continue
                }

                if let text = result.text {
                    apiMessages.append(["role": "assistant", "content": result.assistantContent])
                    messages.append(ChatMessage(role: .assistant, text: text))
                }
                return
            }
            errorText = "요청이 너무 복잡해서 답을 정리하지 못했어요. 다시 물어봐 주세요."
        } catch {
            print("❌ AI 배치 상담 요청 실패: \(error)")
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func executeTool(name: String, input: [String: Any], room: RoomDataPayload) -> String {
        switch name {
        case "suggest_placement":
            let width = input["width_cm"] as? Double ?? 0
            let depth = input["depth_cm"] as? Double ?? 0
            return RoomFitCalculator.suggestPlacement(in: room, widthCm: width, depthCm: depth).summary
        case "simulate_without":
            let query = input["furniture_query"] as? String ?? ""
            let result = RoomFitCalculator.simulateWithout(in: room, query: query)
            // 3D 뷰에 실제로 반영 — 마지막으로 물어본 가구만 숨김 (누적하지 않음)
            hiddenFurnitureIdentifiers = result.identifier.map { [$0] } ?? []
            return result.summary
        default:
            return "지원하지 않는 요청이에요."
        }
    }
}
