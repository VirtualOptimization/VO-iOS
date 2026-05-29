import SwiftUI
import RoomPlan

struct ScanningView: View {
    @ObservedObject var vm: ScanViewModel

    var body: some View {
        ZStack(alignment: .top) {
            RoomCaptureViewControllerRepresentable(
                onFinish: { vm.scanCompleted($0) },
                onCancel:  { vm.retake() }
            )
            .ignoresSafeArea()

            Text("당신의 공간을 디지털 트윈으로 복제 중입니다")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.voBlue)
        }
    }
}
