import SwiftUI
import RoomPlan

struct RoomResultView: View {
    let room: CapturedRoom
    @ObservedObject var vm: ScanViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Banner
            Text("내 방이 잘 스캔되었는지 확인해보세요")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.voBlue)

            // 3D Viewer
            RoomViewerView(capturedRoom: room)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Bottom controls
            VStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                    Text("스캔 결과를 저장하면 최적화 여부를 결정할 수 있어요")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)

                Button("저장하기") { vm.saveAndUpload(room: room) }
                    .buttonStyle(VOFilledButtonStyle())

                Button("다시 찍기") { vm.retake() }
                    .buttonStyle(VOOutlineButtonStyle())
            }
            .padding(.horizontal, 50)
            .padding(.vertical, 20)
        }
    }
}
