import Foundation

final class MockChallengeAPI: ChallengeServing {
    var eventValue = ChallengeEvent(eventId: 7, name: "전시 챌린지", isActive: true, maxAttempts: 2,
                                    maxScore: 100, criteria: [], disqualifyRules: [])
    var status = ChallengeParticipantSession(remainingAttempts: 2, latestResult: nil, elapsedSeconds: nil)
    var failNextSubmission = true
    var submitted: [(UUID, Int, [ChallengeObjectEdit])] = []
    var roomCalls = 0
    var registration = ChallengeRegistration(participantToken: "test-token", remainingAttempts: 2)
    var registrationError: APIError?
    var layoutValue: ChallengeMyLayout?
    var layoutError: APIError?
    var leaveError: APIError?
    var layoutTokens: [String] = []
    var leaveTokens: [String] = []
    func event() async throws -> ChallengeEvent { eventValue }
    func register(name: String, phone: String) async throws -> ChallengeRegistration {
        if let registrationError { throw registrationError }
        return registration
    }
    func session(token: String) async throws -> ChallengeParticipantSession { status }
    func room(token: String) async throws -> ChallengeRoom {
        roomCalls += 1
        let detail = try JSONDecoder().decode(RoomVersionDetail.self, from: Data(#"{"data_url":"https://test/layout"}"#.utf8))
        return ChallengeRoom(detail: detail, remainingAttempts: 2)
    }
    func myLayout(token: String) async throws -> ChallengeMyLayout {
        layoutTokens.append(token)
        if let layoutError { throw layoutError }
        guard let layoutValue else { throw APIError(statusCode: 404, detail: "아직 제출한 배치가 없어요.") }
        return layoutValue
    }
    func leaveSession(token: String) async throws {
        leaveTokens.append(token)
        if let leaveError { throw leaveError }
    }
    func submit(token: String, elapsed: Int, objects: [ChallengeObjectEdit], key: UUID) async throws -> ChallengeScore {
        submitted.append((key, elapsed, objects))
        if failNextSubmission { failNextSubmission = false; throw URLError(.timedOut) }
        return ChallengeScore(attemptId: 1, totalScore: 90, maxScore: 100, disqualified: false,
                              breakdown: [:], hints: [], beatAI: true, aiScore: 80, rank: 1,
                              totalRanked: 1, remainingAttempts: 1)
    }
    func leaderboard() async throws -> ChallengeLeaderboard {
        ChallengeLeaderboard(eventId: 7, totalRanked: 1, aiScore: 80, entries: [])
    }
}

@main struct ChallengeFlowTests {
    @MainActor static func main() async throws {
        let api = MockChallengeAPI()
        var saved: ChallengeSavedSession?
        var resolvedIDs: [Int] = []
        func makeVM() -> ChallengeViewModel {
            ChallengeViewModel(configuredEventId: 0, serviceProvider: { id in resolvedIDs.append(id); return api },
                               loadSaved: { saved }, saveSaved: { saved = $0 }, clearSaved: { saved = nil }, loadLastEvent: { nil }, saveLastEvent: { _ in })
        }
        let vm = makeVM()
        await vm.loadEvent()
        precondition(resolvedIDs.first == 0 && vm.eventId == 7, "current event resolution")
        await vm.start(name: "visitor", phone: "01012345678")
        precondition(saved?.eventId == 7 && vm.hasSession && vm.remainingAttempts == 2)
        await vm.loadRoom()
        precondition(!vm.canSubmit, "button remains disabled before scene readiness")
        await vm.submit(edits: [])
        precondition(api.submitted.isEmpty, "submission blocked before scene readiness")
        vm.sceneLoaded()
        precondition(vm.canSubmit, "loaded scene enables confirmation and submission")
        vm.isWorking = true
        precondition(!vm.canSubmit, "duplicate submission blocked while working")
        vm.isWorking = false
        await vm.submit(edits: [])
        precondition(vm.hasPendingSubmission && saved?.pending != nil, "failed request is persisted")
        precondition(!vm.canSwitchParticipant)
        await vm.beginNewParticipant()
        vm.leaveGame()
        precondition(vm.hasSession && vm.hasPendingSubmission && saved?.pending != nil, "pending submission survives participant/exit actions")
        let savedPending = saved!
        let key = savedPending.pending!.key
        vm.sceneReady = false
        precondition(vm.canSubmit, "durable retry does not require the scene to load again")
        let edited = FurniturePoseEdit(identifier: "bed", center: [1,2,3], rotation: [0,0,0])
        await vm.submit(edits: [edited])
        precondition(api.submitted.count == 2 && api.submitted.allSatisfy { $0.0 == key && $0.2.isEmpty }, "retry reuses exact key and body")
        precondition(vm.screen == .result && vm.remainingAttempts == 1 && saved?.pending == nil)
        await vm.loadRanking()
        vm.closeRanking()
        precondition(vm.screen == .result, "ranking returns to result without clearing session")
        vm.restart()
        await vm.resume()
        precondition(vm.screen == .result && vm.hasSession)
        await vm.loadRoom()
        precondition(vm.screen == .game && !vm.sceneReady)

        // App terminated after a successful server commit but before receiving
        // the response. Retry directly even with zero attempts left/no room.
        saved = savedPending
        api.status = ChallengeParticipantSession(remainingAttempts: 0, latestResult: vm.result, elapsedSeconds: 65)
        resolvedIDs = []
        let restored = makeVM()
        await restored.loadEvent()
        precondition(resolvedIDs.first == 7, "pending recovery never depends on an active current event")
        let roomCalls = api.roomCalls
        await restored.resume()
        precondition(restored.screen == .result && api.roomCalls == roomCalls)
        precondition(api.submitted.last!.0 == key && saved?.pending == nil)

        let resultRestore = makeVM()
        await resultRestore.loadEvent()
        await resultRestore.resume()
        precondition(resultRestore.screen == .result && resultRestore.submittedSeconds == 65)
        resultRestore.isWorking = true
        await resultRestore.beginNewParticipant()
        precondition(resultRestore.hasSession, "participant switch blocked during request")
        resultRestore.isWorking = false
        precondition(resultRestore.canSwitchParticipant)
        await resultRestore.beginNewParticipant()
        precondition(saved == nil && !resultRestore.hasSession && resultRestore.screen == .entry,
                     "new participant action clears local session and opens entry directly")

        precondition(api.leaveTokens == ["test-token"], "successful visitor switch revokes the server token")

        // Re-entering with zero attempts replaces the token and lands on the home with a result.
        let priorScore = ChallengeScore(attemptId: 4, totalScore: 72.5, maxScore: 100, disqualified: false,
            breakdown: ["safety": 25], hints: [], beatAI: false, aiScore: nil, rank: 3,
            totalRanked: 40, remainingAttempts: 0)
        let detail = try JSONDecoder().decode(RoomVersionDetail.self, from: Data(#"{"ios_objects":[]}"#.utf8))
        api.layoutValue = ChallengeMyLayout(result: priorScore, submitted: detail, start: detail)
        api.registration = ChallengeRegistration(participantToken: "rotated-token", remainingAttempts: 0, isReturning: true)
        api.status = ChallengeParticipantSession(remainingAttempts: 0, latestResult: priorScore, elapsedSeconds: 80)
        let returning = makeVM()
        await returning.loadEvent()
        await returning.start(name: "visitor", phone: "01012345678")
        precondition(returning.screen == .welcome && returning.hasSession && saved?.token == "rotated-token")
        precondition(returning.result?.totalScore == 72.5 && returning.submittedSeconds == 80)
        precondition(api.layoutTokens.last == "rotated-token", "my-layout uses only the new participant token")
        let priorRoomCalls = api.roomCalls
        await returning.resume()
        precondition(returning.screen == .result && api.roomCalls == priorRoomCalls, "zero attempts never starts placement")
        await returning.loadMyLayout()
        precondition(returning.screen == .layout && returning.myLayout?.result.attemptId == 4)
        await returning.loadRanking()
        returning.closeRanking()
        precondition(returning.screen == .layout)
        api.layoutError = APIError(statusCode: 404, detail: "아직 제출한 배치가 없어요.")
        await returning.loadMyLayout()
        precondition(returning.screen == .layout && returning.errorMessage?.contains("아직 제출") == true)
        api.layoutError = nil

        // Network failure while signing out keeps the visitor locked in; retry can revoke later.
        api.leaveError = APIError(statusCode: 0, detail: "연결 실패")
        let failedExit = await returning.beginNewParticipant()
        precondition(!failedExit && returning.hasSession && saved?.token == "rotated-token")
        api.leaveError = nil
        let didExit = await returning.beginNewParticipant()
        precondition(didExit && !returning.hasSession && returning.myLayout == nil && saved == nil)
        precondition(api.leaveTokens.last == "rotated-token")

        // A registration conflict does not grant access to another participant's record.
        api.registrationError = APIError(statusCode: 409, detail: "다른 닉네임으로 참여한 번호예요.")
        await returning.start(name: "other", phone: "01012345678")
        precondition(!returning.hasSession && returning.screen == .entry && saved == nil)
        api.registrationError = nil

        // Saved sessions restore their original closed event even when a newer event is configured.
        saved = ChallengeSavedSession(eventId: 7, token: "closed-event-token", pending: nil)
        api.eventValue = ChallengeEvent(eventId: 7, name: "종료 전시", isActive: false, maxAttempts: 1,
            maxScore: 100, criteria: [], disqualifyRules: [])
        resolvedIDs = []
        let closed = makeVM()
        await closed.loadEvent()
        await closed.loadMyLayout()
        precondition(resolvedIDs.first == 7 && closed.screen == .layout)
        api.layoutError = APIError(statusCode: 401, detail: "만료")
        await closed.loadMyLayout()
        precondition(!closed.hasSession && closed.screen == .entry && saved == nil && closed.myLayout == nil)
        api.layoutError = nil
        api.eventValue = ChallengeEvent(eventId: 7, name: "전시", isActive: true, maxAttempts: 1,
            maxScore: 100, criteria: [], disqualifyRules: [])
        api.registration = ChallengeRegistration(participantToken: "unsubmitted", remainingAttempts: 1, isReturning: true)
        api.layoutValue = nil
        let unfinished = makeVM()
        await unfinished.loadEvent()
        await unfinished.start(name: "visitor", phone: "01012345678")
        precondition(unfinished.screen == .criteria && unfinished.hasSession, "404 on a returning unsubmitted participant still allows the challenge")
        api.leaveError = APIError(statusCode: 401, detail: "이전 토큰")
        let alreadyRevoked = await unfinished.beginNewParticipant()
        precondition(alreadyRevoked && saved == nil)
        try await ChallengeAPITests.run()

        let endedEntry = ChallengeViewModel(configuredEventId: 0, serviceProvider: { id in
            if id == 0 { return MissingCurrentEventAPI() }
            return api
        }, loadSaved: { nil }, saveSaved: { _ in }, clearSaved: {},
           loadLastEvent: { 7 }, saveLastEvent: { _ in })
        await endedEntry.loadEvent()
        precondition(endedEntry.eventId == 7 && !endedEntry.hasSession, "event metadata survives logout without preserving participant identity")

        // The submitted matrix keeps RoomPlan's column-vector convention.
        let object = ChallengeObjectEdit(pose: FurniturePoseEdit(identifier:"bed",center:[1,2,3],rotation:[0,.pi/2,0]))
        precondition(abs(object.transform[0][2] - 1) < 0.0001 && object.transform[3] == [1,2,3,1])
        let validation = APIError.from(statusCode: 422, data: Data(#"{"detail":[{"msg":"Value error, 잘못된 좌표"}]}"#.utf8))
        precondition(validation.localizedDescription == "잘못된 좌표")
        func score(breakdown: [String: Double]? = nil, disqualified: Bool = false,
                   beatAI: Bool = false) -> ChallengeScore {
            ChallengeScore(attemptId: 1, totalScore: 50, maxScore: 100, disqualified: disqualified,
                           breakdown: breakdown, hints: ["침대 옆 공간이 0cm예요"], beatAI: beatAI,
                           aiScore: 80, rank: nil, totalRanked: 1, remainingAttempts: 1)
        }
        let excellent = score(breakdown: ["safety": 30, "principles": 30, "space": 40])
        precondition(excellent.strengths.count == 3 && excellent.improvements.isEmpty)
        let weak = score(breakdown: ["safety": 10, "door_clearance": 5, "furniture_use": 5,
                                     "principles": 10, "space": 20])
        precondition(weak.strengths.isEmpty && weak.improvements.count == 4)
        let boundary = score(breakdown: ["safety": 24, "principles": 24, "space": 32])
        precondition(boundary.strengths.count == 3 && boundary.improvements.count == 3)
        precondition(score().strengths.isEmpty && score().improvements.isEmpty, "no fabricated feedback without scores")
        let dq = score(breakdown: ["safety": 30], disqualified: true, beatAI: true)
        precondition(dq.strengths.count == 2 && dq.improvements.isEmpty, "legacy flag does not force disqualification UI")
        precondition(score(beatAI: true).strengths == ["사용 가능한 여유 공간이 AI 배치보다 넓어요."])
        let decoder = JSONDecoder()
        let eventJSON = #"{"event_id":7,"name":"test","is_active":true,"max_attempts":1,"max_score":100,"criteria":[],"disqualify_rules":[],"penalty_rules":["겹친 가구 한 쌍마다 -5점","방 밖으로 나간 가구 하나마다 -5점"]}"#
        let modernEvent = try decoder.decode(ChallengeEvent.self, from: Data(eventJSON.utf8))
        precondition(modernEvent.penaltyRules == ChallengePlacementHint.defaultPenaltyRules)
        let legacyEvent = try decoder.decode(ChallengeEvent.self, from: Data(#"{"event_id":7,"name":"test","is_active":true,"max_attempts":1,"max_score":100,"criteria":[],"disqualify_rules":[]}"#.utf8))
        precondition(legacyEvent.penaltyRules == nil, "older events still decode")
        let penalized = try decoder.decode(ChallengeScore.self, from: Data(#"{"attempt_id":8,"total_score":80,"max_score":100,"disqualified":false,"breakdown":{"safety":30,"door_clearance":15,"furniture_use":15,"principles":30,"space":40,"penalty":20},"hints":["가구 3쌍이 겹쳐 있어요 (-15점)","가구 1개가 방 밖으로 나가 있어요 (-5점)","침대 옆 공간이 0cm예요 (권장 65cm)"],"beat_ai":false,"ai_score":80,"rank":1,"total_ranked":1,"remaining_attempts":0}"#.utf8))
        precondition(penalized.placementPenalty == 20 && penalized.totalScore == 80)
        precondition(penalized.improvements == ["가구 3쌍이 겹쳐 15점 감점됐어요.", "가구 1개가 방 밖으로 나가 5점 감점됐어요."])
        precondition(!penalized.strengths.contains { $0.contains("추가 감점이 없어요") })
        precondition(score().placementPenalty == nil, "missing penalty is not interpreted as zero")
        let noPenalty = score(breakdown: ["penalty": 0])
        precondition(noPenalty.strengths == ["가구 겹침·방 밖 배치로 인한 추가 감점이 없어요."])
        let missingDetails = score(breakdown: ["penalty": 10])
        precondition(missingDetails.improvements == ["가구 겹침·방 밖 배치로 총 10점 추가 감점됐어요."])
        let guidance = ChallengePlacementHint.sections.flatMap(\.items)
        precondition(!guidance.contains { $0.contains("침대 머리") } && guidance.contains { $0.contains("문 앞") }
                     && guidance.contains { $0.contains("연결") } && !guidance.contains { $0.contains("cm") })
        print("PASS: server penalty rules decode; counted penalty feedback and legacy results; placement guide and grounded score review")
        print("PASS: event resolution, scene readiness, unchanged submission, durable retry, ranking navigation, reattempt, session/result recovery, participant reset, transform convention")
    }
}

private struct MissingCurrentEventAPI: ChallengeServing {
    func event() async throws -> ChallengeEvent { throw APIError(statusCode: 404, detail: "종료") }
    func register(name: String, phone: String) async throws -> ChallengeRegistration { fatalError() }
    func session(token: String) async throws -> ChallengeParticipantSession { fatalError() }
    func room(token: String) async throws -> ChallengeRoom { fatalError() }
    func myLayout(token: String) async throws -> ChallengeMyLayout { fatalError() }
    func leaveSession(token: String) async throws { fatalError() }
    func submit(token: String, elapsed: Int, objects: [ChallengeObjectEdit], key: UUID) async throws -> ChallengeScore { fatalError() }
    func leaderboard() async throws -> ChallengeLeaderboard { fatalError() }
}
