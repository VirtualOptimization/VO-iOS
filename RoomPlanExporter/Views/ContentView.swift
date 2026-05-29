import SwiftUI
import RoomPlan

struct ContentView: View {
    @StateObject private var vm = ScanViewModel()

    var body: some View {
        switch vm.phase {
        case .main:
            MainView(vm: vm)

        case .guide:
            ScanGuideView(vm: vm)

        case .countdown:
            CountdownView(vm: vm)

        case .scanning:
            ScanningView(vm: vm)

        case .result(let room):
            RoomResultView(room: room, vm: vm)

        case .uploading:
            LoadingView(
                statusText: "내 방 저장 중..",
                tips: [
                    "잠시만 기다려주세요",
                    "공간 데이터를 서버에 전송하고 있어요",
                    "저장 중입니다, 화면을 끄지 마세요",
                    "저장이 끝나면 확인 코드를 확인해보세요"
                ]
            )

        case .uploadComplete(let room, let confirmCode):
            UploadCompleteView(room: room, confirmCode: confirmCode, vm: vm)

        case .processing:
            LoadingView(
                statusText: "최적화 중..",
                tips: [
                    "최적화 진행 중입니다\n화면을 끄지 마세요",
                    "가구 배치를 분석하고 있어요",
                    "원본과 최적화 결과를\n비교해볼 수 있어요",
                    "잠시 후 최적화 결과가 나와요"
                ]
            )

        case .optimized(let room, let objects):
            OptimizedResultView(room: room, objects: objects, vm: vm)

        case .inquiry:
            InquiryView(vm: vm)

        case .inquiryLoading:
            LoadingView(
                statusText: "공간 정보 조회 중..",
                tips: [
                    "잠시만 기다려주세요",
                    "저장된 공간 데이터를 불러오고 있어요",
                    "원본과 최적화 결과를 모두 확인할 수 있어요",
                    "잠시 후 결과가 나와요"
                ]
            )

        case .inquiryResult(let detail):
            InquiryResultView(detail: detail, vm: vm)
        }
    }
}

#Preview { ContentView() }
