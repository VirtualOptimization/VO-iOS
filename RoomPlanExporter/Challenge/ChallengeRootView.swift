import SwiftUI
import Combine

struct ChallengeRootView: View {
    var onClose: (() -> Void)? = nil
    @StateObject private var vm = ChallengeViewModel()
    @StateObject private var editSession = FurnitureEditSession()
    @State private var name = ""
    @State private var phone = ""
    @State private var consent = false
    @State private var confirmSubmit = false
    @State private var confirmExit = false
    @State private var confirmNewParticipant = false
    @State private var showPlacementHints = false
    @FocusState private var focusedField: EntryField?

    private enum EntryField: Hashable { case name, phone }

    private var validEntry: Bool {
        (1...12).contains(name.trimmingCharacters(in: .whitespacesAndNewlines).count)
        && phone.filter { $0 >= "0" && $0 <= "9" }.hasPrefix("0")
        && (10...11).contains(phone.filter { $0 >= "0" && $0 <= "9" }.count)
        && phone.allSatisfy { ($0 >= "0" && $0 <= "9") || $0 == "-" || $0.isWhitespace }
        && consent
    }

    private var isPlaying: Bool { vm.screen == .game || vm.screen == .submitting }

    private var screenTitle: String {
        switch vm.screen {
        case .welcome, .loading: "가구 배치 챌린지"
        case .entry: "참가자 정보"
        case .criteria: "채점 기준"
        case .game, .submitting: "가구 배치"
        case .result: "도전 결과"
        case .leaderboard: "챌린지 랭킹"
        }
    }

    private func restart() {
        vm.restart()
        name = ""
        phone = ""
        consent = false
    }

