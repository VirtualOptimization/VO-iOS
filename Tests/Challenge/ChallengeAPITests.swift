import Foundation

private final class ChallengeURLProtocol: URLProtocol {
    static var response: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.response(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

enum ChallengeAPITests {
    static func run() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChallengeURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let api = ChallengeService(eventId: 7, urlSession: session)
        let registration = Data(#"{"participant_id":12,"participant_token":"rotated","remaining_attempts":0,"is_returning":true}"#.utf8)
        for status in [200, 201] {
            ChallengeURLProtocol.response = { request in
                precondition(request.httpMethod == "POST" && request.url!.path == "/api/events/7/participants")
                precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
                return (status, registration)
            }
            let value = try await api.register(name: "visitor", phone: "010-1234-5678")
            precondition(value.isReturning == true && value.remainingAttempts == 0 && value.participantToken == "rotated")
        }
        let matrix: [[Float]] = [[1,0,0,0], [0,1,0,0], [0,0,1,0], [2,0.4,1,1]]
        let object: [String: Any] = ["identifier": "desk", "category": "table", "dimensions": [1,0.8,0.6], "transform": matrix]
        let score: [String: Any] = ["attempt_id": 12, "total_score": 72.5, "max_score": 100,
            "disqualified": false, "breakdown": ["safety": 25], "hints": [], "beat_ai": false,
            "rank": 3, "total_ranked": 40, "remaining_attempts": 0]
        let detail: [String: Any] = ["ios_objects": [object], "room_shell_url": "https://example.com/shell.usdc",
            "model_urls": ["table": "https://example.com/table.usdc"],
            "json_data": ["objects": [object], "walls": [], "floors": [], "doors": [], "windows": []]]
        let layout = try JSONSerialization.data(withJSONObject: ["result": score, "submitted": detail, "start": detail])
        ChallengeURLProtocol.response = { request in
            precondition(request.httpMethod == "GET" && request.url!.path == "/api/events/7/my-layout")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer rotated")
            precondition(request.cachePolicy == .reloadIgnoringLocalCacheData)
            return (200, layout)
        }
        let value = try await api.myLayout(token: "rotated")
        precondition(value.result.totalScore == 72.5 && value.submitted.roomShellUrl?.hasSuffix("shell.usdc") == true)
        let legacy = try JSONDecoder().decode(RoomVersionDetail.self,
            from: Data(#"{"layout_json_url":"https://example.com/room.json","json_data":{"legacy":true}}"#.utf8))
        precondition(legacy.effectiveDataUrl != nil && legacy.jsonData == nil, "Legacy JSON must not break room detail decoding")
        // The URL may still refer to the starting layout. Inline submitted positions must win.
        let startingObject = try JSONDecoder().decode(RoomDataPayload.RoomObject.self,
            from: JSONSerialization.data(withJSONObject: object.merging(["transform": [[1,0,0,0],[0,1,0,0],[0,0,1,0],[0,0.4,0,1]]]) { _, new in new }))
        let base = RoomDataPayload(objects: [startingObject], walls: [], floors: [], doors: [], windows: [])
        let submitted = value.submitted.displayPayload(base: base, preferInlineObjects: true)!
        precondition(submitted.objects[0].transform[3][0] == 2 && base.objects[0].transform[3][0] == 0)
        precondition(value.submitted.displayPayload(base: nil, preferInlineObjects: true)?.objects.count == 1)

        ChallengeURLProtocol.response = { request in
            precondition(request.httpMethod == "DELETE" && request.url!.path == "/api/events/7/session")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer rotated")
            precondition(request.cachePolicy == .reloadIgnoringLocalCacheData)
            return (204, Data())
        }
        try await api.leaveSession(token: "rotated")
        for status in [401, 404] {
            ChallengeURLProtocol.response = { _ in (status, Data(#"{"detail":"테스트 안내"}"#.utf8)) }
            do {
                _ = try await api.myLayout(token: "rotated")
                preconditionFailure("HTTP errors must not decode into a successful record")
            } catch let error as APIError { precondition(error.statusCode == status && error.detail == "테스트 안내") }
        }
        ChallengeURLProtocol.response = { _ in (409, Data(#"{"detail":"다른 닉네임으로 참여한 번호예요."}"#.utf8)) }
        do {
            _ = try await api.register(name: "other", phone: "01012345678")
            preconditionFailure("A nickname conflict must not create a session")
        } catch let error as APIError { precondition(error.statusCode == 409) }
        print("PASS: registration 200/201, Bearer my-layout, inline submitted positions, room shell, DELETE 204, HTTP errors")
    }
}
