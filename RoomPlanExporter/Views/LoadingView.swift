import SwiftUI

struct LoadingView: View {
    let statusText: String
    let tips: [String]

    @State private var colorProgress: Double = 0
    @State private var tipIndex: Int = 0

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            // logo_white → logo 컬러 반복 애니메이션
            ZStack {
                Image("logo_white")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 110)

                Image("logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 110)
                    .opacity(colorProgress)
            }

            // 상태 텍스트
            Text(statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // 팁 영역
            VStack(spacing: 10) {
                Text("Tip")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .overlay(Capsule().stroke(Color.secondary.opacity(0.35), lineWidth: 1))

                Text(tips[tipIndex])
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .id(tipIndex)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.4), value: tipIndex)
            }

            Spacer()
        }
        .padding(.horizontal, 40)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                colorProgress = 1.0
            }
        }
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
            "잠시만 기다려주세요",
            "공간 데이터를 서버에 전송하고 있어요",
            "저장이 끝나면 최적화를 실행해볼 수 있어요"
        ]
    )
}
