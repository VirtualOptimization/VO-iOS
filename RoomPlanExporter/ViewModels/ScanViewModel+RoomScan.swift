import Foundation
import RoomPlan

// MARK: - 방 스캔 업로드 + 최적화 요청 + 공간 목록

extension ScanViewModel {

    func saveAndUpload(room: CapturedRoom) {
        phase = .uploading(room)
        uploadError = nil
        savedOriginalDetail = nil
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

    /// GET /rooms/{room_id}/optimized 폴링 → data_url(normalized.json) 나오면 바로 완료 (5초 간격, 최대 2시간).
    /// 서버가 실패로 표시하면 2시간을 기다리지 않고 바로 실패 처리한다.
    private func pollUntilComplete(roomId: Int, accessToken: String) async throws {
        let maxAttempts = 1440
        for attempt in 1...maxAttempts {
            try await Task.sleep(for: .seconds(5))
            if let detail = try? await optimizer.fetchVersionDetail(
                roomId: roomId, versionType: "optimized", accessToken: accessToken),
               detail.dataUrl != nil {
                print("✅ 폴링 \(attempt)/\(maxAttempts) – normalized.json 확인됨, GLB 안 기다리고 진행")
                return
            }
            if let status = try? await optimizer.fetchRoomStatus(roomId: roomId, accessToken: accessToken),
               status.optimizationStatus.uppercased() == "FAILED" {
                throw OptimizerError.optimizationFailed
            }
            print("⏳ 폴링 \(attempt)/\(maxAttempts) – optimized 아직 없음")
        }
        throw OptimizerError.timeout
    }

    // MARK: 최적화 요청 (내 방 조회의 "최적화하기" 버튼)

    /// 최적화 시작 → 완료까지 폴링 → 최적화 버전을 선택한 상태로 내 방 조회 화면 복귀
    func optimizeRoom(from detail: ScanDetail) {
        runOptimization(detail: detail) { roomId, accessToken in
            try await self.optimizer.startOptimization(roomId: roomId, accessToken: accessToken)
        }
    }

    /// 서버에서 이미 돌고 있는 최적화를 이어서 기다린다 (앱을 나갔다 들어온 경우)
    func waitForRunningOptimization(detail: ScanDetail) {
        runOptimization(detail: detail) { _, _ in "PROCESSING" }
    }

    private func runOptimization(detail: ScanDetail,
                                 start: @escaping (Int, String) async throws -> String) {
        guard !isOptimizing else { return }
        isOptimizing = true
        optimizeError = nil
        let roomId = detail.roomId
        optimizingRoomIds.insert(roomId)
        phase = .processing(roomId: roomId)
        Task {
            defer {
                isOptimizing = false
                optimizingRoomIds.remove(roomId)
            }
            do {
                guard let accessToken = KeychainTokenStore.get(.accessToken) else {
                    optimizeError = "로그인이 필요해요"
                    phase = .inquiryResult(detail)
                    return
                }
                let status = try await start(roomId, accessToken)
                if status.uppercased() != "COMPLETED" {
                    try await pollUntilComplete(roomId: roomId, accessToken: accessToken)
                }
                let updated = try await optimizer.fetchRoomVersions(roomId: roomId, accessToken: accessToken)
                phase = .inquiryResult(updated, focusVersionType: "OPTIMIZED")
                syncRoomsWithServer()
            } catch {
                print("❌ 최적화 실패: \(error)")
                optimizeError = "최적화에 실패했어요: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                phase = .inquiryResult(detail)
            }
        }
    }

    /// 원본 버전만 서버에 확정하고(최적화는 내 방 조회에서 따로 요청) 색상이 반영된 서버 카탈로그로
    /// 조회할 수 있도록 방금 확정된 원본 버전 상세를 받아온다.
    func finalizeSave(roomId: Int) {
        guard let accessToken = KeychainTokenStore.get(.accessToken) else { return }
        Task {
            do {
                _ = try await optimizer.completeScanUpload(
                    roomId: roomId, uploadedKeys: pendingUploadedKeys, accessToken: accessToken)
                let detail = try await optimizer.fetchVersionDetail(roomId: roomId, versionType: "origin", accessToken: accessToken)
                savedOriginalDetail = detail
            } catch {
                guard !Task.isCancelled else { return }
                print("⚠️ 저장 확정 실패 (색상 반영된 뷰어로 전환 못함): \(error)")
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

            // 최적화 결과가 아직 없는 방만 상태를 확인해서, 서버에서 돌고 있는 중이면 목록에 표시한다.
            let pending = rooms.filter { !$0.hasOptimized }.map(\.roomId)
            guard !pending.isEmpty else {
                optimizingRoomIds = []
                return
            }
            let running = await withTaskGroup(of: Int?.self) { group -> Set<Int> in
                for roomId in pending {
                    group.addTask { [optimizer] in
                        let status = try? await optimizer.fetchRoomStatus(roomId: roomId, accessToken: accessToken)
                        return status?.optimizationStatus.uppercased() == "PROCESSING" ? roomId : nil
                    }
                }
                var ids: Set<Int> = []
                for await roomId in group { if let roomId { ids.insert(roomId) } }
                return ids
            }
            optimizingRoomIds = running
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
