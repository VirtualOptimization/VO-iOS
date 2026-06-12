import SwiftUI

struct ScanGuideView: View {
    @ObservedObject var vm: ScanViewModel

    private let tips: [(String, String)] = [
        ("방은 환하게 유지하기",
         "방의 모든 불을 켜주세요. 공간이 밝을수록\n가구의 형태와 색상이 더 선명하게 복제됩니다."),
        ("이동은 최대한 천천히",
         "비디오를 찍듯이 아주 천천히 움직여주세요.\n급격한 회전은 데이터가 누락되는 원인이 됩니다."),
        ("시선은 위아래 골고루",
         "가구의 윗면과 바닥까지 충분히 담아주세요.\n다양한 각도에서 찍어야 정확한 분석이 가능합니다."),
        ("거울과 유리창 주의",
         "거울이나 유리창은 가려주면 더 정확합니다.\n빛 반사가 적어야 왜곡 없이 데이터가 수집됩니다.")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { vm.phase = .main } label: {
                Image(systemName: "chevron.left")
                    .font(.semiBold20)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 30)
                    .padding(.top, 20)
                    .padding(.bottom, 40)
            }

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("공간 촬영 및 분석 📷\n이용 안내")
                            .font(.title2.bold())
                        Text("원활하고 정확한 공간 촬영을 위해 확인해주세요!")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 40)
                    .padding(.bottom, 45)

                    VStack(spacing: 0) {
                        ForEach(Array(tips.enumerated()), id: \.offset) { i, tip in
                            TipRow(number: i + 1, title: tip.0, detail: tip.1,
                                   showConnector: i < tips.count - 1)
                        }
                    }
                    .padding(.horizontal, 40)
                }
                .padding(.bottom, 16)
            }

            Button("촬영 시작") { vm.startCountdown() }
                .buttonStyle(VOFilledButtonStyle())
                .padding(.horizontal, 40)
                .padding(.top, 12)
                .padding(.bottom, 48)
        }
    }
}

private struct TipRow: View {
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
                    .font(.subheadline.bold())
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, showConnector ? 16 : 0)
        }
    }
}

#Preview { ScanGuideView(vm: ScanViewModel()) }
