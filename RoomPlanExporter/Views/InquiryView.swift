import SwiftUI

struct InquiryView: View {
    @ObservedObject var vm: ScanViewModel

    @State private var confirmCode = ""
    @FocusState private var isFocused: Bool

    private var canSubmit: Bool {
        !confirmCode.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // 배너
            HStack(spacing: 10) {
                Image("logo_white")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 20)
                Text("공간 조회")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 20)
            .background(Color.voBlue)

            Spacer()

            VStack(spacing: 28) {
                // 안내
                VStack(spacing: 8) {
                    Text("확인 코드를 입력해주세요")
                        .font(.title3.bold())
                    Text("저장 시 받은 확인 코드로 이전 결과를\n다시 조회하고 최적화할 수 있어요")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                // 코드 입력 필드
                TextField("예: A1B2C3D4", text: $confirmCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.title2.bold())
                    .tracking(4)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 16)
                    .padding(.horizontal, 20)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color(.secondarySystemBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(isFocused ? Color.voBlue : Color.clear, lineWidth: 1.5)
                    )
                    .focused($isFocused)
                    .onSubmit {
                        if canSubmit { vm.fetchByCode(confirmCode: confirmCode) }
                    }

                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                    Text("확인 코드는 저장 완료 화면에서 복사할 수 있어요")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 40)

            Spacer()

            // 하단 버튼
            VStack(spacing: 12) {
                Button("조회하기") {
                    isFocused = false
                    vm.fetchByCode(confirmCode: confirmCode)
                }
                .buttonStyle(VOFilledButtonStyle())
                .disabled(!canSubmit)
                .opacity(canSubmit ? 1 : 0.5)

                Button("돌아가기") { vm.retake() }
                    .buttonStyle(VOOutlineButtonStyle())
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 52)
        }
        .onTapGesture { isFocused = false }
    }
}

#Preview {
    InquiryView(vm: ScanViewModel())
}
