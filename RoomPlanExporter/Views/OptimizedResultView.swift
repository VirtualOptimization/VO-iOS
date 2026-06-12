import SwiftUI
import RoomPlan

struct OptimizedResultView: View {
    let room: CapturedRoom
    let versionDetail: RoomVersionDetail
    @ObservedObject var vm: ScanViewModel

    @State private var showOptimized = true
    @State private var isTransparent = false

    var body: some View {
        VStack(spacing: 0) {
            // ── 배너 ─────────────────────────────────────────────────────────
            HStack(spacing: 10) {
                Image("logo_white")
                    .resizable().scaledToFit().frame(height: 32)
                Text("최적화 완료 !")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12).padding(.horizontal, 20)
            .background(Color.voBlue)

            // ── 3D 뷰어 ──────────────────────────────────────────────────────
            Group {
                if showOptimized {
                    FurnitureRealityKitView(detail: versionDetail, capturedRoom: room, isTransparent: isTransparent)
                } else {
                    RoomViewerView(capturedRoom: room, isTransparent: isTransparent)
                }
            }
            .id("\(showOptimized)-\(isTransparent)")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomTrailing) {
                RoomStyleToggle(isTransparent: $isTransparent)
                    .padding(12)
            }

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
                .padding(.vertical, 12)
        }
    }
}

// MARK: - 벽 스타일 토글 버튼 (흰색 / 투명)

struct RoomStyleToggle: View {
    @Binding var isTransparent: Bool

    var body: some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isTransparent = false }
            } label: {
                Text("흰색")
                    .font(.caption.weight(isTransparent ? .regular : .semibold))
                    .foregroundStyle(isTransparent ? Color.secondary : Color.voBlue)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(isTransparent ? Color.clear : Color.voBlue.opacity(0.13))
            }

            Divider()
                .frame(height: 18)

            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isTransparent = true }
            } label: {
                Text("투명")
                    .font(.caption.weight(isTransparent ? .semibold : .regular))
                    .foregroundStyle(isTransparent ? Color.voBlue : Color.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(isTransparent ? Color.voBlue.opacity(0.13) : Color.clear)
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.voBlue.opacity(0.25), lineWidth: 1))
    }
}
