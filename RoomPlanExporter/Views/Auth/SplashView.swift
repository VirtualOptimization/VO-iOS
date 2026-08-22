import SwiftUI

struct SplashView: View {
    let onLogin: () -> Void
    let onSignUp: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Spacer()

            // 태그라인 + 로고
            VStack(spacing: 12) {
                Text("보는 것을 넘어, 최적을 찾다")
                    .font(.semiBold14)
                    .foregroundStyle(Color(.systemGray))

                Image("logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 200)
            }

            Spacer()
            Spacer()
            Spacer()

            // 버튼 영역
            VStack(spacing: 16) {
                Button("로그인", action: onLogin)
                    .buttonStyle(VOFilledButtonStyle())

                Button("회원가입", action: onSignUp)
                    .font(.semiBold14)
                    .foregroundStyle(Color(.systemGray))
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 52)
        }
    }
}
