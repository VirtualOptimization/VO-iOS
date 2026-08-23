import Foundation
import RoomPlan

// MARK: - 방 스캔 업로드 + 최적화 요청 + 공간 목록

extension ScanViewModel {

    func saveAndUpload(room: CapturedRoom) {
        phase = .uploading(room)
        uploadError = nil
        Task {
            do {
                guard let accessToken = KeychainTokenStore.get(.accessToken) else {
                    print("❌ 업로드 실패: 로그인이 필요해요")
                    uploadError = "로그인이 필요해요"
                    phase = .result(room)
                    return
                }

                // 1. 로컬 저장
                print("📁 [1/4] 로컬 저장 시작")
                let (folderURL, usdzExists, emptyUsdzExists) = try saveRoomData(room: room)
                print("📁 [1/4] 로컬 저장 완료 – USDZ=\(usdzExists), Empty=\(emptyUsdzExists)")

                // 2. 업로드 세션 시작 (방을 현재 사용자와 연결)
                print("🌐 [2/4] 업로드 세션 시작 (includeRoomUsdz=\(usdzExists), includeEmpty=\(emptyUsdzExists))")
                let startResp = try await optimizer.startScanUpload(includeRoomUsdz: usdzExists,
                                                                      includeRoomEmptyUsdz: emptyUsdzExists,
                                                                      accessToken: accessToken)
                let roomId = startResp.roomId
                print("🌐 [2/4] 세션 시작 완료 – roomId=\(roomId), 슬롯 \(startResp.uploads.count)개")

                // 3. 각 슬롯 파일을 S3에 PUT (room_data_json, room_usdz 두 슬롯)
                for (i, slot) in startResp.uploads.enumerated() {
                    print("☁️ [3/4] S3 업로드 [\(i+1)/\(startResp.uploads.count)] \(slot.logicalName)")
                    let data = try readFileData(logicalName: slot.logicalName, folderURL: folderURL)
                    try await optimizer.uploadFileToS3(
                        presignedURL: slot.presignedURL,
                        data: data,
                        contentType: slot.contentType
                    )
                    print("☁️ [3/4] 업로드 완료 \(slot.logicalName) (\(data.count) bytes)")
                }

                pendingRoomId = roomId
                pendingUploadedKeys = startResp.uploads.map { $0.s3Key }

                let space = SavedSpace(roomId: roomId)
                savedSpaces.insert(space, at: 0)
                persistSpaces()

                print("🎉 [4/4] 업로드 완료 → UploadCompleteView")
                phase = .uploadComplete(room, roomId: roomId)

            } catch {
                print("❌ 업로드 실패 (\(type(of: error))): \(error)")
                uploadError = "저장에 실패했어요: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                phase = .result(room)
            }
        }
    }

    /// logical_name → 실제 파일 Data 매핑 (room_data_json, room_usdz 두 슬롯만)
    private func readFileData(logicalName: String, folderURL: URL) throws -> Data {
        let fileURL: URL
        switch logicalName {
        case "room_data_json":  fileURL = folderURL.appending(path: "room_data.json")
        case "room_usdz":       fileURL = folderURL.appending(path: "Room.usdz")
        case "room_empty_usdz": fileURL = folderURL.appending(path: "Room_empty.usdz")
        default:                throw OptimizerError.invalidResponse
        }
        return try Data(contentsOf: fileURL)
    }

    /// GET /rooms/{room_id}/optimized 폴링 → data_url(normalized.json) 나오면 바로 완료 (5초 간격, 최대 2시간)
    private func pollUntilComplete(roomId: Int, accessToken: String) async throws {
        let maxAttempts = 1440
        for attempt in 1...maxAttempts {
            try await Task.sleep(for: .seconds(5))
            do {
                let detail = try await optimizer.fetchVersionDetail(
                    roomId: roomId, versionType: "optimized", accessToken: accessToken)
                if detail.dataUrl != nil {
                    print("✅ 폴링 \(attempt)/\(maxAttempts) – normalized.json 확인됨, GLB 안 기다리고 진행")
                    return
                }
            } catch {
                // 아직 없음 – 계속 폴링
            }
            print("⏳ 폴링 \(attempt)/\(maxAttempts) – optimized 아직 없음")
        }
        throw OptimizerError.timeout
    }

    // MARK: 최적화 요청 (UploadCompleteView 버튼)

