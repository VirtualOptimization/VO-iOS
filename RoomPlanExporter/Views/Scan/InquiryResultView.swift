import SwiftUI

struct InquiryResultView: View {
    let detail: ScanDetail
    @ObservedObject var vm: ScanViewModel

    // 선택 상태는 목록의 순번이 아니라 버전 자체(ScanVersion.id)로 기억한다. 순번으로 들고 있으면
    // 버전을 삭제했을 때 남은 목록이 밀려서 엉뚱한 버전이 선택되거나, 범위를 벗어나 "기준 버전 없음"이 된다.
    @State private var selectedVersionKey: String
    @State private var showDeleteAlert  = false

    init(detail: ScanDetail, focusVersionType: String? = nil, vm: ScanViewModel) {
        self.detail = detail
        self._vm = ObservedObject(wrappedValue: vm)
        _selectedVersionKey = State(initialValue: Self.defaultVersionKey(in: detail,
                                                                        focusVersionType: focusVersionType))
    }

    /// 방금 만든 버전(예: 최적화 완료 직후)이 있으면 그걸, 없으면 USER_EDITED 중 version_no가
    /// 가장 높은 것, 그것도 없으면 원본(ORIGINAL)부터 보여준다
    private static func defaultVersionKey(in detail: ScanDetail, focusVersionType: String?) -> String {
        if let focusVersionType,
           let focused = detail.versions.first(where: { $0.versionType.uppercased() == focusVersionType.uppercased() }) {
            return focused.id
        }
        let userEditedVersions = detail.versions.filter { $0.versionType.uppercased() == "USER_EDITED" }
        if let best = userEditedVersions.max(by: { ($0.versionNo ?? 0) < ($1.versionNo ?? 0) }) {
            return best.id
        }
        if let origin = detail.versions.first(where: { $0.versionType.uppercased() == "ORIGINAL" }) {
            return origin.id
        }
        return detail.versions.first?.id ?? ""
    }
    @State private var versionToDelete: ScanVersion? = nil
    private enum ScreenMode { case normal, assistant, edit }
    @State private var mode: ScreenMode = .normal
    @State private var assistantVM: AssistantViewModel?
    @State private var showVersionSheet = false
    @State private var showActionHints = false
    @StateObject private var editSession = FurnitureEditSession()
    @State private var showNamePrompt = false
    @State private var editName = ""
    @State private var pendingEdits: [FurniturePoseEdit] = []
    @State private var pendingParentVersionId: Int?
    @State private var showRoomActions = false
    @State private var showRoomNamePrompt = false
    @State private var roomNameDraft = ""
    @State private var showRoomDeleteAlert = false

    private enum ViewerState { case idle, loading, loaded(RoomVersionDetail), error }
    @State private var viewerState: ViewerState = .idle
    @State private var cachedData: [String: RoomVersionDetail] = [:]
    @State private var loadTask: Task<Void, Never>?

    private let service = RoomOptimizerService()

    // MARK: 버전 목록

    private var selectedVersion: ScanVersion? {
        detail.versions.first { $0.id == selectedVersionKey } ?? detail.versions.first
    }

    private var optimizedVersion: ScanVersion? {
        detail.versions.first { $0.versionType.uppercased() == "OPTIMIZED" }
    }

    private var isViewingOptimized: Bool {
        selectedVersion?.versionType.uppercased() == "OPTIMIZED"
    }

    private var currentRoomName: String {
        vm.savedSpaces.first { $0.roomId == detail.roomId }?.name ?? "내 공간"
    }

