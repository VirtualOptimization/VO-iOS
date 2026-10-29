import Combine
import SwiftUI

struct ChallengeRootView: View {
    var onClose: (() -> Void)? = nil
    @StateObject private var vm = ChallengeViewModel()
    @StateObject private var editSession = FurnitureEditSession()
    @State private var name = ""
    @State private var phone = ""
    @State private var consent = false
    @State private var activeSheet: ChallengeSheet?
    @State private var confirmedAction: ConfirmedAction?
    @State private var isWide = false
    @State private var furnitureLegend: [FurnitureColorLegendItem] = []
    @State private var hintSheetHeight: CGFloat = 460
    @FocusState private var focusedField: EntryField?

    private enum EntryField: Hashable { case name, phone }
    private struct HintContentHeight: PreferenceKey {
        static var defaultValue: CGFloat { 0 }
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }
    private enum ChallengeSheet: String, Identifiable {
        case hints, submission, newParticipant, exit, error
        var id: String { rawValue }
    }

    private enum ResultCardAlignment: AlignmentID {
        static func defaultValue(in dimensions: ViewDimensions) -> CGFloat { dimensions[.top] }
    }

    private static var resultCardTop: VerticalAlignment { VerticalAlignment(ResultCardAlignment.self) }

    private enum ConfirmedAction {
        case submit([FurniturePoseEdit])
        case newParticipant, leaveGame, reloadEvent
    }

    private func sheetDismissed() {
        let action = confirmedAction
        confirmedAction = nil
        switch action {
        case .submit(let edits): Task { await vm.submit(edits: edits) }
        case .newParticipant:
            guard vm.canSwitchParticipant else { return }
            Task {
                if await vm.beginNewParticipant() {
                    name = ""
                    phone = ""
                    consent = false
                }
            }
        case .leaveGame: vm.leaveGame()
        case .reloadEvent: Task { await vm.loadEvent() }
        case nil:
            if vm.errorMessage != nil { activeSheet = .error }
        }
    }

