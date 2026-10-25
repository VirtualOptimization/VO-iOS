import Foundation
import Combine

@MainActor
final class ChallengeViewModel: ObservableObject {
    enum Screen: Equatable { case welcome, entry, criteria, loading, game, submitting, result, leaderboard }
    @Published var screen: Screen = .welcome
    @Published var event: ChallengeEvent?
    @Published var room: ChallengeRoom?
    @Published var result: ChallengeScore?
    @Published var ranking: ChallengeLeaderboard?
    @Published var errorMessage: String?
    @Published var seconds = 0
    @Published var isWorking = false
    @Published private(set) var hasPendingSubmission = false
    @Published private(set) var hasSession = false
    @Published private(set) var remainingAttempts = 0
    @Published var sceneReady = false
    @Published var sceneError: String?
    private var rankingReturnScreen: Screen = .welcome

    private let configuredEventId: Int
    private let serviceProvider: (Int) -> any ChallengeServing
    private let loadSaved: () -> ChallengeSavedSession?
    private let saveSaved: (ChallengeSavedSession) throws -> Void
    private let clearSaved: () -> Void

    init(configuredEventId: Int? = nil,
         serviceProvider: @escaping (Int) -> any ChallengeServing = { ChallengeService(eventId: $0) },
         loadSaved: @escaping () -> ChallengeSavedSession? = ChallengeSessionStore.load,
         saveSaved: @escaping (ChallengeSavedSession) throws -> Void = ChallengeSessionStore.save,
         clearSaved: @escaping () -> Void = ChallengeSessionStore.clear) {
        let value = Bundle.main.object(forInfoDictionaryKey: "VOChallengeEventID")
        self.configuredEventId = configuredEventId ?? (value as? NSNumber)?.intValue ?? Int(value as? String ?? "") ?? 0
        self.serviceProvider = serviceProvider
        self.loadSaved = loadSaved
        self.saveSaved = saveSaved
        self.clearSaved = clearSaved
    }

    var eventId: Int { event?.eventId ?? configuredEventId }
    private var service: any ChallengeServing { serviceProvider(eventId) }
    private var participantToken: String?
    private var startedAt: Date?
    private var pendingSubmission: ChallengePendingSubmission?

    private func saveSession() throws {
        guard let participantToken else { return }
        try saveSaved(ChallengeSavedSession(eventId: eventId, token: participantToken,
                                                              pending: pendingSubmission))
    }
    private(set) var submittedSeconds = 0

