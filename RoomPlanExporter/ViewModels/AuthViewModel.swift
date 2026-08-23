import SwiftUI

@MainActor
final class AuthViewModel: ObservableObject {
    @Published var isLoggedIn: Bool = false
    @Published var username: String = ""
    @Published var loginError: String? = nil
    @Published var isLoading: Bool = false

    // 회원가입 이메일 인증 상태
    @Published var emailVerified: Bool = false
    @Published var emailSendMessage: String? = nil
    @Published var emailError: String? = nil
    /// 회원가입 성공 시 true로 바뀜 — SignUpView가 이걸 보고 로그인 화면으로 돌아감
    @Published var signupSucceeded: Bool = false

    private let authService = AuthService()

    init() {
        if let refreshToken = KeychainTokenStore.get(.refreshToken) {
            Task { await restoreSession(refreshToken: refreshToken) }
        }
    }

    // MARK: 세션 복구 (앱 시작 시 저장된 refresh token으로)

    private func restoreSession(refreshToken: String) async {
        do {
            let accessToken = try await authService.refresh(refreshToken: refreshToken)
            KeychainTokenStore.set(accessToken, for: .accessToken)
            let me = try await authService.me(accessToken: accessToken)
            username = me.nickname.isEmpty ? me.loginId : me.nickname
            isLoggedIn = true
        } catch {
            KeychainTokenStore.delete(.accessToken)
            KeychainTokenStore.delete(.refreshToken)
        }
    }

    // MARK: 로그인

    func login(id: String, password: String, autoLogin: Bool) {
        let trimId = id.trimmingCharacters(in: .whitespaces)

        loginError = nil
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let tokens = try await authService.login(loginId: trimId, password: password)
                KeychainTokenStore.set(tokens.accessToken, for: .accessToken)
                if autoLogin {
                    KeychainTokenStore.set(tokens.refreshToken, for: .refreshToken)
                } else {
                    KeychainTokenStore.delete(.refreshToken)
                }
                let me = try await authService.me(accessToken: tokens.accessToken)
                username = me.nickname.isEmpty ? me.loginId : me.nickname
                isLoggedIn = true
            } catch {
                loginError = (error as? APIError)?.detail ?? "아이디 또는 비밀번호가 올바르지 않아요"
            }
        }
    }

    // MARK: 이메일 인증 (회원가입 흐름)

    func sendEmailCode(email: String) {
        emailError = nil
        emailSendMessage = nil
        Task {
            do {
                try await authService.sendEmailCode(email: email)
                emailSendMessage = "인증번호가 발송되었어요"
            } catch {
                emailError = (error as? APIError)?.detail ?? "인증번호 발송에 실패했어요"
            }
        }
    }

    func verifyEmailCode(email: String, code: String) {
        emailError = nil
        Task {
            do {
                let ok = try await authService.verifyEmailCode(email: email, code: code)
                emailVerified = ok
                if !ok { emailError = "인증번호가 올바르지 않아요" }
            } catch {
                emailVerified = false
                emailError = (error as? APIError)?.detail ?? "인증번호가 올바르지 않아요"
            }
        }
    }

    // MARK: 회원가입

    func signUp(name: String, id: String, password: String, passwordConfirm: String, email: String) {
        let trimId = id.trimmingCharacters(in: .whitespaces)
        loginError = nil
        signupSucceeded = false
        Task {
            do {
                _ = try await authService.signUp(loginId: trimId, password: password, passwordConfirm: passwordConfirm,
                                                  email: email, nickname: name)
                // 가입 완료 → 자동 로그인하지 않고 로그인 화면으로 돌아가서 직접 로그인하게 함
                signupSucceeded = true
            } catch {
                loginError = (error as? APIError)?.detail ?? "회원가입에 실패했어요"
            }
        }
    }

    // MARK: 로그아웃

    func logout() {
        let refreshToken = KeychainTokenStore.get(.refreshToken)
        Task {
            if let refreshToken {
                try? await authService.logout(refreshToken: refreshToken)
            }
        }
        KeychainTokenStore.delete(.accessToken)
        KeychainTokenStore.delete(.refreshToken)
        isLoggedIn = false
        username = ""
        emailVerified = false
        emailSendMessage = nil
        emailError = nil
    }
}
