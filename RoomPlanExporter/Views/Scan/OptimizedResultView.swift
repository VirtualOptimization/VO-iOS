import SwiftUI
import RoomPlan

struct OptimizedResultView: View {
    let room: CapturedRoom
    let versionDetail: RoomVersionDetail
    @ObservedObject var vm: ScanViewModel

    @State private var showOptimized = true

    var body: some View {
        VStack(spacing: 0) {
            // ── 배너 ─────────────────────────────────────────────────────────
            ZStack {
                Text("최적화 완료 !")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                HStack {
                    Image("logo_white")
                        .resizable().scaledToFit().frame(height: 42)
                    Spacer()
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 20)
            .voGlassBanner()

            // ── 3D 뷰어 ──────────────────────────────────────────────────────
            Group {
                if showOptimized {
                    // capturedRoom(원본 스캔의 좌표계)을 여기서 같이 넘기면 안 된다 — 서버 최적화
                    // 파이프라인이 방을 회전/이동시켜 새로운 좌표계로 다시 정규화하기 때문에, 벽만
                    // 원본 좌표계로 그리면 최적화된 가구 좌표(새 좌표계)와 안 맞아서 가구가 벽 밖으로
                    // 튀어나온 것처럼 보인다. 벽도 같은 최적화 JSON에서 읽어야 서로 좌표계가 맞는다.
                    FurnitureRealityKitView(detail: versionDetail, isTransparent: true)
                } else {
                    ServerOriginalPreview(roomId: vm.pendingRoomId, vm: vm)
                }
            }
            .id("\(showOptimized)-\(versionDetail.renderingID)")
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // ── 버전 전환 버튼 (가로 2개) ─────────────────────────────────────
            HStack(spacing: 12) {
                if showOptimized {
                    Button("최적화") { withAnimation(.easeInOut(duration: 0.2)) { showOptimized = true } }
                        .buttonStyle(VOFilledButtonStyle())
                    Button("내 방") { withAnimation(.easeInOut(duration: 0.2)) { showOptimized = false } }
                        .buttonStyle(VOOutlineButtonStyle())
                } else {
                    Button("최적화") { withAnimation(.easeInOut(duration: 0.2)) { showOptimized = true } }
                        .buttonStyle(VOOutlineButtonStyle())
                    Button("내 방") { withAnimation(.easeInOut(duration: 0.2)) { showOptimized = false } }
                        .buttonStyle(VOFilledButtonStyle())
                }
            }
            .padding(.horizontal, 50)
            .padding(.top, 16)

            // ── 메인으로 ─────────────────────────────────────────────────────
            Button("메인으로") { vm.retake() }
                .buttonStyle(VOOutlineButtonStyle())
                .padding(.horizontal, 50)
                .padding(.vertical, 8)
        }
    }
}

/// Original room always uses server assets, never a colored local placeholder.
struct ServerOriginalPreview: View {
    let roomId: Int?
    @ObservedObject var vm: ScanViewModel
    @State private var fetched: RoomVersionDetail?
    @State private var error: String?
    @State private var retry = 0
    @State private var assetError: String?

    var body: some View {
        Group {
            if let detail = fetched ?? vm.savedOriginalDetail {
                FurnitureRealityKitView(detail: detail, isTransparent: true, allowsLocalFallback: false,
                                        onAssetFailure: { assetError = $0 })
                    .id("\(detail.renderingID)-\(retry)")
                    .overlay(alignment: .bottom) {
                        if let assetError {
                            VStack {
                                Text(assetError).multilineTextAlignment(.center)
                                Button("다시 불러오기") { self.assetError = nil; retry += 1 }
                            }.padding().background(.regularMaterial)
                        }
                    }
            } else if let error {
                VStack(spacing: 12) {
                    Text(error).multilineTextAlignment(.center)
                    Button("다시 불러오기") { retry += 1 }
                }.padding()
            } else {
                ProgressView("서버의 원본 공간을 불러오는 중…")
            }
        }
        .task(id: retry) {
            guard vm.savedOriginalDetail == nil || retry > 0 else { return }
            error = nil
            guard let roomId, let token = KeychainTokenStore.get(.accessToken) else {
                error = "원본 공간을 조회할 정보가 없습니다. 내 공간에서 다시 열어주세요."
                return
            }
            do {
                fetched = try await RoomOptimizerService().fetchVersionDetail(
                    roomId: roomId, versionType: "origin", accessToken: token)
            } catch {
                guard !Task.isCancelled else { return }
                self.error = "서버 원본 공간을 아직 불러오지 못했어요. 잠시 후 다시 시도해주세요."
            }
        }
    }
}
