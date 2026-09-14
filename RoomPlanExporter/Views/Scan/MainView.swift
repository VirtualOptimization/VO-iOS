import SwiftUI

struct MainView: View {
    @ObservedObject var vm: ScanViewModel
    @ObservedObject var authVM: AuthViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    cards
                        .padding(.horizontal, 20)
                        .padding(.top, 24)

                    mySpaceSection
                        .padding(.top, 32)
                }
                .padding(.bottom, 48)
            }
        }
        .onAppear { vm.syncRoomsWithServer() }
        .alert("불러오기 실패", isPresented: .constant(vm.inquiryError != nil), actions: {
            Button("확인") { vm.inquiryError = nil }
        }, message: {
            Text(vm.inquiryError ?? "")
        })
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 0) {
            // 점 세 개 메뉴 → 탭하면 로그아웃이 바로 아래에 드롭다운으로 뜸
            HStack {
                Spacer()
                Menu {
                    Button("로그아웃", role: .destructive) { authVM.logout() }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
            }
            .padding(.top, 2)

            // 로고
            Image("logo_white")
                .resizable()
                .scaledToFit()
                .frame(width: 60)
                .padding(.top, 4)
                .padding(.bottom, 14)

            // 인사말
            Text("안녕하세요, \(authVM.username)님")
                .font(.semiBold18)
                .foregroundStyle(.white)
                .padding(.bottom, 4)

            Text("방을 스캔하고 최적의 배치를 확인하세요!")
                .font(.regular13)
                .foregroundStyle(.white.opacity(0.9))
                .padding(.bottom, 26)
        }
        .frame(maxWidth: .infinity)
        // 상태바까지 파란 배경 채우기
        .background(headerBackground.ignoresSafeArea(edges: .top))
    }

    @ViewBuilder
    private var headerBackground: some View {
        if #available(iOS 26.0, *) {
            Color.clear.glassEffect(.regular.tint(Color.voBlue), in: Rectangle())
        } else {
            Color.voBlue
        }
    }

    // MARK: - Cards

    private var cards: some View {
        // 가구 등록/가구 목록 기능을 걷어내고 나니 진입점이 "공간 촬영" 하나뿐이라,
        // 정사각 타일 대신 가로로 넓은 프라이머리 CTA 배너 하나로 재구성.
        Button { vm.showGuide() } label: {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.voBlue.opacity(0.12))
                        .frame(width: 52, height: 52)
                    Image(systemName: "camera.viewfinder")
                        .font(.title2)
                        .foregroundStyle(Color.voBlue)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("공간 촬영")
                        .font(.semiBold16)
                        .foregroundStyle(.primary)
                    Text("방을 스캔하고 최적의 배치를 확인하세요!")
                        .font(.regular12)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
            }
            .padding(18)
            .frame(maxWidth: .infinity)
            .voGlassCardFillingParent(cornerRadius: 16)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 내 공간

    private var mySpaceSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("내 공간")
                .font(.semiBold16)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

            Divider()
                .padding(.horizontal, 24)

            if vm.savedSpaces.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "house.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(Color.voBlue.opacity(0.3))
                    Text("아직 스캔한 공간이 없어요")
                        .font(.semiBold14)
                        .foregroundStyle(.secondary)
                    Text("공간 촬영을 눌러 시작해보세요")
                        .font(.regular12)
                        .foregroundStyle(Color(.tertiaryLabel))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
            } else {
                ForEach(vm.savedSpaces) { space in
                    SpaceRow(space: space, status: vm.roomStatus[space.roomId],
                             onTap: { vm.fetchRoom(roomId: space.roomId) })
                    Divider().padding(.horizontal, 24)
                }
            }
        }
    }
}

// MARK: - SpaceRow

private struct SpaceRow: View {
    let space: SavedSpace
    let status: MyRoomSummary?
    let onTap: () -> Void

    private var hasOptimized: Bool { status?.hasOptimized ?? false }
    private var hasEdited: Bool { (status?.userEditedCount ?? 0) > 0 }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 0) {
                Text(space.dateString)
                    .font(.regular12)
                    .foregroundStyle(.secondary)
                    .frame(width: 74, alignment: .leading)

                Text(space.name)
                    .font(.semiBold13)
                    .foregroundStyle(.primary)

                Spacer()

                Image(systemName: "house")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.voBlue)

                Image(systemName: "sparkles")
                    .font(.system(size: 12))
                    .foregroundStyle(hasOptimized ? Color.voBlue : Color(.tertiaryLabel))
                    .padding(.leading, 4)

                HStack(spacing: 3) {
                    versionDot(filled: true)               // 원본 (항상 존재)
                    versionDot(filled: hasOptimized)        // 최적화
                    versionDot(filled: hasEdited)           // 사용자 편집
                }
                .padding(.leading, 6)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }

    private func versionDot(filled: Bool) -> some View {
        Circle()
            .fill(filled ? Color.voBlue : Color(.systemGray5))
            .frame(width: 6, height: 6)
    }
}

#Preview { MainView(vm: ScanViewModel(), authVM: AuthViewModel()) }
