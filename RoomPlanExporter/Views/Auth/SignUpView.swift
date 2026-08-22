import SwiftUI

struct SignUpView: View {
    @ObservedObject var authVM: AuthViewModel
    let onBack: () -> Void

    @State private var name: String = ""
    @State private var id: String = ""
    @State private var password: String = ""
    @State private var passwordConfirm: String = ""
    @State private var email: String = ""
    @State private var verifyCode: String = ""
    @State private var remainingSeconds: Int = 0
    @State private var countdownTask: Task<Void, Never>? = nil

    private var countdownText: String {
        String(format: "%d:%02d", remainingSeconds / 60, remainingSeconds % 60)
    }

    @FocusState private var focused: Field?
    enum Field { case name, id, pw, pwConfirm, email, code }

    private var pwHint8: Bool { password.count >= 8 }
    private var pwHintSpecial: Bool {
        password.rangeOfCharacter(
            from: CharacterSet.uppercaseLetters
                .union(.punctuationCharacters)
                .union(.symbols)
        ) != nil
    }
    private var pwMatch: Bool { !password.isEmpty && password == passwordConfirm }
    private var canSignUp: Bool {
        !name.isEmpty && !id.isEmpty && pwHint8 && pwHintSpecial && pwMatch && authVM.emailVerified
    }

    var body: some View {
        VStack(spacing: 0) {
            navBar

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    formFields
                    verifySection
                }
                .padding(.horizontal, 30)
                .padding(.top, 24)
                .padding(.bottom, 110)
            }
        }
        .overlay(alignment: .bottom) {
            if canSignUp {
                Button("가입 완료") { doSignUp() }
                    .buttonStyle(VOFilledButtonStyle())
                    .padding(.horizontal, 30)
                    .padding(.bottom, 44)
                    .background(
                        LinearGradient(
                            colors: [.clear, Color(.systemBackground)],
                            startPoint: .top,
                            endPoint: UnitPoint(x: 0.5, y: 0.6)
                        )
                        .ignoresSafeArea(edges: .bottom)
                    )
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { focused = nil }
        .onChange(of: authVM.signupSucceeded) { _, succeeded in
            if succeeded {
                authVM.signupSucceeded = false
                onBack()
            }
        }
        .onChange(of: authVM.emailVerified) { _, verified in
            if verified { countdownTask?.cancel() }
        }
    }

    // MARK: Nav bar

    private var navBar: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("회원가입")
                    .font(.semiBold16)

                HStack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.voBlue)
                    }
                    Spacer()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()
        }
    }

    // MARK: Form

    private var formFields: some View {
        VStack(spacing: 0) {
            UnderlineField(placeholder: "이름[닉네임]", text: $name)
                .focused($focused, equals: .name)
                .submitLabel(.next)
                .onSubmit { focused = .id }

            UnderlineField(placeholder: "아이디", text: $id)
                .focused($focused, equals: .id)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .onSubmit { focused = .pw }

            UnderlineField(placeholder: "비밀번호", text: $password, isSecure: true)
                .focused($focused, equals: .pw)
                .submitLabel(.next)
                .onSubmit { focused = .pwConfirm }

            // 비밀번호 힌트
            VStack(alignment: .leading, spacing: 3) {
                hintRow(text: "8자 이상이어야 합니다.", active: pwHint8)
                hintRow(text: "대문자/특수기호 중 하나를 포함해야 합니다.", active: pwHintSpecial)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
            .padding(.bottom, 2)

            UnderlineField(placeholder: "비밀번호 재입력", text: $passwordConfirm, isSecure: true)
                .focused($focused, equals: .pwConfirm)
                .submitLabel(.done)
                .onSubmit { focused = nil }
        }
    }

    private func hintRow(text: String, active: Bool) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(active ? Color.voBlue : Color(.systemGray4))
                .frame(width: 4, height: 4)
            Text("• \(text)")
                .font(.regular11)
                .foregroundStyle(Color.voBlue)
        }
    }

    // MARK: Email verify

    private var verifySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("인증")
                .font(.semiBold14)
                .foregroundStyle(Color.voBlue)
                .padding(.top, 28)
                .padding(.bottom, 4)

            // 이메일 + 인증하기 버튼
            HStack(spacing: 8) {
                UnderlineField(placeholder: "email@example.com", text: $email)
                    .focused($focused, equals: .email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)

                Button("인증하기") { sendVerify() }
                    .font(.semiBold13)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.voBlue, in: Capsule())
                    .fixedSize()
                    .disabled(email.isEmpty)
                    .opacity(email.isEmpty ? 0.5 : 1)
            }

            // 인증번호 입력
            HStack(spacing: 8) {
                ZStack(alignment: .trailing) {
                    UnderlineField(placeholder: "인증번호", text: $verifyCode)
                        .focused($focused, equals: .code)
                        .keyboardType(.numberPad)
                        .disabled(authVM.emailVerified)

                    if authVM.emailVerified {
                        Text("인증되었습니다")
                            .font(.regular12)
                            .foregroundStyle(Color.voBlue)
                            .padding(.bottom, 2)
                    }
                }

                if !authVM.emailVerified {
                    Button("확인") { verifyCodeTapped() }
                        .font(.semiBold13)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Color.voBlue, in: Capsule())
                        .fixedSize()
                        .disabled(verifyCode.isEmpty)
                        .opacity(verifyCode.isEmpty ? 0.5 : 1)
                }
            }

            if let message = authVM.emailSendMessage, !authVM.emailVerified {
                HStack(spacing: 6) {
                    Text(message)
                        .font(.regular12)
                        .foregroundStyle(.secondary)
                    if remainingSeconds > 0 {
                        Text(countdownText)
                            .font(.semiBold12)
                            .foregroundStyle(Color.voBlue)
                    }
                }
                .padding(.top, 4)
            }
            if let error = authVM.emailError {
                Text(error)
                    .font(.regular12)
                    .foregroundStyle(.red)
                    .padding(.top, 4)
            }
            if let error = authVM.loginError {
                Text(error)
                    .font(.regular12)
                    .foregroundStyle(.red)
                    .padding(.top, 4)
            }
        }
    }

    // MARK: Actions

    private func sendVerify() {
        focused = nil
        authVM.sendEmailCode(email: email)
        startCountdown()
    }

    private func startCountdown() {
        countdownTask?.cancel()
        remainingSeconds = 300
        countdownTask = Task {
            while remainingSeconds > 0 && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                remainingSeconds -= 1
            }
        }
    }

    private func verifyCodeTapped() {
        focused = nil
        authVM.verifyEmailCode(email: email, code: verifyCode)
    }

    private func doSignUp() {
        authVM.signUp(name: name, id: id, password: password, passwordConfirm: passwordConfirm, email: email)
    }
}