    /// /complete 호출 → 파이프라인 시작 → 폴링 → 최적화 JSON 파싱 → OptimizedResultView
    func requestOptimization(room: CapturedRoom, roomId: Int) {
        guard !isOptimizing else { return }
        isOptimizing = true
        optimizeError = nil
        // 즉시 로딩 화면으로 전환
        phase = .processing(room, roomId: roomId)
        Task {
            defer { isOptimizing = false }
            do {
                guard let accessToken = KeychainTokenStore.get(.accessToken) else {
                    optimizeError = "로그인이 필요해요"
                    phase = .uploadComplete(room, roomId: roomId)
                    return
                }

                // 1. POST /api/rooms/{room_id}/complete → 업로드 완료 확인 + 파이프라인 트리거
                print("최적화 요청 – roomId=\(roomId), uploadedKeys=\(pendingUploadedKeys)")
                let resp = try await optimizer.completeScanUpload(roomId: roomId, uploadedKeys: pendingUploadedKeys, accessToken: accessToken)
                print("pipelineStarted=\(resp.pipelineStarted)")

                // pipelineStarted=false → 파이프라인 미시작 (BE ARN 미설정 등)
                // 폴링해도 optimized가 /versions에 절대 안 뜨므로 즉시 복귀
                guard resp.pipelineStarted else {
                    print("pipelineStarted=false – BE의 Step Functions ARN 설정 필요")
                    optimizeError = "최적화 파이프라인이 서버에서 아직 시작되지 않았어요.\n(서버 설정 문제일 수 있어요 — 잠시 후 다시 시도해주세요)"
                    phase = .uploadComplete(room, roomId: roomId)
                    return
                }

                // 2. optimized가 /versions에 뜰 때까지 폴링 (5초 간격, 최대 5분)
                print("최적화 폴링 시작...")
                try await pollUntilComplete(roomId: roomId, accessToken: accessToken)
                print("최적화 완료")

                // 3. optimized 버전 상세 → OptimizedResultView (FurnitureRealityKitView가 직접 렌더링)
                let versionDetail = try await optimizer.fetchVersionDetail(
                    roomId: roomId, versionType: "optimized", accessToken: accessToken)
                print("최적화 버전 상세 취득 – OptimizedResultView로 이동")
                phase = .optimized(room, versionDetail)

            } catch {
                guard !Task.isCancelled else { return }   // 사용자가 취소한 경우 – 이미 이전 화면으로 이동했으므로 조용히 종료
                print("최적화 요청 실패: \(error)")
                // 에러 시 UploadCompleteView로 복귀
                optimizeError = "최적화 요청에 실패했어요: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                phase = .uploadComplete(room, roomId: roomId)
            }
        }
    }

    // MARK: 공간 목록 관리

    func updateSpaceName(_ name: String, id: UUID) {
        guard let idx = savedSpaces.firstIndex(where: { $0.id == id }) else { return }
        savedSpaces[idx].name = name
        persistSpaces()

        // 서버에도 반영 (다른 기기/재설치 후에도 이름 유지) – best-effort, 실패해도 로컬은 이미 저장됨
        let roomId = savedSpaces[idx].roomId
        guard let accessToken = KeychainTokenStore.get(.accessToken) else { return }
        Task {
            do {
                try await optimizer.updateRoomName(roomId: roomId, name: name, accessToken: accessToken)
            } catch {
                print("⚠️ 방 이름 서버 동기화 실패 (로컬은 유지됨): \(error)")
            }
        }
    }

    /// GET /api/rooms – 로그인 사용자의 공간 목록 + 버전 상태를 한 번에 동기화.
    /// 이름은 서버가 우선이고(다른 기기에서 바꿨을 수 있으므로), 서버에 없으면 로컬 값을 유지한다.
    func syncRoomsWithServer() {
        guard let accessToken = KeychainTokenStore.get(.accessToken) else { return }
        Task {
            guard let rooms = try? await optimizer.fetchMyRooms(accessToken: accessToken) else { return }

            let existingNames = Dictionary(uniqueKeysWithValues: savedSpaces.map { ($0.roomId, $0.name) })
            let df = ISO8601DateFormatter()
            df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let dfNoFraction = ISO8601DateFormatter()

            savedSpaces = rooms.map { room in
                let createdAt = room.createdAt.flatMap { df.date(from: $0) ?? dfNoFraction.date(from: $0) } ?? Date()
                return SavedSpace(
                    name: room.name ?? existingNames[room.roomId] ?? "내 공간",
                    roomId: room.roomId,
                    createdAt: createdAt
                )
            }
            roomStatus = Dictionary(uniqueKeysWithValues: rooms.map { ($0.roomId, $0) })
            persistSpaces()
        }
    }

    private func persistSpaces() {
        let snapshot = savedSpaces
        let url = spaceListURL()
        Task.detached {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url)
        }
    }

    private func spaceListURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("space_list.json")
    }

    func loadSpaceList() throws -> [SavedSpace] {
        let data = try Data(contentsOf: spaceListURL())
        return try JSONDecoder().decode([SavedSpace].self, from: data)
    }
}