    func loadEvent() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        do {
            let saved = loadSaved()
            if let saved, saved.pending != nil {
                // Retry belongs to its original event even if no event is active now.
                event = try await serviceProvider(saved.eventId).event()
            } else {
                do { event = try await serviceProvider(configuredEventId).event() }
                catch let error as APIError where error.statusCode == 404 {
                    guard let saved else { throw error }
                    event = try await serviceProvider(saved.eventId).event()
                }
            }
            participantToken = nil
            pendingSubmission = nil
            hasPendingSubmission = false
            hasSession = false
            remainingAttempts = 0
            result = nil
            if let saved, saved.eventId == eventId {
                participantToken = saved.token
                pendingSubmission = saved.pending
                hasPendingSubmission = saved.pending != nil
                hasSession = true
                let status = try await service.session(token: saved.token)
                remainingAttempts = status.remainingAttempts
                result = status.latestResult
                submittedSeconds = status.elapsedSeconds ?? 0
            }
        } catch let error as APIError where error.statusCode == 401 {
            forgetParticipant()
            errorMessage = "저장된 참가 정보가 만료됐어요. 다시 등록해 주세요."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resume() async {
        if hasPendingSubmission { await submit(edits: []) }
        else if result != nil { screen = .result }
        else if remainingAttempts > 0 { screen = .criteria }
        else { errorMessage = "이미 도전 횟수를 모두 사용했어요." }
    }

    func sceneLoaded() {
        sceneReady = true
        sceneError = nil
        if pendingSubmission == nil, startedAt == nil { startedAt = Date() }
    }

    func forgetParticipant() {
        clearSaved()
        participantToken = nil
        pendingSubmission = nil
        hasPendingSubmission = false
        hasSession = false
        remainingAttempts = 0
        result = nil
        restart()
    }

    func start(name: String, phone: String) async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        screen = .loading
        do {
            let registration = try await service.register(name: name, phone: phone)
            guard registration.remainingAttempts > 0 else {
                screen = .entry
                errorMessage = "이미 도전 횟수를 모두 사용했어요."
                isWorking = false
                return
            }
            participantToken = registration.participantToken
            hasSession = true
            remainingAttempts = registration.remainingAttempts
            screen = .criteria
            try saveSession()
        } catch {
            screen = hasSession ? .criteria : .entry
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }

    func loadRoom() async {
        guard !isWorking, let participantToken else { return }
        isWorking = true
        errorMessage = nil
        screen = .loading
        do {
            room = try await service.room(token: participantToken)
            remainingAttempts = room?.remainingAttempts ?? 0
            guard remainingAttempts > 0 || hasPendingSubmission else {
                screen = result == nil ? .criteria : .result
                errorMessage = "이미 도전 횟수를 모두 사용했어요."
                isWorking = false
                return
            }
            seconds = pendingSubmission?.elapsed ?? 0
            startedAt = nil
            sceneReady = false
            sceneError = nil
            screen = .game
        } catch {
            screen = .criteria
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }

    func updateElapsed() {
        guard screen == .game, !hasPendingSubmission, let startedAt else { return }
        seconds = max(0, Int(Date().timeIntervalSince(startedAt)))
    }

    var canSubmit: Bool {
        !isWorking && participantToken != nil && (hasPendingSubmission || (room != nil && sceneReady))
    }

    func submit(edits: [FurniturePoseEdit]) async {
        guard canSubmit, let participantToken else { return }
        isWorking = true
        defer { isWorking = false }
        screen = .submitting
        errorMessage = nil
        if pendingSubmission == nil {
            let elapsed = max(0, Int(Date().timeIntervalSince(startedAt ?? Date())))
            pendingSubmission = ChallengePendingSubmission(key: UUID(), elapsed: elapsed,
                                                  objects: edits.map(ChallengeObjectEdit.init(pose:)))
            hasPendingSubmission = true
            seconds = elapsed
        }
        guard let submission = pendingSubmission else { return }
        do {
            try saveSession()
            result = try await service.submit(token: participantToken, elapsed: submission.elapsed,
                                              objects: submission.objects, key: submission.key)
            submittedSeconds = submission.elapsed
            remainingAttempts = result?.remainingAttempts ?? 0
            pendingSubmission = nil
            hasPendingSubmission = false
            screen = .result
            try saveSession()
        } catch let apiError as APIError where (400..<500).contains(apiError.statusCode) && ![408, 429].contains(apiError.statusCode) {
            pendingSubmission = nil
            hasPendingSubmission = false
            screen = room == nil ? .welcome : .game
            try? saveSession()
            if apiError.statusCode == 401 {
                forgetParticipant()
            } else if apiError.statusCode == 409,
                      let status = try? await service.session(token: participantToken) {
                remainingAttempts = status.remainingAttempts
                if let latest = status.latestResult {
                    result = latest
                    submittedSeconds = status.elapsedSeconds ?? 0
                    screen = .result
                } else { screen = .criteria }
            }
            errorMessage = apiError.localizedDescription
        } catch {
            screen = room == nil ? .welcome : .game
            errorMessage = error.localizedDescription
        }
    }

    func loadRanking() async {
        guard !isWorking, event != nil else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let response = try await service.leaderboard()
            guard response.eventId == eventId else {
                throw APIError(statusCode: 0, detail: "이벤트가 바뀌었어요. 다시 불러와 주세요.")
            }
            if screen != .leaderboard { rankingReturnScreen = screen }
            ranking = response
            screen = .leaderboard
        } catch { errorMessage = error.localizedDescription }
    }

    func closeRanking() { screen = rankingReturnScreen }

    func leaveGame() {
        room = nil
        seconds = 0
        startedAt = nil
        pendingSubmission = nil
        hasPendingSubmission = false
        screen = .criteria
    }

    func restart() {
        room = nil
        ranking = nil
        seconds = 0
        startedAt = nil
        errorMessage = nil
        screen = .welcome
    }
}

