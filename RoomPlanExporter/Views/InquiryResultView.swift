import SwiftUI

struct InquiryResultView: View {
    let detail: ScanDetail
    @ObservedObject var vm: ScanViewModel

    @State private var selectedIndex: Int = 0
    @State private var showDeleteAlert  = false
    @State private var versionToDelete: ScanVersion? = nil

    private enum ViewerState { case idle, loading, loaded(RoomVersionDetail), error }
    @State private var viewerState: ViewerState = .idle
    @State private var cachedData: [String: RoomVersionDetail] = [:]

    private let service = RoomOptimizerService()

    // MARK: 버전 목록 (실제 버전 + VR 플레이스홀더)

    private var displayVersions: [DisplayVersion] {
        let real = detail.versions.map { DisplayVersion(version: $0, isPlaceholder: false) }
        let hasVR = detail.versions.contains { $0.versionType == "vr_modified" }
        if hasVR { return real }
        let placeholder = ScanVersion(placeholderType: "vr_modified")
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
            ZStack(alignment: .topTrailing) {
                Color(.secondarySystemBackground)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                viewerContent

                // 바닥 점유율 뱃지
                if let dv = selectedDisplay, !dv.isPlaceholder, isViewerLoaded {
                    FloorStatsBadge(isOptimized: dv.version.versionType == "optimized")
                        .padding(.top, 12)
                        .padding(.trailing, 16)
                }
            }

            Divider()

            // 버전 리스트 패널
            versionListPanel

            Divider()

            // 메인으로 돌아가기
            Button("메인으로 돌아가기") { vm.retake() }
                .buttonStyle(VOFilledButtonStyle())
                .padding(.horizontal, 40)
                .padding(.vertical, 16)
        }
        .confirmationDialog(
            "이 버전을 삭제하시겠어요?",
            isPresented: $showDeleteAlert,
            titleVisibility: .visible
        ) {
            Button("삭제", role: .destructive) {
                if let v = versionToDelete, let vid = v.versionId {
                    vm.deleteVersion(confirmCode: detail.confirmCode, versionId: vid, from: detail)
                }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("삭제된 버전은 복구할 수 없어요")
        }
        .onAppear { loadViewer() }
        .onChange(of: selectedIndex) { _, _ in loadViewer() }
    }

    // MARK: 배너

    private var banner: some View {
        HStack(spacing: 10) {
            Image("logo_white")
                .resizable()
                .scaledToFit()
                .frame(height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text("공간 조회 결과")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                Text(detail.confirmCode)
                    .font(.caption.bold())
                    .tracking(2)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, 20)
        .background(Color.voBlue)
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
            FurnitureRealityKitView(detail: versionDetail).ignoresSafeArea()
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
        .frame(maxHeight: 260)
        .background(Color(.systemBackground))
    }

    // MARK: 버전 상세 다운로드 & 캐시

    private func loadViewer(force: Bool = false) {
        guard let dv = selectedDisplay, !dv.isPlaceholder else {
            viewerState = .idle
            return
        }
        let cacheKey = dv.version.versionType   // "origin" | "optimized"

        if !force, let cached = cachedData[cacheKey] {
            viewerState = .loaded(cached)
            return
        }

        viewerState = .loading

        Task {
            do {
                let versionDetail = try await service.fetchVersionDetail(
                    confirmCode: detail.confirmCode,
                    versionType: dv.version.versionType
                )
                cachedData[cacheKey] = versionDetail
                viewerState = .loaded(versionDetail)
            } catch {
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
        !isPlaceholder && version.versionType == "vr_modified" && version.versionId != nil
    }

    var body: some View {
        HStack(spacing: 14) {
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
                        .padding(8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(isSelected ? Color.voBlue.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { if !isPlaceholder { onSelect() } }
    }

    private func shortDate(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        guard let d = f.date(from: iso) else { return "" }
        let df = DateFormatter()
        df.locale = Locale(identifier: "ko_KR")
        df.dateFormat = "MM.dd HH:mm"
        return df.string(from: d)
    }
}
