import Foundation

final class MockChallengeAPI: ChallengeServing {
    var eventValue = ChallengeEvent(eventId: 7, name: "전시 챌린지", isActive: true, maxAttempts: 2,
                                    maxScore: 100, criteria: [], disqualifyRules: [])
    var status = ChallengeParticipantSession(remainingAttempts: 2, latestResult: nil, elapsedSeconds: nil)
    var failNextSubmission = true
    var submitted: [(UUID, Int, [ChallengeObjectEdit])] = []
    var roomCalls = 0
    func event() async throws -> ChallengeEvent { eventValue }
    func register(name: String, phone: String) async throws -> ChallengeRegistration {
        ChallengeRegistration(participantToken: "test-token", remainingAttempts: 2)
    }
    func session(token: String) async throws -> ChallengeParticipantSession { status }
    func room(token: String) async throws -> ChallengeRoom {
        roomCalls += 1
        return ChallengeRoom(detail: RoomVersionDetail(dataUrl: "https://test/layout"), remainingAttempts: 2)
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
                               loadSaved: { saved }, saveSaved: { saved = $0 }, clearSaved: { saved = nil })
        }
        let vm = makeVM()
        await vm.loadEvent()
        precondition(resolvedIDs.first == 0 && vm.eventId == 7, "current event resolution")
        await vm.start(name: "visitor", phone: "01012345678")
        precondition(saved?.eventId == 7 && vm.hasSession && vm.remainingAttempts == 2)
        await vm.loadRoom()
        await vm.submit(edits: [])
        precondition(api.submitted.isEmpty, "submission blocked before scene readiness")
        vm.sceneLoaded()
        await vm.submit(edits: [])
        precondition(vm.hasPendingSubmission && saved?.pending != nil, "failed request is persisted")
        let savedPending = saved!
        let key = savedPending.pending!.key
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
        resultRestore.forgetParticipant()
        precondition(saved == nil && !resultRestore.hasSession && resultRestore.screen == .welcome)

        // The submitted matrix keeps RoomPlan's column-vector convention.
        let object = ChallengeObjectEdit(pose: FurniturePoseEdit(identifier:"bed",center:[1,2,3],rotation:[0,.pi/2,0]))
        precondition(abs(object.transform[0][2] - 1) < 0.0001 && object.transform[3] == [1,2,3,1])
        let validation = APIError.from(statusCode: 422, data: Data(#"{"detail":[{"msg":"Value error, 잘못된 좌표"}]}"#.utf8))
        precondition(validation.localizedDescription == "잘못된 좌표")
        let measurement = "침대 옆 공간이 0cm예요 (권장 65cm)"
        let advice = "침대 머리를 벽에 붙여보세요"
        let actionWithMeasurement = "침대 옆 공간이 0cm예요. 침대를 옮겨 통로를 확보해주세요"
        func score(hints: [String], disqualified: Bool = false) -> ChallengeScore {
            ChallengeScore(attemptId: 1, totalScore: 50, maxScore: 100, disqualified: disqualified,
                           breakdown: nil, hints: hints, beatAI: false, aiScore: 80, rank: nil,
                           totalRanked: 1, remainingAttempts: 1)
        }
        precondition(score(hints: [measurement, "책상 앞 공간이 20cm예요 (권장 60cm)", advice,
                                   actionWithMeasurement]).displayHints == [advice, actionWithMeasurement])
        precondition(score(hints: ["침대 옆 공간이 0cm 에요"]).displayHints.isEmpty)
        precondition(score(hints: [measurement], disqualified: true).displayHints == [measurement])
        precondition(score(hints: []).displayHints.isEmpty)
        print("PASS: actionable hints and disqualification reasons preserved; measurement-only hints hidden")
        print("PASS: event resolution, scene readiness, unchanged submission, durable retry, ranking navigation, reattempt, session/result recovery, participant reset, transform convention")
    }
}
