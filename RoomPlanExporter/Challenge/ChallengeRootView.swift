import SwiftUI
import Combine

struct ChallengeRootView: View {
    @StateObject private var vm = ChallengeViewModel()
    @StateObject private var editSession = FurnitureEditSession()
    @State private var name = ""
    @State private var phone = ""
    @State private var consent = false
    @State private var confirmSubmit = false
    @State private var confirmExit = false
    @State private var confirmNewParticipant = false
    @FocusState private var focusedField: EntryField?

    private enum EntryField: Hashable { case name, phone }

    private var validEntry: Bool {
        (1...12).contains(name.trimmingCharacters(in: .whitespacesAndNewlines).count)
        && phone.filter { $0 >= "0" && $0 <= "9" }.hasPrefix("0")
        && (10...11).contains(phone.filter { $0 >= "0" && $0 <= "9" }.count)
        && phone.allSatisfy { ($0 >= "0" && $0 <= "9") || $0 == "-" || $0.isWhitespace }
        && consent
    }

    private func restart() {
        vm.restart()
        name = ""
        phone = ""
        consent = false
    }

    var body: some View {
        VStack(spacing: 0) {
            switch vm.screen {
            case .welcome: welcome
            case .entry: entry
            case .criteria: criteria
            case .loading: ProgressView("방을 준비하고 있어요…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .game, .submitting: game
            case .result: result
            case .leaderboard: leaderboard
            }
        }
        .foregroundStyle(ChallengePalette.ink)
        .background(ChallengePalette.background.ignoresSafeArea())
        .preferredColorScheme(.light)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("완료") { focusedField = nil }
            }
        }
        .task { await vm.loadEvent() }
        .alert("알림", isPresented: Binding(get: { vm.errorMessage != nil },
                                          set: { if !$0 { vm.errorMessage = nil } })) {
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

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("V-O").font(.system(size: 22, weight: .black, design: .rounded))
                Spacer()
                Text("CHALLENGE")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(ChallengePalette.blue)
                    .padding(.horizontal, 13).padding(.vertical, 8)
                    .background(ChallengePalette.blue.opacity(0.1), in: Capsule())
            }
            .padding(.top, 12)