    private func goBack() {
        focusedField = nil
        switch vm.screen {
        case .entry, .criteria: vm.screen = .welcome
        case .game, .submitting: confirmExit = true
        case .result: restart()
        case .leaderboard: vm.closeRanking()
        case .welcome, .loading: break
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            banner
            switch vm.screen {
            case .welcome: welcome
            case .entry: entry
            case .criteria: criteria
            case .loading:
                ProgressView("방을 준비하고 있어요…")
                    .font(.regular13)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .game, .submitting: game
            case .result: result
            case .leaderboard: leaderboard
            }
        }
        .font(.regular13)
        .foregroundStyle(.primary)
        .tint(Color.voBlue)
        .background(Color(.systemBackground).ignoresSafeArea())
        .interactiveDismissDisabled(isPlaying || vm.isWorking || vm.hasPendingSubmission)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("완료") { focusedField = nil }
            }
        }
        .task { await vm.loadEvent() }
        .sheet(isPresented: $showPlacementHints) {
            placementHints
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .alert("알림", isPresented: Binding(get: { vm.errorMessage != nil },
                                          set: { if !$0 { vm.errorMessage = nil } })) {
            if vm.screen == .welcome && vm.event == nil {
                Button("다시 시도") { Task { await vm.loadEvent() } }
            }
            Button("확인", role: .cancel) { vm.errorMessage = nil }
        } message: { Text(vm.errorMessage ?? "") }
        .confirmationDialog("다른 참가자로 시작할까요?", isPresented: $confirmNewParticipant) {
            Button("참가 정보 지우고 시작", role: .destructive) {
                vm.forgetParticipant()
                name = ""; phone = ""; consent = false
            }
            Button("취소", role: .cancel) {}
        } message: { Text("이 기기의 참가 정보가 삭제돼요. 이전 참가자는 같은 번호로 다시 등록할 수 없어요.") }
        .confirmationDialog("이 배치로 제출할까요?", isPresented: $confirmSubmit) {
            Button("제출하기") { Task { await vm.submit(edits: editSession.pendingEdits()) } }
            Button("계속 편집", role: .cancel) {}
        } message: { Text("제출 후에는 이번 도전의 배치를 수정할 수 없어요.") }
        .confirmationDialog("도전을 그만둘까요?", isPresented: $confirmExit) {
            Button("기준 안내로 돌아가기", role: .destructive) { vm.leaveGame() }
            Button("계속하기", role: .cancel) {}
        } message: { Text("현재 배치는 저장되지 않아요.") }
    }

    // Same banner, fonts and controls as the room viewer and scan completion screens.
    private var banner: some View {
        ZStack {
            Text(screenTitle)
                .font(.semiBold14)
                .foregroundStyle(.white)
                .padding(.horizontal, isPlaying ? 108 : 68)
                .frame(maxWidth: .infinity)
            HStack {
                if vm.screen == .welcome || vm.screen == .loading {
                    Image("logo_white")
                        .resizable().scaledToFit().frame(height: 42)
                        .accessibilityHidden(true)
                } else {
                    Button(action: goBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("이전 화면")
                    .disabled(vm.isWorking || vm.hasPendingSubmission)
                }
                Spacer()
                if isPlaying {
                    HStack(spacing: 8) {
                        Text("\(vm.seconds / 60):\(String(format: "%02d", vm.seconds % 60))")
                            .font(.semiBold13).monospacedDigit()
                            .frame(minWidth: 48)
                            .accessibilityLabel("경과 시간 \(vm.seconds)초")
                        Button { showPlacementHints = true } label: {
                            Image(systemName: "key.fill")
                                .font(.system(size: 18, weight: .medium))
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("배치 힌트 보기")
                        .disabled(vm.isWorking)
                    }
                } else if vm.screen == .leaderboard {
                    Button { Task { await vm.loadRanking() } } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 17, weight: .medium))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("랭킹 새로고침")
                    .disabled(vm.isWorking)
                } else if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("챌린지 닫기")
                    .disabled(vm.isWorking || vm.hasPendingSubmission)
                }
            }
            .foregroundStyle(.white)
            .buttonStyle(.plain)
        }
        .frame(minHeight: 52)
        .padding(.horizontal, 20)
        .voGlassBanner()
    }

    private var welcome: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 520
            VStack(spacing: 0) {
                Spacer(minLength: compact ? 12 : 24)
                Text("보는 것을 넘어, 최적을 찾다")
                    .font(.semiBold14).foregroundStyle(.secondary)
                Image("logo")
                    .resizable().scaledToFit().frame(width: compact ? 120 : 160)
                    .padding(.top, compact ? 10 : 16)
                    .accessibilityLabel("V-O")
                Text("내 손으로 바꾸는 공간")
                    .font(.semiBold20).padding(.top, compact ? 18 : 30)
                Text("가구를 옮기고 점수를 확인해보세요.\n나만의 배치로 랭킹에 도전할 수 있어요.")
                    .font(.regular13).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).lineSpacing(5)
                    .padding(.top, 10)
                VStack(spacing: 0) {
                    welcomeStep("01", "참가자 정보 입력", "닉네임과 연락처를 입력해주세요", compact: compact)
                    Divider()
                    welcomeStep("02", "가구 배치하기", "방 안의 가구를 자유롭게 옮겨보세요", compact: compact)
                    Divider()
                    welcomeStep("03", "점수와 랭킹 확인", "AI 배치와 비교하고 순위를 확인해보세요", compact: compact)
                }
                .padding(.top, compact ? 16 : 28)
                Spacer(minLength: 12)
                if vm.isWorking {
                    ProgressView().accessibilityLabel("이벤트 확인 중")
                } else if vm.event?.isActive == false {
                    Text("지금은 참여할 수 없어요")
                        .font(.regular12).foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 12)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) {
                if vm.hasSession {
                    Button("내 도전 이어하기") { Task { await vm.resume() } }
                        .buttonStyle(VOFilledButtonStyle()).disabled(vm.isWorking)
                } else {
                    Button("챌린지 시작하기") { vm.screen = .entry }
                        .buttonStyle(VOFilledButtonStyle())
                        .disabled(vm.event?.isActive != true || vm.isWorking)
                        .opacity(vm.event?.isActive == true ? 1 : 0.45)
                }
                Button("현재 랭킹 보기") { Task { await vm.loadRanking() } }
                    .buttonStyle(VOOutlineButtonStyle())
                    .disabled(vm.event == nil || vm.isWorking)
                if vm.hasSession {
                    Button("다른 참가자 등록") { confirmNewParticipant = true }
                        .font(.semiBold14).foregroundStyle(.secondary)
                        .disabled(vm.hasPendingSubmission || vm.isWorking)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 40).padding(.top, 12).padding(.bottom, 24)
            .background(Color(.systemBackground))
        }
    }

    private func welcomeStep(_ number: String, _ title: String, _ detail: String, compact: Bool) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(number).font(.semiBold12).foregroundStyle(.secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.semiBold13)
                Text(detail).font(.regular11).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, compact ? 10 : 16)
    }

    private var entry: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Text("참가자 정보를 입력해주세요")
                    .font(.semiBold20).padding(.top, 32)
                Text("닉네임은 랭킹에 그대로 표시돼요.")
                    .font(.regular12).foregroundStyle(.secondary).padding(.top, 10)
                VStack(spacing: 0) {
                    UnderlineField(placeholder: "닉네임을 입력하세요 (최대 12자)", text: $name)
                        .focused($focusedField, equals: .name)
                        .submitLabel(.next).onSubmit { focusedField = .phone }
                        .accessibilityLabel("닉네임")
                    UnderlineField(placeholder: "휴대전화 번호를 입력하세요", text: $phone)
                        .keyboardType(.phonePad).textContentType(.telephoneNumber)
                        .focused($focusedField, equals: .phone)
                        .accessibilityLabel("휴대전화 번호")
                }
                .padding(.top, 28)
                Toggle(isOn: $consent) {
                    Text("개인정보 수집·이용에 동의합니다")
                        .font(.regular12)
                }
                .toggleStyle(CheckboxToggleStyle())
                .padding(.top, 28)
                Text("수집 항목: 닉네임, 전화번호\n이용 목적: 순위 확인 및 경품 안내\n보관 기간: 전시 종료 후 30일 이내 파기\n\n닉네임은 순위표에 공개됩니다.\n동의하지 않으면 참여할 수 없습니다.")
                    .font(.regular11).foregroundStyle(.secondary).lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 16).padding(.bottom, 28)
            }
            .padding(.horizontal, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button("기준 확인하기") {
                focusedField = nil
                Task {
                    await vm.start(name: name, phone: phone)
                    if vm.hasSession { name = ""; phone = ""; consent = false }
                }
            }
            .buttonStyle(VOFilledButtonStyle()).disabled(!validEntry || vm.isWorking)
            .opacity(validEntry && !vm.isWorking ? 1 : 0.45)
            .padding(.horizontal, 40).padding(.top, 16).padding(.bottom, 24)
            .background(Color(.systemBackground))
        }
    }

    private var criteria: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("가구를 옮기기 전에\n채점 기준을 확인해주세요")
                        .font(.semiBold20).lineSpacing(4)
                    Text("세 가지 기준으로 배치를 평가해요.")
                        .font(.regular12).foregroundStyle(.secondary)
                }
                .padding(.top, 28)
                ForEach(vm.event?.criteria ?? []) { item in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(item.title).font(.semiBold16)
                            Spacer()
                            Text("\(item.maxScore, specifier: "%.0f")점").font(.semiBold14)
                        }
                        Text(item.description).font(.regular12)
                            .foregroundStyle(.secondary).lineSpacing(4)
                    }
                    .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    .voGlassCard(cornerRadius: 16)
                }

            }
            .padding(.horizontal, 24).padding(.bottom, 28)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button("확인했어요 · 배치 시작하기") { Task { await vm.loadRoom() } }
                .buttonStyle(VOFilledButtonStyle()).disabled(vm.isWorking)
                .padding(.horizontal, 40).padding(.top, 16).padding(.bottom, 24)
                .background(Color(.systemBackground))
        }
    }

    private var game: some View {
        VStack(spacing: 0) {
            if let room = vm.room {
                FurnitureRealityKitView(detail: room.detail, allowsLocalFallback: true,
                                        onAssetFailure: { vm.sceneError = $0; vm.sceneReady = false },
                                        onSceneReady: { vm.sceneLoaded() },
                                        editMode: !vm.hasPendingSubmission && !vm.isWorking, editSession: editSession)
                    .id(room.detail.renderingID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            VStack(spacing: 14) {
                if let message = vm.sceneError {
                    Text(message).font(.regular12).foregroundStyle(.red)
                    Button("방 다시 불러오기") { Task { await vm.loadRoom() } }.disabled(vm.isWorking)
                } else if !vm.sceneReady {
                    ProgressView("가구를 불러오는 중…").font(.regular12)
                }
                Label(vm.hasPendingSubmission
                      ? "같은 배치로 제출을 다시 시도해주세요"
                      : "가구를 탭해서 이동 · 두 손가락으로 시점 조절",
                      systemImage: "info.circle")
                    .font(.regular11).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    Button("초기화") { editSession.cancelPendingEdits() }
                        .buttonStyle(VOOutlineButtonStyle()).disabled(vm.hasPendingSubmission || vm.isWorking)
                    Button(vm.isWorking ? "제출 중…" : (vm.hasPendingSubmission ? "제출 재시도" : "배치 제출")) {
                        confirmSubmit = true
                    }
                    .buttonStyle(VOFilledButtonStyle()).disabled(vm.isWorking || !vm.sceneReady)
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 20)
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in vm.updateElapsed() }
    }

    private var placementHints: some View {
        VStack(spacing: 0) {
            HStack {
                Text("더 좋은 배치를 위한 힌트").font(.semiBold16)
                Spacer()
                Button { showPlacementHints = false } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }
                .accessibilityLabel("힌트 닫기")
            }
            .padding(.horizontal, 24).padding(.top, 20)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("배치하면서 참고해보세요. 힌트를 보는 동안에도 도전 시간은 계속 흘러요.")
                        .font(.regular12).foregroundStyle(.secondary).lineSpacing(4)
                    ForEach(ChallengePlacementHint.sections) { section in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(section.title).font(.semiBold14)
                            ForEach(section.items, id: \.self) { hint in
                                Text(hint).font(.regular12).foregroundStyle(.secondary)
                                    .lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 28)
            }
        }
        .foregroundStyle(.primary)
        .tint(Color.voBlue)
        .background(Color(.systemBackground))
    }

    private func resultFeedback(_ title: String, messages: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.semiBold14)
            ForEach(messages, id: \.self) { message in
                Text(message).font(.regular12).foregroundStyle(.secondary).lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .voGlassCard(cornerRadius: 16)
    }

    private var result: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 24) {
                if let score = vm.result {
                    VStack(spacing: 10) {
                        Text("나의 배치 점수")
                            .font(.regular13).foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(score.totalScore, specifier: "%.1f")")
                                .font(.semiBold38)
                                .foregroundStyle(Color.primary)
                            Text("/ \(score.maxScore, specifier: "%.0f")점")
                                .font(.regular14).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 32)
                    HStack {
                        resultMetric("현재 순위", score.rank.map { "\($0)위 / \(score.totalRanked)명" } ?? "순위 없음")
                        Divider().frame(height: 36)
                        resultMetric("소요 시간", "\(vm.submittedSeconds / 60)분 \(vm.submittedSeconds % 60)초")
                    }
                    .padding(18).voGlassCard(cornerRadius: 16)
                    if let breakdown = score.breakdown {
                        VStack(spacing: 0) {
                            ForEach(vm.event?.criteria ?? []) { criterion in
                                HStack {
                                    Text(criterion.title).font(.regular13)
                                    Spacer()
                                    Text("\(breakdown[criterion.key] ?? 0, specifier: "%.1f") / \(criterion.maxScore, specifier: "%.0f")점")
                                        .font(.semiBold13).monospacedDigit()
                                }
                                .padding(.vertical, 14)
                                Divider()
                            }
                        }
                        if let aiScore = score.aiScore {
                            HStack {
                                Label("AI 배치 점수", systemImage: "sparkles").font(.regular13)
                                Spacer()
                                Text("\(aiScore, specifier: "%.1f")점").font(.semiBold14)
                            }
                        }
                    }
                    if !score.strengths.isEmpty {
                        resultFeedback("잘한 부분", messages: score.strengths)
                    }
                    if !score.improvements.isEmpty {
                        resultFeedback("아쉬운 부분", messages: score.improvements)
                    }
                    Text("남은 도전 \(vm.remainingAttempts)회")
                        .font(.regular12).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 24)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) {
                if vm.remainingAttempts > 0, vm.event?.isActive == true {
                    Button("다시 도전하기") { Task { await vm.loadRoom() } }
                        .buttonStyle(VOFilledButtonStyle()).disabled(vm.isWorking)
                    Button("랭킹 보기") { Task { await vm.loadRanking() } }
                        .buttonStyle(VOOutlineButtonStyle()).disabled(vm.isWorking)
                } else {
                    Button("랭킹 보기") { Task { await vm.loadRanking() } }
                        .buttonStyle(VOFilledButtonStyle()).disabled(vm.isWorking)
                }
                Button("처음으로") { restart() }
                    .font(.semiBold14).foregroundStyle(.secondary).padding(.top, 4)
                    .disabled(vm.isWorking)
            }
            .padding(.horizontal, 40).padding(.top, 16).padding(.bottom, 24)
            .background(Color(.systemBackground))
        }
    }

    private func resultMetric(_ title: String, _ value: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.regular11).foregroundStyle(.secondary)
            Text(value).font(.semiBold14)
        }
        .frame(maxWidth: .infinity)
    }

    private var leaderboard: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("현재 랭킹").font(.semiBold20)
                    Spacer()
                    if let ranking = vm.ranking {
                        Text("\(ranking.totalRanked)명 참여")
                            .font(.regular12).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 30)
                if let event = vm.event {
                    Text(event.name).font(.regular12).foregroundStyle(.secondary).padding(.top, 8)
                }
                if let aiScore = vm.ranking?.aiScore {
                    HStack {
                        Label("AI 배치 점수", systemImage: "sparkles").font(.regular13)
                        Spacer()
                        Text("\(aiScore, specifier: "%.1f")점").font(.semiBold14).monospacedDigit()
                    }
                    .padding(18).voGlassCard(cornerRadius: 16).padding(.top, 24)
                }
                HStack(spacing: 8) {
                    Text("순위").frame(width: 40)
                    Text("닉네임").frame(maxWidth: .infinity, alignment: .leading)
                    Text("소요 시간").frame(width: 64, alignment: .trailing)
                    Text("점수").frame(width: 58, alignment: .trailing)
                }
                .font(.regular11).foregroundStyle(.secondary)
                .padding(.top, 28).padding(.bottom, 12)
                Divider()
                if vm.ranking?.entries.isEmpty == true {
                    VStack(spacing: 10) {
                        Image(systemName: "trophy").font(.system(size: 32)).foregroundStyle(Color.voBlue)
                        Text("아직 등록된 기록이 없어요").font(.semiBold14)
                        Text("첫 번째 배치에 도전해보세요").font(.regular12).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 48)
                }
                ForEach(vm.ranking?.entries ?? []) { item in
                    rankingRow(item)
                    Divider()
                }
                Text("참가자별 가장 높은 점수의 기록이 표시돼요.")
                    .font(.regular11).foregroundStyle(.secondary)
                    .padding(.top, 18).padding(.bottom, 24)
            }
            .padding(.horizontal, 24)
        }
        .refreshable { await vm.loadRanking() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button("돌아가기") { vm.closeRanking() }
                .buttonStyle(VOFilledButtonStyle()).disabled(vm.isWorking)
                .padding(.horizontal, 40).padding(.top, 16).padding(.bottom, 24)
                .background(Color(.systemBackground))
        }
    }

    private func rankingRow(_ item: ChallengeLeaderboardEntry) -> some View {
        HStack(spacing: 8) {
            Text("\(item.rank)")
                .font(.semiBold14).monospacedDigit()
                .frame(width: 32, height: 32)
                .background(item.rank <= 3 ? Color.voBlue.opacity(0.2) : .clear, in: Circle())
                .frame(width: 40)
                .accessibilityLabel("\(item.rank)위")
            Text(item.name).font(.semiBold13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
            Text(item.elapsedSeconds.map { "\($0 / 60)분 \($0 % 60)초" } ?? "—")
                .font(.regular11).foregroundStyle(.secondary).monospacedDigit()
                .frame(width: 64, alignment: .trailing)
            Text("\(item.totalScore, specifier: "%.1f")점")
                .font(.semiBold13).monospacedDigit()
                .frame(width: 58, alignment: .trailing)
        }
        .padding(.vertical, 16)
        .accessibilityElement(children: .combine)
    }
}
