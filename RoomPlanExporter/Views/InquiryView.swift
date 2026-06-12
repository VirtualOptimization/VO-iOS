import SwiftUI

struct InquiryView: View {
    @ObservedObject var vm: ScanViewModel

    @State private var confirmCode = ""
    @FocusState private var isFocused: Bool

    private var canSubmit: Bool {
        !confirmCode.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { vm.retake() } label: {
                Image(systemName: "chevron.left")
                    .font(.semiBold20)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 30)
                    .padding(.top, 20)
                    .padding(.bottom, 40)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("공간 조회 🔍")
                    .font(.title2.bold())
                Text("이전에 저장한 공간 및 최적화 결과를 확인하고 싶다면\n발행된 확인 코드를 입력해주세요")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 48)

            // 언더라인 스타일 텍스트필드
            VStack(spacing: 0) {
                TextField("확인 코드 입력", text: $confirmCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.title3.bold())
                    .tracking(4)
                    .focused($isFocused)
                    .padding(.bottom, 10)
                    .onSubmit {
                        if canSubmit { vm.fetchByCode(confirmCode: confirmCode) }
                    }

                Rectangle()
                    .frame(height: 1.5)
                    .foregroundStyle(Color.voBlue)
            }
            .padding(.horizontal, 30)

            Spacer()

            Button("조회하기") {
                isFocused = false
                vm.fetchByCode(confirmCode: confirmCode)
            }
            .buttonStyle(VOFilledButtonStyle())
            .disabled(!canSubmit)
            .opacity(canSubmit ? 1 : 0.5)
            .padding(.horizontal, 50)
            .padding(.bottom, 52)
        }
        .onTapGesture { isFocused = false }
    }
}

// MARK: - 조회 중 로딩 화면 (InquiryView 헤더 + LoadingView 애니메이션)

struct InquiryLoadingView: View {
    let tips: [String]

    @State private var tipIndex = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "chevron.left")
                .font(.semiBold20)
                .foregroundStyle(.black)
                .padding(.horizontal, 30)
                .padding(.top, 20)
                .padding(.bottom, 40)

            VStack(alignment: .leading, spacing: 10) {
                Text("공간 조회 🔍")
                    .font(.title2.bold())
                Text("이전에 저장한 공간 및 최적화 결과를 확인하고 싶다면\n발행된 확인 코드를 입력해주세요")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 30)

            Spacer()

            VStack(spacing: 28) {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let raw = CGFloat(t.truncatingRemainder(dividingBy: 2.2) / 2.2)
                    let scan = raw * 1.6 - 0.3

                    ZStack {
                        Image("logo_white").resizable().scaledToFit().frame(width: 110)
                        Image("logo").resizable().scaledToFit().frame(width: 110)
                            .mask(
                                LinearGradient(
                                    stops: [
                                        .init(color: .clear, location: max(0, scan - 0.5)),
                                        .init(color: .black, location: max(0, scan - 0.05)),
                                        .init(color: .black, location: min(1, scan + 0.05)),
                                        .init(color: .clear, location: min(1, scan + 0.4))
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                    }
                }

                Text("결과 불러오는 중..")
                    .font(.medium14)
                    .foregroundStyle(.voBlue)
                    .padding(.top, -40)

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
                        .padding(.top, 10)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 40)

            Spacer()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                withAnimation { tipIndex = (tipIndex + 1) % tips.count }
            }
        }
    }
}

#Preview {
    InquiryView(vm: ScanViewModel())
}

#Preview("로딩") {
    InquiryLoadingView(tips: ["저장된 데이터를 찾아\n불러오고 있어요", "잠시 후 결과가 나와요"])
}
