import Foundation
import RoomPlan
import UIKit

// MARK: - ScanPhase

enum ScanPhase {
    case main
    case guide
    case countdown
    case scanning
    case result(CapturedRoom)                                         // 스캔 완료 – 저장 전
    case uploading(CapturedRoom)                                      // S3 파일 업로드 중
    case uploadComplete(CapturedRoom, roomId: Int)                    // 업로드 완료 – 방 이름 입력
    case processing(roomId: Int)                                      // 내 방 조회에서 최적화 요청 후 폴링 중
    case inquiryLoading(roomId: Int)                                  // 공간 조회 중
    case inquiryResult(ScanDetail, focusVersionType: String? = nil)   // 내 방 조회 (최적화·편집·AI 상담)
}

extension ScanPhase: Equatable {
    static func == (lhs: ScanPhase, rhs: ScanPhase) -> Bool {
        switch (lhs, rhs) {
        case (.main, .main), (.guide, .guide), (.countdown, .countdown),
             (.scanning, .scanning): return true
        case (.result, .result), (.uploading, .uploading),
             (.uploadComplete, .uploadComplete), (.processing, .processing),
             (.inquiryLoading, .inquiryLoading),
             (.inquiryResult, .inquiryResult): return true
        default: return false
        }
    }
}


// MARK: - ScanViewModel
//
// 책임별로 여러 파일에 나눠서 구현되어 있습니다 (단일 클래스, extension으로 분리):
//   ScanViewModel.swift            — 상태 선언 + 네비게이션 (이 파일)
//   ScanViewModel+RoomScan.swift   — 방 스캔 업로드 + 최적화 요청 + 공간 목록
//   ScanViewModel+Inquiry.swift    — 확인 코드로 공간 조회/버전 삭제
//   ScanViewModel+RoomExport.swift — RoomPlan 캡처 데이터 → 로컬 JSON/USDZ 익스포트

@MainActor
final class ScanViewModel: ObservableObject {
    @Published var phase: ScanPhase = .main
    @Published var countdownValue: Int = 3
    @Published var isOptimizing: Bool = false   // 최적화 진행 중 여부
    @Published var inquiryError: String? = nil
    @Published var optimizeError: String? = nil
    @Published var editError: String? = nil
    @Published var uploadError: String? = nil
    @Published var savedSpaces: [SavedSpace] = []
    @Published var roomStatus: [Int: MyRoomSummary] = [:]   // roomId -> 서버 버전 상태 (GET /api/rooms)
    /// 서버에서 최적화가 돌고 있는 방 — 앱을 나갔다 들어와도 진행 중임을 보여주기 위해 목록 동기화 때 확인한다.
    @Published var optimizingRoomIds: Set<Int> = []
    /// 최적화 없이 "저장하기"만 눌렀을 때 서버에 확정된 원본 버전 — 채워지면 UploadCompleteView가
    /// 로컬 렌더러 대신 이걸로 서버 색상이 반영된 가구를 보여준다.
    @Published var savedOriginalDetail: RoomVersionDetail? = nil

    let optimizer = RoomOptimizerService()

    /// 저장 확정(complete) 요청 시 서버에 함께 보내야 하는 실제 업로드된 S3 키 목록
    var pendingUploadedKeys: [String] = []

    init() {
        savedSpaces = (try? loadSpaceList()) ?? []
    }

    // MARK: Navigation

    func showGuide() { phase = .guide }

    func startCountdown() {
        countdownValue = 3
        phase = .countdown
        Task {
            for i in stride(from: 3, through: 1, by: -1) {
                countdownValue = i
                try? await Task.sleep(for: .seconds(1))
            }
            phase = .scanning
        }
    }

    func scanCompleted(_ room: CapturedRoom) { phase = .result(room) }
    func retake() { phase = .main }
}
