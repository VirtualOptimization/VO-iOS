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
                phase = .inquiryResult(detail)
            } catch {
                print("❌ 조회 실패: \(error)")
                inquiryError = "공간 정보를 불러오지 못했어요. 잠시 후 다시 시도해주세요"
                phase = .main
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
