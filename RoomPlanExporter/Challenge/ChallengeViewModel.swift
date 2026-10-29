import Foundation
import Combine

@MainActor
final class ChallengeViewModel: ObservableObject {
    enum Screen: Equatable { case welcome, entry, criteria, loading, game, submitting, result, layout, leaderboard }
    @Published var screen: Screen = .welcome
    @Published var event: ChallengeEvent?
    @Published var room: ChallengeRoom?
    @Published var result: ChallengeScore?
    @Published private(set) var myLayout: ChallengeMyLayout?
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
    private let loadLastEvent: () -> Int?
    private let saveLastEvent: (Int) -> Void

    init(configuredEventId: Int? = nil,
         serviceProvider: @escaping (Int) -> any ChallengeServing = { ChallengeService(eventId: $0) },
         loadSaved: @escaping () -> ChallengeSavedSession? = ChallengeSessionStore.load,
         saveSaved: @escaping (ChallengeSavedSession) throws -> Void = ChallengeSessionStore.save,
         clearSaved: @escaping () -> Void = ChallengeSessionStore.clear,
         loadLastEvent: @escaping () -> Int? = {
             let id = UserDefaults.standard.integer(forKey: "vo.challenge.lastEvent")
             return id > 0 ? id : nil
         },
         saveLastEvent: @escaping (Int) -> Void = { UserDefaults.standard.set($0, forKey: "vo.challenge.lastEvent") }) {
        let value = Bundle.main.object(forInfoDictionaryKey: "VOChallengeEventID")
        self.configuredEventId = configuredEventId ?? (value as? NSNumber)?.intValue ?? Int(value as? String ?? "") ?? 0
        self.serviceProvider = serviceProvider
        self.loadSaved = loadSaved
        self.saveSaved = saveSaved
        self.clearSaved = clearSaved
        self.loadLastEvent = loadLastEvent
        self.saveLastEvent = saveLastEvent
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
    private(set) var submittedSeconds: Int?

    func loadEvent() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        do {
            var saved = loadSaved()
            if let restored = saved {
                // A saved record remains accessible after its event closes or a new event starts.
                do { event = try await serviceProvider(restored.eventId).event() }
                catch let error as APIError where error.statusCode == 404 {
                    guard restored.pending == nil else { throw error }
                    clearSaved()
                    saved = nil
                    event = try await serviceProvider(configuredEventId).event()
                }
            } else {
                do { event = try await serviceProvider(configuredEventId).event() }
                catch let error as APIError where error.statusCode == 404 {
                    // Keep only a non-sensitive event ID after logout, never the participant token.
                    guard configuredEventId == 0, let previousId = loadLastEvent() else { throw error }
                    event = try await serviceProvider(previousId).event()
                }
            }
            saveLastEvent(eventId)
            participantToken = nil
            pendingSubmission = nil
            hasPendingSubmission = false
            hasSession = false
            remainingAttempts = 0
            result = nil
            myLayout = nil
            if let saved, saved.eventId == eventId {
                participantToken = saved.token
                pendingSubmission = saved.pending
                hasPendingSubmission = saved.pending != nil
                hasSession = true
                let status = try await service.session(token: saved.token)
                remainingAttempts = status.remainingAttempts
                result = status.latestResult
                submittedSeconds = status.elapsedSeconds
            }
        } catch let error as APIError where error.statusCode == 401 {
            forgetParticipant()
            errorMessage = "저장된 참가 정보가 만료됐어요. 다시 등록해 주세요."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resume() async {
        guard !isWorking else { return }
        if hasPendingSubmission { await submit(edits: []) }
        else if result != nil { screen = .result }
        else if remainingAttempts > 0, event?.isActive == true { screen = .criteria }
        else { await loadMyLayout(showComparison: false) }
    }

    func sceneLoaded() {
        sceneReady = true
        sceneError = nil
        if pendingSubmission == nil, startedAt == nil { startedAt = Date() }
    }

    var canSwitchParticipant: Bool { !isWorking && !hasPendingSubmission }

    @discardableResult
    func beginNewParticipant() async -> Bool {
        guard canSwitchParticipant else { return false }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        if let participantToken {
            do { try await service.leaveSession(token: participantToken) }
            catch let error as APIError where error.statusCode == 401 {
                // A rotated/revoked token is already signed out on the server.
            } catch {
                // Keep the identity locked until revocation succeeds; never silently switch visitors.
                errorMessage = error.localizedDescription
                return false
            }
        }
        forgetParticipant()
        screen = .entry
        return true
    }

    func forgetParticipant() {
        clearSaved()
        participantToken = nil
        pendingSubmission = nil
        hasPendingSubmission = false
        hasSession = false
        remainingAttempts = 0
        result = nil
        myLayout = nil
        submittedSeconds = nil
        sceneReady = false
        sceneError = nil
        restart()
    }

    func start(name: String, phone: String) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        screen = .loading
        do {
            let registration = try await service.register(name: name, phone: phone)
            // Re-entry rotates the token, including when there are no attempts left.
            participantToken = registration.participantToken
            hasSession = true
            remainingAttempts = registration.remainingAttempts
            result = nil
            myLayout = nil
            submittedSeconds = nil
            room = nil
            pendingSubmission = nil
            hasPendingSubmission = false
            sceneReady = false
            startedAt = nil
            try saveSession()
            screen = remainingAttempts > 0 && event?.isActive == true ? .criteria : .welcome
            if registration.isReturning == true || remainingAttempts == 0 {
                do {
                    let layout = try await service.myLayout(token: registration.participantToken)
                    myLayout = layout
                    result = layout.result
                    remainingAttempts = layout.result.remainingAttempts
                    // Session contains elapsed time, which my-layout's result may omit.
                    if let status = try? await service.session(token: registration.participantToken) {
                        submittedSeconds = status.elapsedSeconds
                    }
                    screen = .welcome
                } catch let error as APIError where error.statusCode == 404 {
                    // Returning participants may have registered without submitting yet.
                    if remainingAttempts == 0 { errorMessage = error.localizedDescription }
                } catch let error as APIError where error.statusCode == 401 {
                    forgetParticipant()
                    screen = .entry
                    errorMessage = "참가 정보가 만료됐어요. 다시 들어와 주세요."
                } catch {
                    screen = .welcome
                    errorMessage = error.localizedDescription
                }
            }
        } catch {
            screen = hasSession ? .welcome : .entry
            errorMessage = error.localizedDescription
        }
    }

    func loadMyLayout(showComparison: Bool = true) async {
        guard !isWorking, let participantToken else { return }
        let previousScreen = screen
        isWorking = true
        screen = .loading
        errorMessage = nil
        defer { isWorking = false }
        do {
            let layout = try await service.myLayout(token: participantToken)
            myLayout = layout
            result = layout.result
            remainingAttempts = layout.result.remainingAttempts
            screen = showComparison ? .layout : .result
        } catch let error as APIError where error.statusCode == 401 {
            forgetParticipant()
            screen = .entry
            errorMessage = "참가 정보가 만료됐어요. 다시 들어와 주세요."
        } catch {
            screen = previousScreen
            errorMessage = error.localizedDescription
        }
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
            myLayout = nil
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
                    submittedSeconds = status.elapsedSeconds
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
        guard !isWorking, !hasPendingSubmission else { return }
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

