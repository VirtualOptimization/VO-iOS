import SwiftUI
import RoomPlan

struct UploadCompleteView: View {
    let room: CapturedRoom
    let confirmCode: String
    @ObservedObject var vm: ScanViewModel

    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            // 배너
            HStack(spacing: 10) {
                Image("logo_white")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 20)
                Text("내 방 저장 및 확인 코드 생성 완료 !")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 20)
            .background(Color.voBlue)

            // 확인 코드
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Text(confirmCode)
                        .font(.title2.bold())
                        .tracking(4)

                    Button {
                        UIPasteboard.general.string = confirmCode
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            copied = false
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .foregroundStyle(copied ? .green : .secondary)
                            .animation(.easeInOut(duration: 0.2), value: copied)
                    }
                }

                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                    Text("확인 코드를 복사해두면 다음에도 조회 및 최적화가 가능해요")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 24)

            Divider()

            // 3D 뷰어
            RoomViewerView(capturedRoom: room)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 하단 버튼
            VStack(spacing: 10) {
                Button("최적화 요청") {
                    vm.requestOptimization(room: room, confirmCode: confirmCode)
                }
                .buttonStyle(VOFilledButtonStyle())
                .padding(.horizontal, 40)

                Button("메인으로") { vm.retake() }
                    .buttonStyle(VOOutlineButtonStyle())
                    .padding(.horizontal, 40)
            }
            .padding(.vertical, 20)
        }
    }
}
