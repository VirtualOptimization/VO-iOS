import SwiftUI
import RoomPlan

struct ContentView: View {
    @StateObject private var authVM = AuthViewModel()
    @StateObject private var vm = ScanViewModel()

    var body: some View {
        if authVM.isLoggedIn {
            ScanFlowView(vm: vm, authVM: authVM)
        } else {
            AuthFlowView(authVM: authVM)
        }
    }
}

// MARK: - Auth Flow

private enum AuthScreen { case splash, login, signUp }

private struct AuthFlowView: View {
    @ObservedObject var authVM: AuthViewModel
    @State private var screen: AuthScreen = .splash

    var body: some View {
        Group {
            switch screen {
            case .splash:
                SplashView(
                    onLogin: { screen = .login },
                    onSignUp: { screen = .signUp }
                )
            case .login:
                LoginView(
                    authVM: authVM,
                    onSignUp: { authVM.loginError = nil; screen = .signUp }
                )
            case .signUp:
                SignUpView(
                    authVM: authVM,
                    onBack: { authVM.loginError = nil; screen = .login }
                )
            }
        }
        .animation(.easeInOut(duration: 0.25), value: screen)
    }
}

// MARK: - Scan Flow (로그인 후)

private struct ScanFlowView: View {
    @ObservedObject var vm: ScanViewModel
    @ObservedObject var authVM: AuthViewModel

    var body: some View {
        ZStack {
            switch vm.phase {
            case .main:
                MainView(vm: vm, authVM: authVM)
                    .transition(.opacity)

            case .guide:
                ScanGuideView(vm: vm)
                    .transition(.opacity)

            case .countdown:
                CountdownView(vm: vm)
                    .transition(.opacity)

            case .scanning:
                ScanningView(vm: vm)
                    .transition(.opacity)

            case .result(let room):
                RoomResultView(room: room, vm: vm)
                    .transition(.opacity)

            case .uploading:
                LoadingView(
                    statusText: "내 방 저장 중..",
                    tips: [
                        "데이터를 안전하게\n서버로 보내고 있어요",
                        "공간 데이터를 서버에 전송하고 있어요",
                        "저장 중입니다, 화면을 끄지 마세요",
                        "저장이 끝나면 방 이름을 지어줄 수 있어요"
                    ]
                )
                .transition(.opacity)

            case .uploadComplete(let room, let roomId):
                UploadCompleteView(room: room, roomId: roomId, vm: vm)
                    .transition(.opacity)

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
                .transition(.opacity)

            case .optimized(let room, let versionDetail):
                OptimizedResultView(room: room, versionDetail: versionDetail, vm: vm)
                    .transition(.opacity)

            case .inquiryLoading:
                InquiryLoadingView(tips: [
                    "저장된 데이터를 찾아\n불러오고 있어요",
                    "저장된 공간 데이터를 불러오고 있어요",
                    "원본과 최적화 결과를\n모두 확인할 수 있어요",
                    "잠시 후 결과가 나와요"
                ])
                .transition(.opacity)

            case .inquiryResult(let detail):
                InquiryResultView(detail: detail, vm: vm)
                    .transition(.opacity)

            case .furnitureMethodPicker:
                FurnitureMethodPickerView(vm: vm)
                    .transition(.opacity)

            case .furnitureGuide:
                FurnitureCaptureGuideView(vm: vm)
                    .transition(.opacity)

            case .furnitureLidarCapture:
                FurnitureLidarCaptureView(vm: vm)
                    .transition(.opacity)

            case .furnitureAIEntry(let image):
                FurnitureAIEntryView(image: image, vm: vm)
                    .transition(.opacity)

            case .furnitureProcessing(let thumbnail):
                FurnitureProcessingView(thumbnail: thumbnail, vm: vm)
                    .transition(.opacity)

            case .furnitureModelReady(let modelURL, let thumbnail):
                FurnitureModelResultView(vm: vm, modelURL: modelURL, thumbnail: thumbnail)
                    .transition(.opacity)

            case .furnitureList:
                FurnitureListView(vm: vm)
                    .transition(.opacity)

            case .furnitureAICompare:
                FurnitureAICompareView(vm: vm)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: vm.phase)
    }
}

#Preview { ContentView() }
