import SwiftUI

// MARK: - AI 배치 상담 패널
//
// 예전엔 풀스크린 화면으로 따로 떴는데, 방 3D 뷰와 분리된 느낌이 커서 지금은 InquiryResultView
// 위에 반투명 패널로 얹는 방식으로 바꿨다 — 대화하는 동안에도 뒤에 같은 3D 뷰가 계속 보이고,
// 가구 제외 시뮬레이션(F03) 결과는 그 자리에서 바로 가구가 숨겨지는 걸로 확인할 수 있다.

struct AssistantPanelView: View {
    @ObservedObject var vm: AssistantViewModel
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if vm.isRoomLoading {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("방 데이터를 불러오는 중...")
                        .font(.regular12)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 16)
            } else {
                if !vm.messages.isEmpty || vm.isLoading {
                    messageList
                } else {
                    suggestions
                }
                inputBar
            }
        }
        // 패널 자체는 배경 없이 — 대화 중에도 뒤의 3D 방이 그대로 보이도록 말풍선과 입력창에만
        // 반투명 배경을 둔다.
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .task { await vm.loadRoomIfNeeded() }
        .alert("오류", isPresented: .constant(vm.errorText != nil), actions: {
            Button("확인") { vm.errorText = nil }
        }, message: {
            Text(vm.errorText ?? "")
        })
    }

    // MARK: Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(vm.messages) { msg in
                        bubble(for: msg).id(msg.id)
                    }
                    if vm.isLoading {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.7)
                            Text("생각 중...")
                                .font(.regular11)
                                .foregroundStyle(.secondary)
                        }
                        .id("loading")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)
            }
            .frame(maxHeight: 240)
            .onChange(of: vm.messages.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: vm.isLoading) { _, _ in scrollToBottom(proxy) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation {
            if vm.isLoading {
                proxy.scrollTo("loading", anchor: .bottom)
            } else if let last = vm.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func bubble(for msg: ChatMessage) -> some View {
        HStack {
            if msg.role == .user { Spacer(minLength: 40) }
            Group {
                if msg.role == .user {
                    Text(msg.text)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Color.voBlue, in: RoundedRectangle(cornerRadius: 14))
                } else {
                    Text(msg.text)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .font(.regular13)
            if msg.role == .assistant { Spacer(minLength: 40) }
        }
    }

    // MARK: Suggestions (첫 진입 시)

    private var suggestions: some View {
        HStack(spacing: 8) {
            suggestionChip("소파 140cm 여기 들어갈까?")
            suggestionChip("책상 빼면 얼마나 넓어져?")
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
    }

    private func suggestionChip(_ text: String) -> some View {
        Button {
            vm.inputText = text
            vm.send()
        } label: {
            Text(text)
                .font(.regular11)
                .foregroundStyle(Color.voBlue)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.voBlue.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Input bar

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("방에 대해 물어보세요", text: $vm.inputText)
                .font(.regular13)
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit { vm.send() }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())

            Button(action: { vm.send() }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(canSend ? Color.voBlue : Color(.systemGray3))
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var canSend: Bool {
        !vm.inputText.trimmingCharacters(in: .whitespaces).isEmpty && !vm.isLoading
    }
}
