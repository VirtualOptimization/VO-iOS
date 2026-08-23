import SwiftUI

struct InquiryResultView: View {
    let detail: ScanDetail
    @ObservedObject var vm: ScanViewModel

    @State private var selectedIndex: Int
    @State private var showDeleteAlert  = false

    init(detail: ScanDetail, vm: ScanViewModel) {
        self.detail = detail
        self._vm = ObservedObject(wrappedValue: vm)

        // USER_EDITED 중 version_no가 가장 높은 것 우선 선택
        let userEditedVersions = detail.versions.filter { $0.versionType.uppercased() == "USER_EDITED" }
        if let best = userEditedVersions.max(by: { ($0.versionNo ?? 0) < ($1.versionNo ?? 0) }),
           let idx = detail.versions.firstIndex(where: { $0.versionId == best.versionId }) {
            _selectedIndex = State(initialValue: idx)
        } else if let idx = detail.versions.firstIndex(where: { $0.versionType.uppercased() == "OPTIMIZED" }) {
            _selectedIndex = State(initialValue: idx)
        } else {
            _selectedIndex = State(initialValue: 0)
        }
    }
    @State private var versionToDelete: ScanVersion? = nil
    @State private var isTransparent: Bool = false
    @State private var material = RoomMaterial.presets[0]

    private enum ViewerState { case idle, loading, loaded(RoomVersionDetail), error }
    @State private var viewerState: ViewerState = .idle
    @State private var cachedData: [String: RoomVersionDetail] = [:]
    @State private var loadTask: Task<Void, Never>?

    private let service = RoomOptimizerService()

    // MARK: 버전 목록 (실제 버전 + VR 플레이스홀더)

    private var displayVersions: [DisplayVersion] {
        let real = detail.versions.map { DisplayVersion(version: $0, isPlaceholder: false) }
        let hasUserEdited = detail.versions.contains { $0.versionType.uppercased() == "USER_EDITED" }
        if hasUserEdited { return real }
        let placeholder = ScanVersion(placeholderType: "USER_EDITED")
        return real + [DisplayVersion(version: placeholder, isPlaceholder: true)]
    }

    private var selectedDisplay: DisplayVersion? {
        guard selectedIndex < displayVersions.count else { return nil }
        return displayVersions[selectedIndex]
    }

    private var isViewerLoaded: Bool {
        if case .loaded = viewerState { return true }
        return false
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            banner

            // 3D 뷰어 (메인 영역)
            ZStack {
                Color(.secondarySystemBackground)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                viewerContent
            }
            .overlay(alignment: .bottomTrailing) {
                RoomStyleToggle(isTransparent: $isTransparent)
                    .padding(12)
            }
            .overlay(alignment: .bottomLeading) {
                MaterialSwatchPicker(selected: $material)
                    .padding(12)
            }

            Divider()

            // 버전 리스트 패널
            versionListPanel

            Divider()

            // 메인으로 돌아가기
            Button("메인으로") { vm.retake() }
                .buttonStyle(VOFilledButtonStyle())
                .padding(.horizontal, 50)
                .padding(.vertical, 10)
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
            isTransparent = false
            loadViewer()
        }
        .alert("삭제 실패", isPresented: .constant(vm.inquiryError != nil), actions: {
            Button("확인") { vm.inquiryError = nil }
        }, message: {
            Text(vm.inquiryError ?? "")
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
            FurnitureRealityKitView(detail: versionDetail, isTransparent: isTransparent,
                                    wallColor: material.wallColor, floorColor: material.floorColor,
                                    furnitureTint: material.furnitureColor)
                .id("\(versionDetail.effectiveDataUrl ?? versionDetail.usdzUrl ?? "\(selectedIndex)")-\(isTransparent)-\(material.id)")
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
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                Spacer().frame(height: 6)
                ForEach(Array(displayVersions.enumerated()), id: \.offset) { index, dv in
                    VersionRow(
                        version: dv.version,
                        isSelected: index == selectedIndex && !dv.isPlaceholder,
                        isPlaceholder: dv.isPlaceholder,
                        onSelect: {
                            withAnimation(.easeInOut(duration: 0.2)) { selectedIndex = index }
                        },
                        onDelete: {
                            versionToDelete = dv.version
                            showDeleteAlert = true
                        }
                    )
                    if index < displayVersions.count - 1 {
                        Divider().padding(.leading, 54)
                    }
                }
            }
        }
        .frame(maxHeight: 140)
        .background(Color(.systemBackground))
    }

    // MARK: 버전 상세 다운로드 & 캐시

    private func loadViewer(force: Bool = false) {
        guard let dv = selectedDisplay, !dv.isPlaceholder else {
            loadTask?.cancel()
            viewerState = .idle
            return
        }
        let cacheKey = dv.version.versionId.map { String($0) } ?? dv.version.versionType

        if !force, let cached = cachedData[cacheKey] {
            loadTask?.cancel()
            viewerState = .loaded(cached)
            return
        }

        loadTask?.cancel()
        viewerState = .loading

        let snapshot = dv  // 선택 시점 캡처
        loadTask = Task {
            guard let accessToken = KeychainTokenStore.get(.accessToken) else {
                viewerState = .error
                return
            }
            do {
                let versionDetail: RoomVersionDetail
                let versionType = snapshot.version.versionType.uppercased()
                if let vid = snapshot.version.versionId {
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
                        versionType: snapshot.version.versionType.lowercased(),
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

// MARK: - DisplayVersion

private struct DisplayVersion {
    let version: ScanVersion
    let isPlaceholder: Bool
}

// MARK: - VersionRow

private struct VersionRow: View {
    let version: ScanVersion
    let isSelected: Bool
    let isPlaceholder: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    // 삭제는 VR 수정본(vr_modified)만 가능
    private var canDelete: Bool {
        !isPlaceholder && version.canBeDeleted && version.versionId != nil
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
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(version.displayName)
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(
                            isPlaceholder ? .tertiary :
                            isSelected    ? .primary  : .secondary
                        )

                    if isPlaceholder {
                        Text("준비 중")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.4), in: Capsule())
                            .padding(.leading, 6)
                    }
                }

                if let date = version.createdAt {
                    Text(shortDate(date))
                        .font(.caption2)
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
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(isSelected ? Color.voBlue.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { if !isPlaceholder { onSelect() } }
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
