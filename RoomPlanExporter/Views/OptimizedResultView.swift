import SwiftUI
import RoomPlan
import simd

struct OptimizedResultView: View {
    let room: CapturedRoom
    let objects: [OptimizedObject]
    @ObservedObject var vm: ScanViewModel

    @State private var showOptimized = true

    /// 원본 방 가구를 OptimizedObject 형태로 변환 (최적화 뷰와 동일한 렌더러 사용)
    private var originalObjects: [OptimizedObject] {
        room.objects.compactMap { obj in
            OptimizedObject(
                identifier: obj.identifier,
                category:   String(describing: obj.category),
                center:     SIMD3(obj.transform.columns.3.x,
                                  obj.transform.columns.3.y,
                                  obj.transform.columns.3.z),
                rotation:   simd_quatf(obj.transform)
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 배너
            HStack(spacing: 10) {
                Image("logo_white")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 20)
                Text("최적화 완료 !")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 20)
            .background(Color.voBlue)

            // 3D 뷰어 + 통계 뱃지
            ZStack(alignment: .topTrailing) {
                Group {
                    if showOptimized {
                        RoomViewerView(capturedRoom: room, optimizedObjects: objects)
                    } else {
                        RoomViewerView(capturedRoom: room, optimizedObjects: originalObjects)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeInOut(duration: 0.3), value: showOptimized)

                // 바닥 점유율 뱃지 (UI placeholder)
                FloorStatsBadge(isOptimized: showOptimized)
                    .padding(.top, 12)
                    .padding(.trailing, 16)
            }

            // 하단 컨트롤
            VStack(spacing: 14) {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                    Text("모든 버전은 저장되어 있으니 자유롭게 확인해보세요")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    if showOptimized {
                        Button("최적화") { withAnimation { showOptimized = true } }
                            .buttonStyle(VOFilledButtonStyle())
                        Button("내 방") { withAnimation { showOptimized = false } }
                            .buttonStyle(VOOutlineButtonStyle())
                    } else {
                        Button("최적화") { withAnimation { showOptimized = true } }
                            .buttonStyle(VOOutlineButtonStyle())
                        Button("내 방") { withAnimation { showOptimized = false } }
                            .buttonStyle(VOFilledButtonStyle())
                    }
                }
                .padding(.horizontal, 40)

                Button("메인으로 돌아가기") { vm.retake() }
                    .buttonStyle(VOOutlineButtonStyle())
                    .padding(.horizontal, 40)
            }
            .padding(.vertical, 20)
        }
    }
}

// MARK: - 바닥 점유율 뱃지 (UI only)

struct FloorStatsBadge: View {
    let isOptimized: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "mappin.circle.fill")
                    .foregroundStyle(.red)
                Text("바닥 점유율 \(isOptimized ? 72 : 54)%")
                    .font(.caption.bold())
            }
            Text(isOptimized ? "최적화 대비 +18%" : "기존 내 방 대비 -18%")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
