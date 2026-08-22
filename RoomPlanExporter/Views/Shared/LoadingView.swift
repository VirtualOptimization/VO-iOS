import SwiftUI

struct LoadingView: View {
    let statusText: String
    let tips: [String]

    @State private var colorProgress: Double = 0
    @State private var tipIndex: Int = 0

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            // TimelineView로 끊김 없는 좌→우 wipe
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                // -0.3 → 1.3 범위로 이동: 시작/끝이 둘 다 화면 밖 → 리셋이 안 보임
                let raw = CGFloat(t.truncatingRemainder(dividingBy: 2.2) / 2.2)
                let scan = raw * 1.6 - 0.3
                // 오프셋이 일정하게 증가하는 값들이라, 양쪽을 다 0...1로 클램프해야
                // (한쪽만 클램프하면 scan이 범위 밖일 때 순서가 역전돼 경고가 남) 항상 오름차순이 보장됨.
                let clamp: (CGFloat) -> CGFloat = { min(max($0, 0), 1) }

                ZStack {
                    Image("logo_white")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 110)

                    Image("logo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 110)
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: clamp(scan - 0.5)),
                                    .init(color: .black, location: clamp(scan - 0.05)),
                                    .init(color: .black, location: clamp(scan + 0.05)),
                                    .init(color: .clear, location: clamp(scan + 0.4))
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                }
            }

            // 상태 텍스트
            Text(statusText)
                .font(.medium14)
                .foregroundStyle(.voBlue)
                .padding(.top, -40)

            // 팁 영역
            VStack(spacing: 10) {
                Text("Tip")
                    .font(.semiBold10)
                    .foregroundStyle(.voBlue)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 1)
                    .overlay(Capsule().stroke(Color.voBlue, lineWidth: 1))

                Text(tips[tipIndex])
                    .font(.regular14)
                    .foregroundStyle(.gray)
                    .multilineTextAlignment(.center)
                    .id(tipIndex)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.4), value: tipIndex)
                    .padding(.top, 3)
            }

            Spacer()
        }
        .padding(.horizontal, 40)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                withAnimation {
                    tipIndex = (tipIndex + 1) % tips.count
                }
            }
        }
    }
}

#Preview {
    LoadingView(
        statusText: "내 방 저장 중..",
        tips: [
            "데이터를 안전하게\n서버로 보내고 있어요",
            "공간 데이터를 \n서버에 전송하고 있어요",
            "저장이 끝나면 \n최적화를 실행해볼 수 있어요"
        ]
    )
}
