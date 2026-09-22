import SwiftUI
import RoomPlan

struct ScanningView: View {
    @ObservedObject var vm: ScanViewModel

    var body: some View {
        ZStack(alignment: .top) {
            RoomCaptureViewControllerRepresentable(
                onFinish: { vm.scanCompleted($0) },
                onCancel: { vm.retake() },
                onFail: { _ in vm.retake() }
            )
            .ignoresSafeArea()

            ZStack {
                Text("당신의 공간을 디지털 트윈으로 복제 중입니다")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                HStack {
                    Image("logo_white")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 42)
                    Spacer()
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 20)
            .voGlassBanner()
        }
    }
}
