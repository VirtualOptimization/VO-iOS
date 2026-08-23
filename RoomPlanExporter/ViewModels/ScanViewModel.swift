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
    case processing(CapturedRoom, roomId: Int)                        // 최적화 파이프라인 폴링 중
    case optimized(CapturedRoom, RoomVersionDetail)                    // 최적화 완료 – 결과 비교
    case inquiryLoading(roomId: Int)                                  // 공간 조회 중
    case inquiryResult(ScanDetail)                                    // 조회 / 최적화 완료 결과
    case furnitureMethodPicker                                        // 가구 등록 방법 선택 (LiDAR 실측 / 사진 AI 생성)
    case furnitureGuide                                                // LiDAR 촬영 안내 (LiDAR 방법 선택시에만)
    case furnitureLidarCapture                                        // LiDAR 객체 캡처 (ObjectCaptureSession, 카메라 전용)
    case furnitureAIEntry(UIImage)                                     // 사진 확인 + AI 서비스 선택 + 실측 치수 입력
    case furnitureProcessing(UIImage)                                 // 3D 모델 생성 중 (공용 로딩 화면)
    case furnitureModelReady(URL, UIImage)                            // 3D 모델 준비 완료
    case furnitureList                                                // 저장된 가구 목록
    case furnitureAICompare                                           // Tripo3D vs Hyper3D 비교 테스트 (개발용)
}

extension ScanPhase: Equatable {
    static func == (lhs: ScanPhase, rhs: ScanPhase) -> Bool {
        switch (lhs, rhs) {
        case (.main, .main), (.guide, .guide), (.countdown, .countdown),
             (.scanning, .scanning): return true
        case (.result, .result), (.uploading, .uploading),
             (.uploadComplete, .uploadComplete), (.processing, .processing),
             (.optimized, .optimized), (.inquiryLoading, .inquiryLoading),
             (.inquiryResult, .inquiryResult): return true
        case (.furnitureMethodPicker, .furnitureMethodPicker), (.furnitureGuide, .furnitureGuide),
             (.furnitureLidarCapture, .furnitureLidarCapture), (.furnitureAIEntry, .furnitureAIEntry),
             (.furnitureProcessing, .furnitureProcessing), (.furnitureModelReady, .furnitureModelReady),
             (.furnitureList, .furnitureList), (.furnitureAICompare, .furnitureAICompare): return true
        default: return false
        }
    }
}


// MARK: - ScanViewModel
//
// 책임별로 여러 파일에 나눠서 구현되어 있습니다 (단일 클래스, extension으로 분리):
//   ScanViewModel.swift            — 상태 선언 + 네비게이션 (이 파일)
//   ScanViewModel+Furniture.swift  — 가구 캡처/저장/서버 동기화
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
    @Published var furnitureSyncError: String? = nil
    @Published var uploadError: String? = nil
    @Published var savedFurniture: [FurnitureItem] = []
    @Published var savedSpaces: [SavedSpace] = []
    @Published var roomStatus: [Int: MyRoomSummary] = [:]   // roomId -> 서버 버전 상태 (GET /api/rooms)
    @Published var furnitureProgressText: String = ""

    let optimizer = RoomOptimizerService()

    /// 가구 3D 생성(LiDAR 재구성/Meshy AI/Tripo3D) 취소용 핸들 — 화면 이탈 시 실제 작업도 중단시킴
    var furnitureGenerationTask: Task<Void, Never>? = nil

    /// 최적화 요청 시 필요한 room id (스캔 업로드 후 채워짐, 다른 extension 파일에서도 갱신됨)
    var pendingRoomId: Int? = nil
    /// 최적화 완료 요청(complete) 시 서버에 함께 보내야 하는 실제 업로드된 S3 키 목록
    var pendingUploadedKeys: [String] = []

    init() {
        savedFurniture = (try? loadFurnitureList()) ?? []
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
    func retake() {
        pendingRoomId = nil
        phase = .main
    }

    // MARK: Furniture Navigation

    /// 가구 등록 진입점 — 방법 선택 화면부터 시작 (MainView "+ 가구 등록", FurnitureListView "+")
    func showFurnitureAddMethodPicker() { phase = .furnitureMethodPicker }

    /// "LiDAR로 실측 스캔" 선택 → 촬영 안내 화면
    func chooseLidarMethod() { phase = .furnitureGuide }

    /// 안내 화면에서 "촬영 시작" → LiDAR 캡처 화면 (지원 기기 확인은 호출하는 쪽에서)
    func startLidarCapture() { phase = .furnitureLidarCapture }

    /// "사진으로 AI 3D 생성" 선택 후 카메라/보관함/탐색으로 고른 사진으로 확인 화면 진입
    func chooseAIMethod(with image: UIImage) {
        phase = .furnitureAIEntry(image)
    }

    /// 등록 취소/실패 후 방법 선택 화면으로 복귀
    func retakeFurniture() {
        phase = .furnitureMethodPicker
    }

    func showFurnitureList() {
        phase = .furnitureList
        syncFurnitureWithServer()
    }

    /// 개발용 — Tripo3D vs Hyper3D 비교 테스트 화면
    func showFurnitureAICompare() { phase = .furnitureAICompare }
}
