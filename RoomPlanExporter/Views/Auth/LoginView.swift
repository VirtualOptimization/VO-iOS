import SwiftUI

struct LoginView: View {
    @ObservedObject var authVM: AuthViewModel
    let onSignUp: () -> Void

    @State private var id: String = ""
    @State private var password: String = ""
    @State private var autoLogin: Bool = false
    @FocusState private var focused: Field?
    enum Field { case id, pw }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 60)

            // 로고 (작게)
            Image("logo")
                .resizable()
                .scaledToFit()
                .frame(width: 92)
                .padding(.bottom, 48)

            // 입력 필드
            VStack(spacing: 0) {
                UnderlineField(placeholder: "아이디를 입력하세요", text: $id)
                    .focused($focused, equals: .id)
                    .submitLabel(.next)
                    .onSubmit { focused = .pw }

                UnderlineField(placeholder: "비밀번호를 입력하세요", text: $password, isSecure: true)
                    .focused($focused, equals: .pw)
                    .submitLabel(.done)
                    .onSubmit { doLogin() }
            }
            .padding(.horizontal, 40)

            // 자동 로그인
            HStack {
                Spacer()
                Toggle(isOn: $autoLogin) {
                    Text("자동 로그인")
                        .font(.regular12)
                        .foregroundStyle(Color(.systemGray))
                }
                .toggleStyle(CheckboxToggleStyle())
            }
            .padding(.horizontal, 40)
            .padding(.top, 10)

            // 에러 메시지
            if let err = authVM.loginError {
                Text(err)
                    .font(.regular12)
                    .foregroundStyle(.red)
                    .padding(.top, 14)
            }

            Spacer()

            // 하단 버튼
            VStack(spacing: 16) {
                Button("로그인") { doLogin() }
                    .buttonStyle(VOFilledButtonStyle())
                    .disabled(authVM.isLoading)

                Button("회원가입", action: onSignUp)
                    .font(.semiBold14)
                    .foregroundStyle(Color(.systemGray))
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 52)
        }
        .contentShape(Rectangle())
        .onTapGesture { focused = nil }
    }

    private func doLogin() {
        focused = nil
        authVM.login(id: id, password: password, autoLogin: autoLogin)
    }
}

// MARK: - Underline Text Field

struct UnderlineField: View {
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false

    @State private var isRevealed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Group {
                    if isSecure && !isRevealed {
                        SecureField(placeholder, text: $text)
                    } else {
                        TextField(placeholder, text: $text)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                }
                .font(.regular14)

                if isSecure {
                    Button {
                        isRevealed.toggle()
                    } label: {
                        Image(systemName: isRevealed ? "eye.slash" : "eye")
                            .font(.system(size: 15))
                            .foregroundStyle(Color(.systemGray))
                    }
                }
            }
            .padding(.vertical, 16)

            Rectangle()
                .fill(Color(.systemGray5))
                .frame(height: 1)
        }
    }
}

// MARK: - Checkbox Toggle

struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(configuration.isOn ? Color.voBlue : Color(.systemGray3))
                    .font(.system(size: 15))
                configuration.label
            }
        }
        .buttonStyle(.plain)
    }
}