    /// 하단 툴바 버튼 — 세 기능이 같은 무게로 보이도록 생김새와 너비를 맞춘다
    private func toolbarButton(_ title: String, icon: String, isEnabled: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 17))
                Text(title)
                    .font(.semiBold12)
            }
            .foregroundStyle(isEnabled ? Color.voBlue : Color(.tertiaryLabel))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    /// 최적화 결과가 이미 있으면 그 버전으로 전환, 없으면 새로 요청
    private func optimize() {
        if let optimizedVersion {
            withAnimation(.easeInOut(duration: 0.2)) { selectedVersionKey = optimizedVersion.id }
        } else {
            vm.optimizeRoom(from: detail)
        }
    }

    private var isViewerLoaded: Bool {
        if case .loaded = viewerState { return true }
        return false
    }

    /// AI 배치 상담이 근거로 쓸 현재 버전의 방 데이터 JSON URL
    private var currentDataURL: String? {
        guard case .loaded(let versionDetail) = viewerState else { return nil }
        return versionDetail.effectiveDataUrl
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            if mode == .normal {
                banner
            }

            // 3D 뷰어 (메인 영역) — 채팅 모드에서도 계속 같은 뷰가 떠 있어서, 대화 중 가구를
            // 직접 드래그하거나(F02 대안) 채팅이 숨긴 가구를(F03) 그 자리에서 바로 확인할 수 있음
            ZStack {
                Color(.secondarySystemBackground)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                viewerContent
            }
            .overlay(alignment: .bottomTrailing) {
                if mode == .edit {
                    VStack(alignment: .trailing, spacing: 8) {
                        if showActionHints {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("가구를 탭해서 선택 → 오른쪽 핸들을 드래그해서 이동")
                                Text("다시 탭하면 90도 회전")
                                Text("다 옮겼으면 오른쪽 위 저장을 눌러주세요")
                            }
                            .font(.regular11)
                            .foregroundStyle(.black)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .voGlassCardWhite(cornerRadius: 14)
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.voBlue, lineWidth: 1.5))
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                        Button { withAnimation(.easeInOut(duration: 0.15)) { showActionHints.toggle() } } label: {
                            Image(systemName: "questionmark")
                                .font(.semiBold12)
                                .foregroundStyle(Color.voBlue)
                                .frame(width: 32, height: 32)
                                .voGlassCircle()
                        }
                    }
                    .padding(.trailing, 16)
                    .padding(.bottom, 12)
                }
            }
            .overlay(alignment: .topLeading) {
                if mode == .assistant {
                    Button { exitSpecialMode() } label: {
                        Image(systemName: "xmark")
                            .font(.semiBold14)
                            .foregroundStyle(.primary)
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .padding(12)
                }
            }
            .overlay(alignment: .bottom) {
                if mode == .assistant, let assistantVM {
                    AssistantPanelView(vm: assistantVM)
                }
            }

            if mode == .normal {
                Divider()

                VStack(spacing: 12) {
                    // 3D 뷰를 가리지 않도록 기능 버튼을 아래로 내려 가로로 나란히 둔다
                    HStack(spacing: 8) {
                        toolbarButton("최적화", icon: "sparkles",
                                      isEnabled: !isViewingOptimized) { optimize() }
                        toolbarButton("가구 편집", icon: "arrow.up.and.down.and.arrow.left.and.right",
                                      isEnabled: currentDataURL != nil) { mode = .edit }
                        toolbarButton("AI 상담", icon: "bubble.left.and.bubble.right.fill",
                                      isEnabled: currentDataURL != nil) { enterAssistantMode() }
                    }

                    // 버전은 늘 펼쳐두지 않고 필요할 때만 시트로 — 3D 뷰 영역을 더 넓게 씀
                    HStack(spacing: 10) {
                        Button { showVersionSheet = true } label: {
                            HStack(spacing: 6) {
                                Image(systemName: selectedVersion?.systemIcon ?? "doc")
                                Text(selectedVersion?.displayName ?? "버전 선택")
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                        }
                        .buttonStyle(VOOutlineButtonStyle())

                        Button("메인으로") { vm.retake() }
                            .buttonStyle(VOFilledButtonStyle())
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            } else if mode == .edit {
                Divider()

                HStack(spacing: 10) {
                    Button("취소") { exitSpecialMode() }
                        .buttonStyle(VOOutlineButtonStyle())
                    Button("저장") { promptEditName() }
                        .buttonStyle(VOFilledButtonStyle())
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
        }
        .onAppear { loadViewer() }
        .onChange(of: selectedVersionKey) { _, _ in
            loadViewer()
        }
        // 보고 있던 버전이 삭제되면 남은 버전 중 기본값으로 돌아가고 뷰어도 다시 그린다
        .onChange(of: detail.versions.map(\.id)) { _, ids in
            guard !ids.contains(selectedVersionKey) else { return }
            selectedVersionKey = Self.defaultVersionKey(in: detail, focusVersionType: nil)
        }
        .sheet(isPresented: $showVersionSheet) {
            versionListPanel
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                // 삭제 확인창은 시트 안에 붙여야 목록 위로 뜬다 — 바깥 화면에 붙이면
                // 시트에 가려져서 시트를 내려야만 보인다.
                .alert("'\(versionToDelete?.displayName ?? "")'를 삭제할까요?",
                       isPresented: $showDeleteAlert) {
                    Button("취소", role: .cancel) { versionToDelete = nil }
                    Button("삭제", role: .destructive) {
                        if let v = versionToDelete, let vid = v.versionId {
                            vm.deleteVersion(roomId: detail.roomId, versionId: vid, from: detail)
                        }
                        versionToDelete = nil
                    }
                } message: {
                    Text("삭제된 버전은 복구할 수 없어요.")
                }
        }
        .alert("작업 실패", isPresented: .constant(vm.inquiryError != nil), actions: {
            Button("확인") { vm.inquiryError = nil }
        }, message: {
            Text(vm.inquiryError ?? "")
        })
        .alert("최적화 실패", isPresented: .constant(vm.optimizeError != nil), actions: {
            Button("확인") { vm.optimizeError = nil }
        }, message: {
            Text(vm.optimizeError ?? "")
        })
        .alert("편집 저장 실패", isPresented: .constant(vm.editError != nil), actions: {
            Button("확인") { vm.editError = nil }
        }, message: {
            Text(vm.editError ?? "")
        })
        .alert("편집본 이름", isPresented: $showNamePrompt) {
            TextField("예: 침대 창가 배치", text: $editName)
            Button("취소", role: .cancel) {
                pendingEdits = []
                pendingParentVersionId = nil
            }
            Button("저장") { saveEdits() }
        } message: {
            Text("나중에 버전 목록에서 이 이름으로 찾을 수 있어요.")
        }
        .confirmationDialog("방 관리", isPresented: $showRoomActions, titleVisibility: .visible) {
            Button("방 이름 수정") { beginRoomRename() }
            Button("방 삭제", role: .destructive) { showRoomDeleteAlert = true }
            Button("취소", role: .cancel) {}
        }
        .alert("방 이름 수정", isPresented: $showRoomNamePrompt) {
            TextField("방 이름", text: $roomNameDraft)
            Button("취소", role: .cancel) {}
            Button("저장") { saveRoomName() }
                .disabled(roomNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("내 공간 목록과 이 화면의 제목이 함께 변경돼요.")
        }
        .overlay {
            if showRoomDeleteAlert {
                roomDeleteConfirmation
            }
        }
    }

    // MARK: 배너

    private var banner: some View {
        ZStack {
            Text(currentRoomName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)

            HStack {
                Image("logo_white")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 42)
                Spacer()

                Button { showRoomActions = true } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 20)
        .voGlassBanner()
    }

    private var roomDeleteConfirmation: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { showRoomDeleteAlert = false }

            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    Text("방을 삭제할까요?")
                        .font(.headline)
                    Text("이 방과 원본·최적화·편집본이 모두 지워지고\n복구할 수 없어요.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 22)

                Divider()

                HStack(spacing: 0) {
                    Button("취소") { showRoomDeleteAlert = false }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 54)

                    Divider().frame(height: 54)

                    Button("삭제", role: .destructive) {
                        showRoomDeleteAlert = false
                        vm.deleteRoom(roomId: detail.roomId)
                    }
                    .frame(maxWidth: .infinity, minHeight: 54)
                }
            }
            .voGlassCard(cornerRadius: 18)
            .padding(.horizontal, 36)
            .offset(y: 48)
        }
        .transition(.opacity)
        .zIndex(20)
    }

    private func beginRoomRename() {
        roomNameDraft = currentRoomName
        // confirmationDialog가 내려간 다음 이름 입력창을 띄워 두 프레젠테이션이 겹치지 않게 한다.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            showRoomNamePrompt = true
        }
    }

    private func saveRoomName() {
        let trimmed = roomNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        vm.updateSpaceName(trimmed, roomId: detail.roomId)
    }

    // MARK: 뷰어 콘텐츠

    @ViewBuilder
    private var viewerContent: some View {
        switch viewerState {
        case .idle:
            EmptyView()
        case .loading:
            VStack(spacing: 16) {
                ProgressView().progressViewStyle(.circular).scaleEffect(1.5)
                Text("3D 모델 불러오는 중...")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        case .loaded(let versionDetail):
            FurnitureRealityKitView(detail: versionDetail, isTransparent: true,
                                    editMode: mode == .edit,
                                    hiddenIdentifiers: assistantVM?.hiddenFurnitureIdentifiers ?? [],
                                    editSession: editSession)
                .id(versionDetail.renderingID)
                .ignoresSafeArea()
        case .error:
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36)).foregroundStyle(.secondary)
                Text("모델을 불러오지 못했어요")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("다시 시도") { loadViewer(force: true) }
                    .font(.subheadline).foregroundStyle(Color.voBlue)
            }
        }
    }

    // MARK: 버전 리스트 패널

    private var versionListPanel: some View {
        VStack(spacing: 0) {
            Text("버전 선택")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 20)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    ForEach(detail.versions) { version in
                        VersionRow(
                            version: version,
                            isSelected: version.id == selectedVersion?.id,
                            onSelect: {
                                withAnimation(.easeInOut(duration: 0.2)) { selectedVersionKey = version.id }
                                showVersionSheet = false
                            },
                            onDelete: {
                                versionToDelete = version
                                showDeleteAlert = true
                            }
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .background(Color(.systemBackground))
    }

    // MARK: 화면 모드 전환

    private func enterAssistantMode() {
        guard let currentDataURL else { return }
        assistantVM = AssistantViewModel(dataURLString: currentDataURL)
        withAnimation(.easeInOut(duration: 0.2)) { mode = .assistant }
    }

    /// 저장 전에 이름을 물어본다 — 편집본이 여러 개 쌓이면 이름 없이는 구분이 안 된다.
    private func promptEditName() {
        let edits = editSession.pendingEdits()
        guard !edits.isEmpty else {
            vm.editError = "옮긴 가구가 없어요. 가구를 옮긴 뒤 저장해주세요."
            return
        }
        guard let parentVersionId = selectedVersion?.versionId else {
            vm.editError = "저장할 기준 버전을 찾지 못했어요. 버전을 다시 선택해주세요."
            return
        }
        pendingEdits = edits
        // 이름 입력 중 목록이 갱신되더라도, 편집을 시작해 화면에서 확인한 버전을 부모로 저장한다.
        pendingParentVersionId = parentVersionId
        editName = ""
        showNamePrompt = true
    }

    /// 옮긴 가구를 새 "사용자 편집" 버전으로 저장한다. 서버가 Unity 좌표계 파일도 함께 만들어서
    /// VR에서도 같은 배치가 열린다.
    private func saveEdits() {
        guard let parentVersionId = pendingParentVersionId else {
            vm.editError = "저장할 기준 버전을 찾지 못했어요."
            return
        }
        let trimmed = editName.trimmingCharacters(in: .whitespaces)
        vm.saveEditedVersion(roomId: detail.roomId,
                             parentVersionId: parentVersionId,
                             name: trimmed.isEmpty ? "내 편집" : trimmed,
                             edits: pendingEdits,
                             from: detail)
    }

    /// 채팅/가구 편집 모드 둘 다 이 버튼 하나로 나간다.
    private func exitSpecialMode() {
        assistantVM?.showAllFurniture()
        withAnimation(.easeInOut(duration: 0.2)) { mode = .normal }
        assistantVM = nil
        showActionHints = false
    }

    // MARK: 버전 상세 다운로드 & 캐시

    private func loadViewer(force: Bool = false) {
        guard let version = selectedVersion else {
            loadTask?.cancel()
            viewerState = .idle
            return
        }
        let cacheKey = version.id

        if !force, let cached = cachedData[cacheKey] {
            loadTask?.cancel()
            viewerState = .loaded(cached)
            return
        }

        loadTask?.cancel()
        viewerState = .loading

        let snapshot = version  // 선택 시점 캡처
        loadTask = Task {
            guard let accessToken = KeychainTokenStore.get(.accessToken) else {
                viewerState = .error
                return
            }
            do {
                let versionDetail: RoomVersionDetail
                let versionType = snapshot.versionType.uppercased()
                if let vid = snapshot.versionId {
                    versionDetail = try await service.fetchVersionDetailById(
                        roomId: detail.roomId,
                        versionId: vid,
                        accessToken: accessToken
                    )
                } else if versionType == "ORIGINAL" || versionType == "ORIGIN" {
                    versionDetail = try await service.fetchVersionDetail(
                        roomId: detail.roomId,
                        versionType: "origin",
                        accessToken: accessToken
                    )
                } else {
                    versionDetail = try await service.fetchVersionDetail(
                        roomId: detail.roomId,
                        versionType: snapshot.versionType.lowercased(),
                        accessToken: accessToken
                    )
                }
                guard !Task.isCancelled else { return }
                cachedData[cacheKey] = versionDetail
                viewerState = .loaded(versionDetail)
            } catch {
                guard !Task.isCancelled else { return }
                print("❌ 버전 상세 로드 실패: \(error)")
                viewerState = .error
            }
        }
    }
}

// MARK: - VersionRow

private struct VersionRow: View {
    let version: ScanVersion
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    // 원본·최적화는 지울 수 없고, 사용자 편집본과 VR 수정본만 삭제 가능
    private var canDelete: Bool {
        version.canBeDeleted && version.versionId != nil
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            // 라디오 인디케이터
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 20))
                .foregroundStyle(isSelected ? Color.voBlue : Color(.tertiaryLabel))

            // 카테고리 아이콘
            Image(systemName: version.systemIcon)
                .font(.subheadline)
                .foregroundStyle(isSelected ? Color.voBlue : .secondary)
                .frame(width: 20)

            // 종류 + 출처 뱃지 / 아래줄에 편집본 이름과 날짜
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(version.displayName)
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    if let source = version.editSource {
                        Text(source == .vr ? "VR" : "앱")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.voBlue)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.voBlue.opacity(0.12), in: Capsule())
                    }
                }

                if let date = version.createdAt {
                    Text(shortDate(date))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // 삭제 버튼 (원본 제외, 플레이스홀더 제외)
            if canDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.subheadline)
                        .foregroundStyle(.red.opacity(0.75))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .frame(minHeight: 72)
        .background(
            isSelected ? Color.voBlue.opacity(0.08) : Color(.secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }

    private func shortDate(_ iso: String) -> String {
        let formatters: [ISO8601DateFormatter] = [
            { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }(),
            { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }(),
            { let f = ISO8601DateFormatter(); return f }()
        ]
        let df = DateFormatter()
        df.locale = Locale(identifier: "ko_KR")
        df.dateFormat = "MM.dd HH:mm"
        for f in formatters {
            if let d = f.date(from: iso) { return df.string(from: d) }
        }
        // 타임존 없는 형식 폴백 ("2024-01-15T10:30:00.123456")
        let plain = DateFormatter()
        plain.locale = Locale(identifier: "ko_KR")
        plain.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        if let d = plain.date(from: iso) { return df.string(from: d) }
        plain.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        if let d = plain.date(from: iso) { return df.string(from: d) }
        return ""
    }
}
