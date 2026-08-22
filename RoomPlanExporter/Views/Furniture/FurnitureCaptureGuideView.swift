import SwiftUI
import RealityKit

// MARK: - LiDAR 실측 스캔 안내
//
// "가구 등록 방법 선택" 화면에서 LiDAR 방법을 골랐을 때만 보여주는 안내.
// 이 방법은 라이브 카메라로 가구 주위를 도는 캡처만 가능 — 사진 선택 옵션이 없다.

struct FurnitureCaptureGuideView: View {
    @ObservedObject var vm: ScanViewModel

    @State private var showLidarUnsupportedAlert = false

    private let tips: [(String, String)] = [
        ("가구를 밝은 곳에 두기",
         "가구 주변 조명을 켜주세요.\n어두우면 인식과 촬영 품질이 떨어질 수 있어요."),
        ("가구 주위에 여유 공간 확보",
         "가구를 한 바퀴 돌 수 있는 공간에 놓아주세요.\n주위를 돌면서 여러 각도를 촬영하게 됩니다."),
        ("천천히 한 바퀴 돌며 촬영",
         "화면 안내에 따라 가구 주위를 천천히 돌아주세요.\nLiDAR가 깊이를 함께 측정해서 실제 크기 그대로 3D 모델을 만들어요."),
        ("바닥면도 담고 싶다면",
         "화면에 뒤집기 안내가 뜨면 가구를 뒤집어\n이어서 촬영할 수 있어요.")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                vm.retakeFurniture()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.semiBold20)
                    .foregroundStyle(Color.voBlue)
                    .padding(.horizontal, 30)
                    .padding(.top, 20)
                    .padding(.bottom, 40)
            }

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("LiDAR 실측 스캔 안내")
                            .font(.title2.bold())
                        Text("가구를 스캔해서 실제 크기 그대로 등록해요!")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 40)
                    .padding(.bottom, 45)

                    VStack(spacing: 0) {
                        ForEach(Array(tips.enumerated()), id: \.offset) { i, tip in
                            FurnitureTipRow(number: i + 1, title: tip.0, detail: tip.1,
                                           showConnector: i < tips.count - 1)
                        }
                    }
                    .padding(.horizontal, 40)
                }
                .padding(.bottom, 16)
            }

            Button("촬영 시작") { startCapture() }
                .buttonStyle(VOFilledButtonStyle())
                .padding(.horizontal, 40)
                .padding(.top, 12)
                .padding(.bottom, 48)
        }
        .alert("이 기기에서는 사용할 수 없어요", isPresented: $showLidarUnsupportedAlert) {
            Button("확인") {}
        } message: {
            Text("LiDAR 실측 스캔에는 LiDAR 스캐너가 필요해요. iPhone/iPad Pro 계열 기기에서 이용해주세요.")
        }
    }

    private func startCapture() {
        guard ObjectCaptureSession.isSupported else {
            showLidarUnsupportedAlert = true
            return
        }
        vm.startLidarCapture()
    }
}

private struct FurnitureTipRow: View {
    let number: Int
    let title: String
    let detail: String
    let showConnector: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(spacing: 0) {
                Circle()
                    .fill(Color.voBlue)
                    .frame(width: 28, height: 28)
                    .overlay(
                        Text("\(number)")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                    )
                if showConnector {
                    Canvas { ctx, size in
                        var path = Path()
                        path.move(to: CGPoint(x: size.width / 2, y: 0))
                        path.addLine(to: CGPoint(x: size.width / 2, y: size.height))
                        ctx.stroke(path, with: .color(.gray.opacity(0.4)),
                                   style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    }
                    .frame(width: 28, height: 44)
                    .padding(.top, 4)
                }
            }
            .frame(width: 28, alignment: .top)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.semiBold14)
                Text(detail)
                    .font(.regular12)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, showConnector ? 16 : 0)
        }
    }
}

#Preview { FurnitureCaptureGuideView(vm: ScanViewModel()) }
