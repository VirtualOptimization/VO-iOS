import Foundation

// MARK: - room_id로 공간 조회 / 버전 삭제

extension ScanViewModel {

    func fetchRoom(roomId: Int) {
        inquiryError = nil
        phase = .inquiryLoading(roomId: roomId)
        Task {
            guard let accessToken = KeychainTokenStore.get(.accessToken) else {
                inquiryError = "로그인이 필요해요"
                phase = .main
                return
            }
            do {
                let detail = try await optimizer.fetchRoomVersions(roomId: roomId, accessToken: accessToken)
                inquiryError = nil
                // 앱을 나갔다 들어온 사이에도 서버에서 최적화가 돌고 있을 수 있다 — 그럼 결과를 이어서 기다린다.
                let hasOptimized = detail.versions.contains { $0.versionType.uppercased() == "OPTIMIZED" }
                let status = try? await optimizer.fetchRoomStatus(roomId: roomId, accessToken: accessToken)
                if !hasOptimized, status?.optimizationStatus.uppercased() == "PROCESSING" {
                    waitForRunningOptimization(detail: detail)
                } else {
                    phase = .inquiryResult(detail)
                }
            } catch {
                print("❌ 조회 실패: \(error)")
                inquiryError = "공간 정보를 불러오지 못했어요. 잠시 후 다시 시도해주세요"
                phase = .main
            }
        }
    }

    /// 저장 직후 "내 방 보러가기" — 저장 확정(complete)이 원본 버전을 만들기 전에 누를 수 있으니
    /// 원본 버전이 보일 때까지 잠깐 기다렸다가 내 방 조회 화면으로 간다.
    func openSavedRoom(roomId: Int) {
        inquiryError = nil
        phase = .inquiryLoading(roomId: roomId)
        Task {
            guard let accessToken = KeychainTokenStore.get(.accessToken) else {
                inquiryError = "로그인이 필요해요"
                phase = .main
                return
            }
            for _ in 1...30 {
                if let detail = try? await optimizer.fetchRoomVersions(roomId: roomId, accessToken: accessToken),
                   detail.versions.contains(where: { ["ORIGINAL", "ORIGIN"].contains($0.versionType.uppercased()) }) {
                    phase = .inquiryResult(detail)
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
            inquiryError = "방을 아직 불러오지 못했어요. 잠시 후 내 공간에서 다시 열어주세요"
            phase = .main
        }
    }

    /// 편집 모드에서 옮긴 가구를 새 "사용자 편집" 버전으로 저장하고, 저장된 버전을 보여준다.
    func saveEditedVersion(roomId: Int, parentVersionId: Int, edits: [FurniturePoseEdit], from detail: ScanDetail) {
        guard !edits.isEmpty else {
            editError = "옮긴 가구가 없어요. 가구를 옮긴 뒤 저장해주세요."
            return
        }
        guard let accessToken = KeychainTokenStore.get(.accessToken) else {
            editError = "로그인이 필요해요"
            return
        }
        phase = .inquiryLoading(roomId: roomId)
        Task {
            do {
                try await optimizer.createUserEditedVersion(
                    roomId: roomId, parentVersionId: parentVersionId, edits: edits, accessToken: accessToken)
                let updated = try await optimizer.fetchRoomVersions(roomId: roomId, accessToken: accessToken)
                phase = .inquiryResult(updated)   // 가장 최근 편집본이 자동으로 선택된다
                syncRoomsWithServer()
            } catch {
                print("❌ 편집본 저장 실패: \(error)")
                editError = (error as? LocalizedError)?.errorDescription ?? "편집한 배치를 저장하지 못했어요."
                phase = .inquiryResult(detail)
            }
        }
    }

    func deleteVersion(roomId: Int, versionId: Int, from detail: ScanDetail) {
        Task {
            guard let accessToken = KeychainTokenStore.get(.accessToken) else {
                inquiryError = "로그인이 필요해요"
                return
            }
            do {
                try await optimizer.deleteVersion(roomId: roomId, versionId: versionId, accessToken: accessToken)
                var updated = detail
                updated.versions = detail.versions.filter { $0.versionId != versionId }
                phase = .inquiryResult(updated)
            } catch {
                print("❌ 삭제 실패: \(error)")
                inquiryError = "삭제에 실패했어요: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
        }
    }
}