            Spacer(minLength: 30)

            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: "square.3.layers.3d.top.filled")
                    .font(.system(size: 44))
                    .foregroundStyle(.white)
                    .frame(width: 84, height: 84)
                    .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 24))
                Text("내 방을 더 좋게,\n직접 배치해 볼까요?")
                    .font(.system(size: 32, weight: .bold))
                    .lineSpacing(4)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Text("가구를 옮기고 점수를 확인해 보세요.\n나만의 배치로 순위에 도전할 수 있어요.")
                    .font(.system(size: 17))
                    .lineSpacing(4)
                    .foregroundStyle(.white.opacity(0.93))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(28)
            .background(
                LinearGradient(colors: [ChallengePalette.blue, ChallengePalette.deepBlue],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 28)
            )

            HStack(spacing: 8) {
                welcomeStep("01", "정보 입력")
                welcomeStep("02", "가구 배치")
                welcomeStep("03", "점수 확인")
            }
            .padding(.top, 18)

            Spacer(minLength: 24)

            if let event = vm.event {
                Text(event.isActive ? event.name : "지금은 참여할 수 없어요")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(event.isActive ? ChallengePalette.muted : .red)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 12)
            } else {
                ProgressView("이벤트 확인 중…")
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 12)
            }
            if vm.hasSession {
                Button("내 도전 이어하기") { Task { await vm.resume() } }
                    .buttonStyle(ChallengePrimaryButtonStyle())
                    .disabled(vm.isWorking)
                Button("다른 참가자 등록") { confirmNewParticipant = true }
                    .buttonStyle(ChallengeSecondaryButtonStyle())
                    .disabled(vm.hasPendingSubmission || vm.isWorking)
            } else {
            Button("방 편집 시작하기") { vm.screen = .entry }
                .buttonStyle(ChallengePrimaryButtonStyle())
                .disabled(vm.event?.isActive != true)
                .opacity(vm.event?.isActive == true ? 1 : 0.5)
            }
            Button("이벤트 새로고침") { Task { await vm.loadEvent() } }
                .disabled(vm.isWorking)
            Button("현재 랭킹 보기") { Task { await vm.loadRanking() } }
                .buttonStyle(ChallengeSecondaryButtonStyle())
                .disabled(vm.event == nil || vm.isWorking)
                .padding(.top, 10)
        }
        .padding(24)
    }

    private func welcomeStep(_ number: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(number).font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(ChallengePalette.blue)
            Text(title).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ChallengePalette.ink)
                .lineLimit(1).minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(.white, in: RoundedRectangle(cornerRadius: 16))
    }

    private var entry: some View {
        VStack(alignment: .leading, spacing: 22) {
            Button("〈 돌아가기") { vm.screen = .welcome }
                .font(.body.weight(.semibold))
            Text("참가자 정보").font(.largeTitle.bold())
            Text("닉네임은 순위표에 그대로 표시돼요.").font(.body).foregroundStyle(.secondary)
            TextField("닉네임 (순위표에 그대로 표시돼요)", text: $name)
                .textInputAutocapitalization(.never)
                .submitLabel(.next).focused($focusedField, equals: .name)
                .onSubmit { focusedField = .phone }
                .padding(16).background(.white, in: RoundedRectangle(cornerRadius: 14))
            TextField("휴대전화 번호", text: $phone)
                .keyboardType(.phonePad).textContentType(.telephoneNumber)
                .focused($focusedField, equals: .phone)
                .padding(16).background(.white, in: RoundedRectangle(cornerRadius: 14))
            Toggle("개인정보 수집·이용에 동의합니다.", isOn: $consent).font(.body)
            Text("수집 항목: 닉네임, 전화번호\n이용 목적: 순위 확인 및 경품 안내\n보관 기간: 전시 종료 후 30일 이내 파기\n닉네임은 순위표에 공개됩니다. 동의하지 않으면 참여할 수 없습니다.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("기준 확인하기") { focusedField = nil; Task {
                    await vm.start(name: name, phone: phone)
                    if vm.hasSession { name = ""; phone = ""; consent = false }
                } }
                .buttonStyle(ChallengePrimaryButtonStyle()).disabled(!validEntry || vm.isWorking)
                .opacity(validEntry && !vm.isWorking ? 1 : 0.5)
        }
        .padding(24)
    }

    private var criteria: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("채점 기준").font(.largeTitle.bold())
                Text("가구를 옮기기 전에 기준을 확인해 주세요.")
                    .font(.body).foregroundStyle(.secondary)
                if let event = vm.event {
                    ForEach(event.criteria) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(item.title).font(.title3.bold())
                                Spacer()
                                Text("\(item.maxScore, specifier: "%.0f")점")
                                    .font(.headline).foregroundStyle(Color.voBlue)
                            }
                            Text(item.description).font(.body)
                        }
                        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16))
                    }
                    Text("실격 기준").font(.title3.bold())
                    ForEach(event.disqualifyRules, id: \.self) { rule in
                        Label(rule, systemImage: "exclamationmark.triangle")
                            .font(.body).foregroundStyle(.red)
                    }
                }
                Button("확인했어요 · 편집 시작") { Task { await vm.loadRoom() } }
                    .buttonStyle(ChallengePrimaryButtonStyle()).disabled(vm.isWorking)
                    .padding(.top, 12)
            }
            .padding(20)
        }
    }

    private var game: some View {
        VStack(spacing: 0) {
            HStack {
                Button { confirmExit = true } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                    .disabled(vm.hasPendingSubmission || vm.isWorking)
                Spacer()
                Text("배치하기").font(.title3.bold())
                Spacer()
                Text("\(vm.seconds / 60):\(String(format: "%02d", vm.seconds % 60))")
                    .monospacedDigit().font(.title3.bold()).frame(minWidth: 70)
            }
            .padding(.horizontal, 16)
            if let room = vm.room {
                FurnitureRealityKitView(detail: room.detail, allowsLocalFallback: true,
                                        onAssetFailure: { message in vm.sceneError = message; vm.sceneReady = false },
                                        onSceneReady: { vm.sceneLoaded() },
                                        editMode: !vm.hasPendingSubmission && !vm.isWorking, editSession: editSession)
                    .id(room.detail.renderingID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let message = vm.sceneError {
                Text(message).font(.footnote).foregroundStyle(.red)
                Button("방 다시 불러오기") { Task { await vm.loadRoom() } }.disabled(vm.isWorking)
            } else if !vm.sceneReady { ProgressView("가구를 불러오는 중…").padding(8) }
            Text(vm.hasPendingSubmission
                 ? "이전 제출의 응답을 확인 중이에요. 같은 배치로 다시 제출해 주세요."
                 : "가구를 탭해서 이동 · 두 손가락으로 시점 조절")
                .font(.subheadline).multilineTextAlignment(.center).padding(.vertical, 10)
            HStack(spacing: 12) {
                Button("초기화") { editSession.cancelPendingEdits() }
                    .buttonStyle(ChallengeSecondaryButtonStyle()).disabled(vm.hasPendingSubmission || vm.isWorking)
                Button(vm.isWorking ? "제출 중…" : (vm.hasPendingSubmission ? "제출 재시도" : "배치 제출")) {
                    confirmSubmit = true
                }
                    .buttonStyle(ChallengePrimaryButtonStyle()).disabled(vm.isWorking || !vm.sceneReady)
            }
            .padding(.horizontal, 20).padding(.bottom, 16)
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            vm.updateElapsed()
        }
    }

    private var result: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("도전 결과").font(.title.bold())
                if let score = vm.result {
                    Text("\(score.totalScore, specifier: "%.1f") / \(score.maxScore, specifier: "%.0f")점")
                        .font(.system(size: 48, weight: .bold))
                        .foregroundStyle(score.disqualified ? .red : Color.voBlue)
                        .minimumScaleFactor(0.7).lineLimit(1)
                    if score.disqualified {
                        Text("실격 · 다시 확인해 주세요")
                            .font(.title3.bold()).foregroundStyle(.red)
                    } else {
                        ForEach(vm.event?.criteria ?? []) { criterion in
                            HStack {
                                Text(criterion.title)
                                Spacer()
                                Text("\(score.breakdown?[criterion.key] ?? 0, specifier: "%.1f") / \(criterion.maxScore, specifier: "%.0f")")
                            }
                            .font(.body).padding(15)
                            .background(.white, in: RoundedRectangle(cornerRadius: 12))
                        }
                        if score.beatAI {
                            Label("AI보다 넓은 공간을 만들었어요!", systemImage: "sparkles")
                                .font(.headline).foregroundStyle(Color.voBlue)
                                .padding(14).background(Color.voBlue.opacity(0.12), in: Capsule())
                        }
                        if let aiScore = score.aiScore {
                            Text("AI 점수 \(aiScore, specifier: "%.1f")점")
                                .font(.title3.weight(.semibold))
                        }
                    }
                    Text(score.disqualified ? "실격 사유" : "개선 힌트")
                        .font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(score.hints, id: \.self) { hint in
                        Text(hint).font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14).background(.white, in: RoundedRectangle(cornerRadius: 12))
                    }
                    if let rank = score.rank {
                        Text("현재 순위 \(rank)위 / \(score.totalRanked)명").font(.title3.bold())
                    } else {
                        Text("순위 없음").font(.title3.bold())
                    }
                    Text("걸린 시간 \(vm.submittedSeconds / 60)분 \(vm.submittedSeconds % 60)초")
                }
                Text("남은 도전 \(vm.remainingAttempts)회").foregroundStyle(.secondary)
                if vm.remainingAttempts > 0, vm.event?.isActive == true {
                    Button("다시 도전하기") { Task { await vm.loadRoom() } }
                        .buttonStyle(ChallengePrimaryButtonStyle()).disabled(vm.isWorking)
                }
                Button("랭킹 보기") { Task { await vm.loadRanking() } }.buttonStyle(ChallengePrimaryButtonStyle())
                Button("처음으로") { restart() }.buttonStyle(ChallengeSecondaryButtonStyle())
            }
            .padding(20)
        }
    }

    private var leaderboard: some View {
        VStack(spacing: 16) {
            Text("V-O Challenge 랭킹").font(.title.bold())
            if let ranking = vm.ranking {
                Text(ranking.aiScore.map {
                    "참가자 \(ranking.totalRanked)명 · AI \($0.formatted(.number.precision(.fractionLength(1))))점"
                } ?? "참가자 \(ranking.totalRanked)명")
                    .font(.body).foregroundStyle(.secondary)
            }
            ScrollView {
                if vm.ranking?.entries.isEmpty == true {
                    Text("아직 등록된 기록이 없어요.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                }
                ForEach(vm.ranking?.entries ?? []) { item in
                    HStack(spacing: 14) {
                        Text("\(item.rank)위").font(.title3.bold()).frame(width: 52)
                        Text(item.name).font(.body)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text("\(item.totalScore, specifier: "%.1f")점").font(.headline)
                            if let seconds = item.elapsedSeconds {
                                Text("\(seconds / 60)분 \(seconds % 60)초")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(16)
                    .background(item.rank <= 3 ? Color.voBlue.opacity(0.15) : .white,
                                in: RoundedRectangle(cornerRadius: 14))
                }
            }
            Button("새로고침") { Task { await vm.loadRanking() } }
                .buttonStyle(ChallengeSecondaryButtonStyle())
            Button("돌아가기") { vm.closeRanking() }.buttonStyle(ChallengePrimaryButtonStyle())
        }
        .padding(20)
    }
}

private enum ChallengePalette {
    static let background = Color(red: 0.966, green: 0.967, blue: 0.974)
    static let ink = Color(red: 0.11, green: 0.16, blue: 0.25)
    static let muted = Color(red: 0.39, green: 0.44, blue: 0.52)
    static let blue = Color(red: 0.20, green: 0.39, blue: 0.72)
    static let deepBlue = Color(red: 0.10, green: 0.24, blue: 0.51)
}

private struct ChallengePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(ChallengePalette.blue, in: RoundedRectangle(cornerRadius: 18))
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

private struct ChallengeSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(ChallengePalette.blue)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(.white, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(ChallengePalette.blue.opacity(0.35)))
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}
