import SwiftUI
import RoomPlan

struct OptimizedResultView: View {
    let room: CapturedRoom
    let versionDetail: RoomVersionDetail
    @ObservedObject var vm: ScanViewModel

    @State private var showOptimized = true
    @State private var isTransparent = false
    @State private var material = RoomMaterial.presets[0]

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
                    FurnitureRealityKitView(detail: versionDetail, capturedRoom: room, isTransparent: isTransparent,
                                            wallColor: material.wallColor, floorColor: material.floorColor,
                                            furnitureTint: material.furnitureColor)
                } else {
                    RoomViewerView(capturedRoom: room, isTransparent: isTransparent,
                                   wallColor: material.wallColor, floorColor: material.floorColor)
                }
            }
            .id("\(showOptimized)-\(isTransparent)-\(material.id)")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomTrailing) {
                RoomStyleToggle(isTransparent: $isTransparent)
                    .padding(12)
            }
            .overlay(alignment: .bottomLeading) {
                MaterialSwatchPicker(selected: $material)
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
                .padding(.vertical, 8)
        }
    }
}

// MARK: - 벽/바닥 머티리얼 프리셋

struct RoomMaterial: Identifiable, Equatable {
    let id: String
    let name: String
    let swatchColor: Color   // 피커에 보여줄 대표 색상 (바닥 기준)
    let wallColor: UIColor
    let floorColor: UIColor
    /// 카탈로그 모델/박스 폴백 가구에 입힐 색 (바닥과 톤은 맞추되 너무 동화되지 않게 살짝 다르게)
    let furnitureColor: UIColor

    static let presets: [RoomMaterial] = [
        RoomMaterial(id: "white", name: "화이트",
                     swatchColor: .white,
                     wallColor: .white,
                     floorColor: .white,
                     furnitureColor: UIColor(white: 0.90, alpha: 1.0)),
        RoomMaterial(id: "beige", name: "베이지",
                     swatchColor: Color(red: 0.83, green: 0.72, blue: 0.56),
                     wallColor: UIColor(red: 0.95, green: 0.92, blue: 0.86, alpha: 1.0),
                     floorColor: UIColor(red: 0.83, green: 0.72, blue: 0.56, alpha: 1.0),
                     furnitureColor: UIColor(red: 0.93, green: 0.87, blue: 0.76, alpha: 1.0)),
        RoomMaterial(id: "wood", name: "우드",
                     swatchColor: Color(red: 0.72, green: 0.53, blue: 0.34),
                     wallColor: .white,
                     floorColor: UIColor(red: 0.72, green: 0.53, blue: 0.34, alpha: 1.0),
                     furnitureColor: UIColor(red: 0.55, green: 0.38, blue: 0.24, alpha: 1.0)),
        RoomMaterial(id: "gray", name: "그레이",
                     swatchColor: Color(red: 0.55, green: 0.55, blue: 0.58),
                     wallColor: UIColor(red: 0.88, green: 0.88, blue: 0.89, alpha: 1.0),
                     floorColor: UIColor(red: 0.55, green: 0.55, blue: 0.58, alpha: 1.0),
                     furnitureColor: UIColor(red: 0.75, green: 0.75, blue: 0.77, alpha: 1.0)),
        RoomMaterial(id: "charcoal", name: "차콜",
                     swatchColor: Color(red: 0.27, green: 0.27, blue: 0.29),
                     wallColor: UIColor(red: 0.80, green: 0.80, blue: 0.82, alpha: 1.0),
                     floorColor: UIColor(red: 0.27, green: 0.27, blue: 0.29, alpha: 1.0),
                     furnitureColor: UIColor(red: 0.45, green: 0.45, blue: 0.47, alpha: 1.0)),
    ]
}

// MARK: - 머티리얼 스와치 피커

struct MaterialSwatchPicker: View {
    @Binding var selected: RoomMaterial

    var body: some View {
        HStack(spacing: 2) {
            ForEach(RoomMaterial.presets) { m in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { selected = m }
                } label: {
                    Circle()
                        .fill(m.swatchColor)
                        .frame(width: 26, height: 26)
                        .overlay(
                            Circle().stroke(Color.voBlue, lineWidth: selected.id == m.id ? 2.5 : 0)
                        )
                        .overlay(
                            Circle().stroke(Color(.systemGray4), lineWidth: 0.75)
                        )
                        .frame(width: 44, height: 44)   // 터치 영역은 44pt로 넉넉하게, 보이는 원은 그대로
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .voGlassCard(cornerRadius: 8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.voBlue.opacity(0.25), lineWidth: 1))
    }
}

// MARK: - 벽 스타일 토글 버튼 (기본 / 투시)

struct RoomStyleToggle: View {
    @Binding var isTransparent: Bool

    var body: some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isTransparent = false }
            } label: {
                Text("기본")
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
                Text("투시")
                    .font(.caption.weight(isTransparent ? .semibold : .regular))
                    .foregroundStyle(isTransparent ? Color.voBlue : Color.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(isTransparent ? Color.voBlue.opacity(0.13) : Color.clear)
            }
        }
        .voGlassCard(cornerRadius: 8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.voBlue.opacity(0.25), lineWidth: 1))
    }
}
