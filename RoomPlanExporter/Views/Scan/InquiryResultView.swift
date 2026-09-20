import SwiftUI

struct InquiryResultView: View {
    let detail: ScanDetail
    @ObservedObject var vm: ScanViewModel

    @State private var selectedIndex: Int
    @State private var showDeleteAlert  = false

    init(detail: ScanDetail, focusVersionType: String? = nil, vm: ScanViewModel) {
        self.detail = detail
        self._vm = ObservedObject(wrappedValue: vm)

        // 방금 만든 버전(예: 최적화 완료 직후)이 있으면 그걸, 없으면 USER_EDITED 중 version_no가
        // 가장 높은 것, 그것도 없으면 원본(ORIGINAL)부터 보여준다
        let userEditedVersions = detail.versions.filter { $0.versionType.uppercased() == "USER_EDITED" }
        if let focusVersionType,
           let idx = detail.versions.firstIndex(where: { $0.versionType.uppercased() == focusVersionType.uppercased() }) {
            _selectedIndex = State(initialValue: idx)
        } else if let best = userEditedVersions.max(by: { ($0.versionNo ?? 0) < ($1.versionNo ?? 0) }),
           let idx = detail.versions.firstIndex(where: { $0.versionId == best.versionId }) {
            _selectedIndex = State(initialValue: idx)
        } else if let idx = detail.versions.firstIndex(where: { $0.versionType.uppercased() == "ORIGINAL" }) {
            _selectedIndex = State(initialValue: idx)
        } else {
            _selectedIndex = State(initialValue: 0)
        }
    }
    @State private var versionToDelete: ScanVersion? = nil
    private enum ScreenMode { case normal, assistant, edit }
    @State private var mode: ScreenMode = .normal
    @State private var assistantVM: AssistantViewModel?
    @State private var showVersionSheet = false
    @State private var showActionHints = false
    @StateObject private var editSession = FurnitureEditSession()

    private enum ViewerState { case idle, loading, loaded(RoomVersionDetail), error }
    @State private var viewerState: ViewerState = .idle
    @State private var cachedData: [String: RoomVersionDetail] = [:]
    @State private var loadTask: Task<Void, Never>?

    private let service = RoomOptimizerService()

    // MARK: 버전 목록

    private var selectedVersion: ScanVersion? {
        guard selectedIndex < detail.versions.count else { return nil }
        return detail.versions[selectedIndex]
    }

    private var optimizedIndex: Int? {
        detail.versions.firstIndex { $0.versionType.uppercased() == "OPTIMIZED" }
    }

    private var isViewingOptimized: Bool {
        selectedVersion?.versionType.uppercased() == "OPTIMIZED"
    }

    /// 화면 위에 겹쳐 뜨는 동작 버튼 — 세 버튼이 같은 무게로 보이도록 생김새를 맞춘다
    private func actionChip(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.semiBold12)
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }

    /// 최적화 결과가 이미 있으면 그 버전으로 전환, 없으면 새로 요청
    private func optimize() {
        if let optimizedIndex {
            withAnimation(.easeInOut(duration: 0.2)) { selectedIndex = optimizedIndex }
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
                if mode != .normal {
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
            .overlay(alignment: .topTrailing) {
                if mode == .normal {
                    VStack(alignment: .trailing, spacing: 8) {
                        if !isViewingOptimized {
                            actionChip("최적화하기", icon: "sparkles") { optimize() }
                        }
                        if currentDataURL != nil {
                            actionChip("AI 배치 상담", icon: "bubble.left.and.bubble.right.fill") { enterAssistantMode() }
                            actionChip("가구 편집", icon: "arrow.up.and.down.and.arrow.left.and.right") { mode = .edit }
                        }
                    }
                    .padding(12)
                } else if mode == .edit {
                    actionChip("저장", icon: "square.and.arrow.down") { saveEdits() }
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
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
        }
        .overlay {
            if showDeleteAlert {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                        .onTapGesture { showDeleteAlert = false }
                    VStack(spacing: 0) {
                        VStack(spacing: 6) {
                            Text("'\(versionToDelete?.displayName ?? "")'가 삭제됩니다.")
                                .font(.headline)
                                .multilineTextAlignment(.center)
                            Text("삭제된 버전은 복구할 수 없어요.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 20)

                        Divider()

                        HStack(spacing: 0) {
                            Button {
                                showDeleteAlert = false
                            } label: {
                                Text("취소")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .foregroundStyle(.secondary)
                            }
                            Divider().frame(height: 50)
                            Button {
                                showDeleteAlert = false
                                if let v = versionToDelete, let vid = v.versionId {
                                    vm.deleteVersion(roomId: detail.roomId, versionId: vid, from: detail)
                                }
                            } label: {
                                Text("삭제")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                    .voGlassCard(cornerRadius: 14)
                    .padding(.horizontal, 44)
                }
            }
        }
        .onAppear { loadViewer() }
        .onChange(of: selectedIndex) { _, _ in
            loadViewer()
        }
        .sheet(isPresented: $showVersionSheet) {
            versionListPanel
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .alert("삭제 실패", isPresented: .constant(vm.inquiryError != nil), actions: {
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
    }

    // MARK: 배너

    private var banner: some View {
        ZStack {
            Text(vm.savedSpaces.first { $0.roomId == detail.roomId }?.name ?? "내 공간")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)

            HStack {
                Image("logo_white")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 42)
                Spacer()
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 20)
        .voGlassBanner()
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
                    ForEach(Array(detail.versions.enumerated()), id: \.offset) { index, version in
                        VersionRow(
                            version: version,
                            isSelected: index == selectedIndex,
                            onSelect: {
                                withAnimation(.easeInOut(duration: 0.2)) { selectedIndex = index }
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

    /// 옮긴 가구를 새 "사용자 편집" 버전으로 저장한다. 서버가 Unity 좌표계 파일도 함께 만들어서
    /// VR에서도 같은 배치가 열린다.
    private func saveEdits() {
        guard let parentVersionId = selectedVersion?.versionId else {
            vm.editError = "저장할 기준 버전을 찾지 못했어요."
            return
        }
        vm.saveEditedVersion(roomId: detail.roomId,
                             parentVersionId: parentVersionId,
                             edits: editSession.pendingEdits(),
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
        let cacheKey = version.versionId.map { String($0) } ?? version.versionType

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

            // 이름 + 날짜
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(version.displayName)
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? .primary : .secondary)
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