    private func confirm(_ action: ConfirmedAction) {
        focusedField = nil
        confirmedAction = action
        activeSheet = nil
    }

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
        case .layout: "내 배치 보기"
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
        case .game, .submitting: activeSheet = .exit
        case .result: restart()
        case .layout: vm.screen = .result
        case .leaderboard: vm.closeRanking()
        case .welcome, .loading: break
        }
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                banner
                switch vm.screen {
                case .welcome: welcome
                case .entry: entry
                case .criteria: criteria
                case .loading:
                    ProgressView("불러오고 있어요…")
                        .font(.regular13)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .game, .submitting: game
                case .result: result
                case .layout: layoutComparison
                case .leaderboard: leaderboard
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onChange(of: geometry.size, initial: true) { _, size in
                isWide = size.width >= 900 && size.width > size.height
            }
        }
        .font(.regular13)
        .foregroundStyle(.primary)
        .tint(Color.voBlue)
        .background(Color(.systemBackground).ignoresSafeArea())
        .interactiveDismissDisabled(isPlaying || vm.isWorking || vm.hasPendingSubmission)
        .task { await vm.loadEvent() }
        .sheet(item: $activeSheet, onDismiss: sheetDismissed) { sheet in
            Group {
                switch sheet {
                case .hints:
                    if #available(iOS 18.0, *) {
                        placementHints.presentationSizing(.fitted)
                    } else {
                        placementHints
                    }
                case .submission: submissionConfirmation
                case .newParticipant: newParticipantConfirmation
                case .exit: exitConfirmation
                case .error: errorNotice
                }
            }
            .presentationDetents(sheet == .hints ? [.height(hintSheetHeight)] : [.medium, .large])
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled(sheet == .error)
        }
        .onChange(of: vm.errorMessage) { _, message in
            if message != nil, activeSheet == nil { activeSheet = .error }
        }
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
                        Button {
                            activeSheet = .hints
                        } label: {
                            Image(systemName: "key.fill")
                                .font(.system(size: 18, weight: .medium))
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("배치 힌트 보기")
                        .disabled(vm.isWorking)
                    }
                } else if vm.screen == .leaderboard {
                    Button {
                        Task { await vm.loadRanking() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 17, weight: .medium))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("랭킹 새로고침")
                    .disabled(vm.isWorking)
                } else if let onClose {
                    Button {
                        Task {
                            if await vm.beginNewParticipant() { onClose() }
                        }
                    } label: {
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
            Group {
                if isWide {
                    HStack(spacing: 64) {
                        welcomeBrand(compact: compact)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        VStack(spacing: 20) {
                            welcomeSteps(compact: true)
                            eventStatus
                            welcomeActions
                        }
                        .frame(maxWidth: 420)
                    }
                    .padding(.horizontal, 40).padding(.vertical, 24)
                    .frame(maxWidth: 1120)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        Spacer(minLength: compact ? 12 : 24)
                        welcomeBrand(compact: compact)
                        welcomeSteps(compact: compact).padding(.top, compact ? 16 : 28)
                        Spacer(minLength: 12)
                        eventStatus
                    }
                    .padding(.horizontal, 40).padding(.bottom, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !isWide {
                welcomeActions
                    .padding(.horizontal, 40).padding(.top, 12).padding(.bottom, 24)
                    .frame(maxWidth: 600)
                    .frame(maxWidth: .infinity)
                    .background(Color(.systemBackground))
            }
        }
    }

    private func welcomeBrand(compact: Bool) -> some View {
        VStack(spacing: 0) {
            Text("보는 것을 넘어, 최적을 찾다").font(.semiBold14).foregroundStyle(.secondary)
            Image("logo").resizable().scaledToFit()
                .frame(width: compact ? 120 : 160, height: compact ? 80 : 108)
                .padding(.top, 16).accessibilityLabel("V-O")
            Text("내 손으로 바꾸는 공간").font(.semiBold20).padding(.top, compact ? 18 : 30)
            Text("움직이기 편한 공간을 만들어보세요.\n세 항목 점수에서 감점을 빼 순위를 정해요.")
                .font(.regular13).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineSpacing(5).padding(.top, 10)
        }
    }

    private func welcomeSteps(compact: Bool) -> some View {
        VStack(spacing: 0) {
            welcomeStep("01", "참가자 정보 입력", "닉네임과 연락처를 입력해주세요", compact: compact)
            Divider()
            welcomeStep("02", "가구 배치하기", "열쇠 버튼으로 배점·감점을 확인해보세요", compact: compact)
            Divider()
            welcomeStep("03", "점수와 랭킹 확인", "항목별 점수와 감점을 함께 확인해보세요", compact: compact)
        }
    }

    @ViewBuilder private var eventStatus: some View {
        if vm.isWorking {
            ProgressView().accessibilityLabel("이벤트 확인 중")
        } else if vm.event?.isActive == false {
            Text("새 도전은 종료됐어요. 기존 참가자는 다시 들어가 기록을 볼 수 있어요.")
                .font(.regular12).foregroundStyle(.secondary)
        }
    }

    private var welcomeActions: some View {
        VStack(spacing: 12) {
            if vm.hasSession {
                Button(vm.hasPendingSubmission ? "제출 재시도" : (vm.result != nil || vm.remainingAttempts == 0 ? "내 도전 결과 보기" : "내 도전 이어하기")) { Task { await vm.resume() } }
                    .buttonStyle(VOFilledButtonStyle()).disabled(vm.isWorking)
            } else {
                Button(vm.event?.isActive == false ? "내 기록으로 다시 들어가기" : "참가 등록 · 재입장") { vm.screen = .entry }
                    .buttonStyle(VOFilledButtonStyle())
                    .disabled(vm.event == nil || vm.isWorking)
                    .opacity(vm.event != nil ? 1 : 0.45)
            }
            Button("현재 랭킹 보기") { Task { await vm.loadRanking() } }
                .buttonStyle(VOOutlineButtonStyle()).disabled(vm.event == nil || vm.isWorking)
            if vm.hasSession {
                Button {
                    activeSheet = .newParticipant
                } label: {
                    Text("다른 참가자 등록").font(.semiBold14).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(!vm.canSwitchParticipant)
            }
        }
    }

    private func welcomeStep(_ number: String, _ title: String, _ detail: String, compact: Bool)
        -> some View
    {
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

    /// Center short landscape pages in the visible area; let long pages and keyboard layouts scroll.
    private func centeredScroll<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let page = content()
        return GeometryReader { geometry in
            ScrollView(showsIndicators: false) {
                page
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: isWide ? max(0, geometry.size.height) : 0, alignment: .center)
            }
        }
    }

    private var entry: some View {
        centeredScroll {
            let layout =
                isWide
                ? AnyLayout(HStackLayout(alignment: .center, spacing: 56))
                : AnyLayout(VStackLayout(alignment: .leading, spacing: 28))
            layout {
                VStack(alignment: .leading, spacing: 16) {
                    Text("참가자 정보를 입력해주세요").font(.semiBold20)
                    Text("닉네임은 랭킹에 그대로 표시돼요.\n다시 들어오셨다면 이전과 같은 닉네임·전화번호를 입력해주세요.")
                        .font(.regular12).foregroundStyle(.secondary)
                    if isWide { entryPrivacy.padding(.top, 16) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text("참가 정보").font(.semiBold14)
                        Spacer()
                        if focusedField != nil {
                            Button("입력 완료") { focusedField = nil }
                                .font(.semiBold13).frame(minWidth: 80, minHeight: 44)
                        }
                    }
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
                    Toggle(isOn: $consent) {
                        Text("개인정보 수집·이용에 동의합니다").font(.regular12)
                            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    }
                    .toggleStyle(CheckboxToggleStyle())
                    .frame(minHeight: 48).contentShape(Rectangle())
                    if !isWide { entryPrivacy }
                    if isWide { entryAction }
                }
                .frame(maxWidth: isWide ? 460 : .infinity, alignment: .leading)
            }
            .padding(.horizontal, isWide ? 40 : 32).padding(.vertical, 28)
            .frame(maxWidth: isWide ? 1080 : 600)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !isWide {
                entryAction.padding(.horizontal, 32).padding(.vertical, 16)
                    .frame(maxWidth: 600).frame(maxWidth: .infinity)
                    .background(Color(.systemBackground))
            }
        }
    }

    private var entryPrivacy: some View {
        Text(
            "수집 항목: 닉네임, 전화번호\n이용 목적: 순위 확인 및 경품 안내\n보관 기간: 전시 종료 후 30일 이내 파기\n\n닉네임은 순위표에 공개됩니다.\n동의하지 않으면 참여할 수 없습니다."
        )
        .font(.regular11).foregroundStyle(.secondary).lineSpacing(5)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var entryAction: some View {
        Button("참가 정보 확인하기") {
            focusedField = nil
            Task {
                await vm.start(name: name, phone: phone)
                if vm.hasSession {
                    name = ""
                    phone = ""
                    consent = false
                }
            }
        }
        .buttonStyle(VOFilledButtonStyle()).disabled(!validEntry || vm.isWorking)
        .opacity(validEntry && !vm.isWorking ? 1 : 0.45)
    }

    private var orderedCriteria: [ChallengeCriterion] {
        let order = ["safety", "space", "principles"]
        return (vm.event?.criteria ?? []).sorted {
            (order.firstIndex(of: $0.key) ?? order.count) < (order.firstIndex(of: $1.key) ?? order.count)
        }
    }

    private var criteria: some View {
        centeredScroll {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("가구를 옮기기 전에\n채점 기준을 확인해주세요")
                        .font(.semiBold20).lineSpacing(4)
                    Text("안전·동선 30점, 여유 공간 40점, 생활 원칙 30점.\n합계에서 추가 감점을 빼 최종 점수를 정해요.")
                        .font(.regular12).foregroundStyle(.secondary)
                }
                .padding(.top, isWide ? 0 : 28)
                let layout =
                    isWide
                    ? AnyLayout(HStackLayout(alignment: .top, spacing: 24))
                    : AnyLayout(VStackLayout(spacing: 20))
                layout {
                    VStack(spacing: 20) {
                        ForEach(orderedCriteria) { item in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(item.title).font(.semiBold16)
                                    Spacer()
                                    Text("\(item.maxScore, specifier: "%.0f")점").font(.semiBold14)
                                }
                                Text(
                                    ChallengePlacementHint.criterionDescription(
                                        key: item.key, fallback: item.description)
                                )
                                .font(.regular12).foregroundStyle(.secondary).lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                            .voGlassCard(cornerRadius: 16)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    VStack(spacing: 20) {
                        penaltyGuide
                        rankingGuide
                    }
                    .frame(maxWidth: .infinity)
                }
                Text("배치 중에도 오른쪽 위 열쇠 버튼으로 기준을 다시 볼 수 있어요.")
                    .font(.regular12).foregroundStyle(.secondary).lineSpacing(4)
            }
            .padding(.horizontal, 32).padding(.bottom, 24)
            .frame(maxWidth: 1120).frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button("확인했어요 · 배치 시작하기") { Task { await vm.loadRoom() } }
                .buttonStyle(VOFilledButtonStyle()).disabled(vm.isWorking)
                .frame(maxWidth: 440).padding(.horizontal, 32).padding(.vertical, 16)
                .frame(maxWidth: .infinity)
                .background(Color(.systemBackground))
        }
    }

    private var game: some View {
        let layout = isWide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        return layout {
            Group {
                if let room = vm.room {
                    FurnitureRealityKitView(
                        detail: room.detail, allowsLocalFallback: true,
                        onAssetFailure: {
                            vm.sceneError = $0
                            vm.sceneReady = false
                        },
                        onSceneReady: { vm.sceneLoaded() },
                        onColorLegendReady: { furnitureLegend = $0 },
                        editMode: !vm.hasPendingSubmission && !vm.isWorking, editSession: editSession
                    )
                    .id(room.detail.renderingID)
                } else {
                    Color(.secondarySystemBackground)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            .overlay(alignment: .topLeading) {
                if vm.sceneReady, !furnitureLegend.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(furnitureLegend) { item in
                            HStack(spacing: 7) {
                                Circle().fill(Color(uiColor: item.color))
                                    .frame(width: 12, height: 12)
                                    .overlay(Circle().stroke(.black.opacity(0.15), lineWidth: 0.5))
                                Text(item.title).font(.regular11)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(12).allowsHitTesting(false)
                }
            }
            centeredScroll {
                VStack(spacing: 20) {
                    if isWide {
                        Text("나만의 배치를 완성해보세요").font(.semiBold16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let message = vm.sceneError {
                        Text(message).font(.regular12).foregroundStyle(.secondary)
                        Button("방 다시 불러오기") { Task { await vm.loadRoom() } }.disabled(vm.isWorking)
                            .frame(minHeight: 48)
                    } else if !vm.sceneReady {
                        ProgressView("가구를 불러오는 중…").font(.regular12)
                    }
                    Label(
                        vm.hasPendingSubmission ? "같은 배치로 제출을 다시 시도해주세요" : "가구를 탭해서 이동 · 두 손가락으로 시점 조절",
                        systemImage: "info.circle"
                    )
                    .font(.regular12).foregroundStyle(.secondary).lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if isWide {
                        Text("가구를 선택하면 이동·회전할 수 있어요.\n오른쪽 위 열쇠에서 배점과 감점을 확인해보세요.")
                            .font(.regular12).foregroundStyle(.secondary).lineSpacing(5)
                    }
                    let controls =
                        isWide ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
                    controls {
                        Button("초기화") { editSession.cancelPendingEdits() }
                            .buttonStyle(VOOutlineButtonStyle()).disabled(
                                vm.hasPendingSubmission || vm.isWorking || !vm.sceneReady)
                        Button(vm.isWorking ? "제출 중…" : (vm.hasPendingSubmission ? "제출 재시도" : "배치 제출")) {
                            activeSheet = .submission
                        }
                        .buttonStyle(VOFilledButtonStyle()).disabled(!vm.canSubmit)
                    }
                }
                .padding(24)
            }
            .frame(width: isWide ? 300 : nil, height: isWide ? nil : 175)
            .background(Color(.systemBackground))
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            vm.updateElapsed()
        }
    }

    private func confirmationPanel<Actions: View>(
        _ title: String, message: String, @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(spacing: 0) {
            centeredScroll {
                VStack(alignment: .leading, spacing: 16) {
                    Text(title).font(.semiBold20)
                    Text(message).font(.regular13).foregroundStyle(.secondary).lineSpacing(5)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(24)
            }
            VStack(spacing: 12, content: actions).padding(.horizontal, 24).padding(.bottom, 24)
        }
        .background(Color(.systemBackground))
    }

    private var newParticipantConfirmation: some View {
        confirmationPanel(
            "다른 참가자로 시작할까요?", message: "서버에서 로그아웃하고 이 기기의 참가 정보를 지워요. 기록과 랭킹은 유지되며, 같은 닉네임·전화번호로 다시 들어와 볼 수 있어요."
        ) {
            Button("새 참가자 입력하기") { confirm(.newParticipant) }
                .buttonStyle(VOFilledButtonStyle()).disabled(!vm.canSwitchParticipant)
            Button("취소") { activeSheet = nil }.buttonStyle(VOOutlineButtonStyle())
        }
    }

    private var exitConfirmation: some View {
        confirmationPanel("도전을 그만둘까요?", message: "현재 배치는 저장되지 않아요. 기준 안내로 돌아갑니다.") {
            Button("기준 안내로 돌아가기") { confirm(.leaveGame) }
                .buttonStyle(VOFilledButtonStyle()).disabled(vm.isWorking || vm.hasPendingSubmission)
            Button("계속하기") { activeSheet = nil }.buttonStyle(VOOutlineButtonStyle())
        }
    }

    private var errorNotice: some View {
        confirmationPanel("안내", message: vm.errorMessage ?? "잠시 후 다시 시도해주세요.") {
            if vm.screen == .welcome, vm.event == nil {
                Button("다시 시도") {
                    vm.errorMessage = nil
                    confirm(.reloadEvent)
                }.buttonStyle(VOFilledButtonStyle())
            }
            Button("확인") {
                vm.errorMessage = nil
                activeSheet = nil
            }.buttonStyle(VOOutlineButtonStyle())
        }
    }

    private var submissionConfirmation: some View {
        confirmationPanel("이 배치로 제출할까요?", message: "제출 후에는 이번 도전의 배치를 수정할 수 없어요.") {
            Button("제출하기") { confirm(.submit(editSession.pendingEdits())) }
                .buttonStyle(VOFilledButtonStyle()).disabled(!vm.canSubmit)
            Button("계속 편집") { activeSheet = nil }.buttonStyle(VOOutlineButtonStyle())
        }
    }

    private var rankingGuide: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("랭킹이 정해지는 순서").font(.semiBold14)
            Text("참가자별 가장 좋은 기록으로 비교해요.")
                .font(.regular12).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text("1. 총점이 높은 순")
                Text("2. 여유 공간이 넓은 순")
                Text("3. 소요 시간이 짧은 순")
                Text("4. 먼저 제출한 순")
            }
            .font(.regular12).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .voGlassCard(cornerRadius: 16)
    }

    private var penaltyGuide: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("추가 감점은 이렇게 계산해요").font(.semiBold14)
            ForEach(vm.event?.penaltyRules ?? ChallengePlacementHint.defaultPenaltyRules, id: \.self) {
                rule in
                Text(rule).font(.regular12)
            }
            Text("최종 점수 = 항목 합계 − 감점 (최저 0점)")
                .font(.semiBold16).foregroundStyle(.primary).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .voGlassCard(cornerRadius: 16)
    }

    private var placementHints: some View {
        VStack(spacing: 0) {
            HStack {
                Text("배치 힌트").font(.semiBold16)
                Spacer()
                Button {
                    activeSheet = nil
                } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }
                .accessibilityLabel("힌트 닫기")
            }
            .padding(.horizontal, 24).padding(.top, 20)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("힌트를 보는 동안에도 시간은 계속 흘러요.")
                        .font(.regular11).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("추가 감점").font(.semiBold14)
                        ForEach(vm.event?.penaltyRules ?? ChallengePlacementHint.defaultPenaltyRules, id: \.self) {
                            rule in
                            Text(rule).font(.regular12)
                        }
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .voGlassCard(cornerRadius: 16)
                    ForEach(ChallengePlacementHint.sections) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title).font(.semiBold14)
                            ForEach(section.items, id: \.self) { hint in
                                Text(hint).font(.regular12).foregroundStyle(.secondary)
                                    .lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 12)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: HintContentHeight.self, value: geometry.size.height)
                    }
                }
            }
        }
        .onPreferenceChange(HintContentHeight.self) { height in
            hintSheetHeight = min(600, max(260, ceil(height) + 64))
        }
        .frame(idealWidth: 600, idealHeight: hintSheetHeight)
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
        centeredScroll {
            VStack(spacing: 24) {
                if let score = vm.result {
                    let layout =
                        isWide
                        ? AnyLayout(HStackLayout(alignment: Self.resultCardTop, spacing: 32))
                        : AnyLayout(VStackLayout(spacing: 24))
                    layout {
                        VStack(spacing: 20) {
                            VStack(spacing: 10) {
                                Text("나의 배치 점수")
                                    .font(.regular13).foregroundStyle(.secondary)
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text("\(score.totalScore, specifier: "%.1f")")
                                        .font(.semiBold38)
                                        .foregroundStyle(Color.voBlue)
                                    Text("/ \(score.maxScore, specifier: "%.0f")점")
                                        .font(.regular14).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.top, isWide ? 0 : 32)
                            HStack {
                                resultMetric(
                                    "현재 순위", score.rank.map { "\($0)위 / \(score.totalRanked)명" } ?? "순위 없음")
                                Divider().frame(height: 36)
                                resultMetric("소요 시간", vm.submittedSeconds.map { "\($0 / 60)분 \($0 % 60)초" } ?? "—")
                            }
                            .padding(18).voGlassCard(cornerRadius: 16)
                            .alignmentGuide(Self.resultCardTop) { dimensions in dimensions[.top] }
                            if let breakdown = score.breakdown {
                                VStack(spacing: 0) {
                                    ForEach(vm.event?.criteria ?? []) { criterion in
                                        HStack {
                                            Text(criterion.title).font(.regular13)
                                            Spacer()
                                            HStack(alignment: .firstTextBaseline, spacing: 0) {
                                                Text("\(breakdown[criterion.key] ?? 0, specifier: "%.1f")")
                                                    .foregroundStyle(Color.voBlue)
                                                Text(" / \(criterion.maxScore, specifier: "%.0f")점")
                                                    .foregroundStyle(.secondary)
                                            }
                                            .font(.semiBold13).monospacedDigit()
                                        }
                                        .padding(.vertical, 14)
                                        Divider()
                                    }
                                    if let penalty = score.placementPenalty {
                                        HStack {
                                            Text("추가 감점").font(.regular13)
                                            Spacer()
                                            Text(penalty > 0 ? "−\(String(format: "%.0f", penalty))점" : "없음")
                                                .font(.semiBold13).monospacedDigit()
                                                .foregroundStyle(penalty > 0 ? Color.pink : Color.secondary)
                                        }
                                        .padding(.vertical, 14)
                                        Text("세 항목 점수의 합계에서 추가 감점을 뺀 최종 점수예요. 최저 점수는 0점이에요.")
                                            .font(.regular12).foregroundStyle(.secondary).lineSpacing(4)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        VStack(spacing: 20) {
                            if !score.strengths.isEmpty {
                                resultFeedback("잘한 부분", messages: score.strengths)
                            }
                            if !score.improvements.isEmpty {
                                resultFeedback("아쉬운 부분", messages: score.improvements)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .alignmentGuide(Self.resultCardTop) { dimensions in dimensions[.top] }
                    }
                }
            }
            .padding(.horizontal, 32).padding(.bottom, 24)
            .frame(maxWidth: 1120).frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) {
                Button("내 배치 보기") { Task { await vm.loadMyLayout() } }
                    .buttonStyle(VOOutlineButtonStyle()).disabled(vm.isWorking)
                Button("랭킹 보기") { Task { await vm.loadRanking() } }
                    .buttonStyle(VOFilledButtonStyle()).disabled(vm.isWorking)
                Button {
                    restart()
                } label: {
                    Text("처음으로").font(.semiBold14).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(vm.isWorking)
            }
            .frame(maxWidth: 440).padding(.horizontal, 32).padding(.vertical, 16)
            .frame(maxWidth: .infinity).background(Color(.systemBackground))
        }
    }

    private var layoutComparison: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("처음 방과 내가 제출한 배치를 비교해보세요")
                    .font(.semiBold16).padding(.top, 24)
                if let layout = vm.myLayout {
                    let arrangement = isWide
                        ? AnyLayout(HStackLayout(alignment: .top, spacing: 20))
                        : AnyLayout(VStackLayout(spacing: 20))
                    arrangement {
                        ChallengeLayoutPreview(title: "시작 배치", detail: layout.start, height: isWide ? 360 : 300)
                        ChallengeLayoutPreview(title: "내가 제출한 배치", detail: layout.submitted, height: isWide ? 360 : 300)
                    }
                    Text("나의 배치 점수 \(layout.result.totalScore, specifier: "%.1f")점")
                        .font(.semiBold16).foregroundStyle(Color.voBlue)
                }
            }
            .padding(.horizontal, 32).padding(.bottom, 24)
            .frame(maxWidth: 1200).frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button("도전 결과로 돌아가기") { vm.screen = .result }
                .buttonStyle(VOFilledButtonStyle()).disabled(vm.isWorking)
                .frame(maxWidth: 440).padding(.horizontal, 32).padding(.vertical, 16)
                .frame(maxWidth: .infinity).background(Color(.systemBackground))
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
        centeredScroll {
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
                        Label("AI 배치 총점", systemImage: "sparkles").font(.regular13)
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
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: 1080).frame(maxWidth: .infinity)
        }
        .refreshable { await vm.loadRanking() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button("돌아가기") { vm.closeRanking() }
                .buttonStyle(VOFilledButtonStyle()).disabled(vm.isWorking)
                .frame(maxWidth: 440).padding(.horizontal, 32).padding(.vertical, 16)
                .frame(maxWidth: .infinity).background(Color(.systemBackground))
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

/// Same room viewer and visual treatment as the challenge; viewing never enables editing or a timer.
private struct ChallengeLayoutPreview: View {
    let title: String
    let detail: RoomVersionDetail
    let height: CGFloat
    @State private var ready = false
    @State private var error: String?
    @State private var retry = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.semiBold14)
            FurnitureRealityKitView(detail: detail, isTransparent: true,
                onAssetFailure: { error = $0 }, onSceneReady: { ready = true }, prefersInlineObjects: true)
                .id("\(detail.renderingID)-\(retry)")
                .frame(height: height)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay {
                    if let error {
                        VStack(spacing: 12) {
                            Text(error).font(.regular12).multilineTextAlignment(.center)
                            Button("다시 불러오기") { self.error = nil; ready = false; retry += 1 }
                                .buttonStyle(VOOutlineButtonStyle())
                        }
                        .padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    } else if !ready { ProgressView("방을 불러오고 있어요…").font(.regular12) }
                }
        }
        .frame(maxWidth: .infinity)
    }
}
