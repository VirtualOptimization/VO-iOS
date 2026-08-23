import SwiftUI
import RealityKit

// MARK: - LiDAR 기반 가구 캡처 (ObjectCaptureSession)
//
// 가구 주위를 돌며 LiDAR 깊이 데이터와 함께 여러 장을 캡처한다.
// LiDAR(PhotogrammetrySession)는 실측 치수 측정에만 쓰고, 실제 비주얼 3D 모델은
// 촬영된 사진을 Meshy AI로 보내서 생성한다(ScanViewModel+Furniture.startLidarCapture).
// LiDAR가 있는 기기(Pro 계열)에서만 동작.

struct FurnitureLidarCaptureView: View {
    @ObservedObject var vm: ScanViewModel

    @State private var session = ObjectCaptureSession()
    @State private var imagesDirectory: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FurnitureCapture_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ObjectCaptureView(session: session)
                .ignoresSafeArea()

            VStack {
                topBar
                Spacer()
                guidanceText
                bottomControls
            }
        }
        .onAppear {
            session.start(imagesDirectory: imagesDirectory)
        }
        .onChange(of: session.state) { _, newState in
            if newState == .completed {
                finishAndProcess()
            }
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            Button {
                session.cancel()
                try? FileManager.default.removeItem(at: imagesDirectory)
                vm.retakeFurniture()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(Color.black.opacity(0.4), in: Circle())
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    // MARK: Guidance text (상태/피드백)

    private var guidanceText: some View {
        Group {
            if let text = feedbackText {
                Text(text)
                    .font(.regular12)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.5), in: Capsule())
            }
        }
        .padding(.bottom, 16)
    }

    private var feedbackText: String? {
        switch session.state {
        case .ready:
            return "가구를 화면 중앙에 맞춰주세요"
        case .detecting:
            return "가구 주위에 사각 박스를 맞춰주세요"
        case .capturing:
            if let f = session.feedback.first {
                switch f {
                case .objectTooClose:        return "가구에서 조금 떨어져 주세요"
                case .objectTooFar:          return "가구에 조금 더 가까이 가주세요"
                case .movingTooFast:         return "더 천천히 움직여주세요"
                case .environmentLowLight, .environmentTooDark: return "조명을 더 밝게 해주세요"
                case .outOfFieldOfView:      return "가구가 화면 안에 들어오게 해주세요"
                case .objectNotFlippable:    return "가구를 뒤집을 수 없는 위치예요"
                case .overCapturing:         return "충분히 촬영됐어요, 완료해도 좋아요"
                default:                     return "가구 주위를 천천히 돌며 촬영 중이에요"
                }
            }
            return "가구 주위를 천천히 돌며 촬영 중이에요 (\(session.numberOfShotsTaken)장)"
        case .finishing:
            return "촬영을 마무리하고 있어요"
        default:
            return nil
        }
    }

    // MARK: Bottom controls

    private var bottomControls: some View {
        Group {
            switch session.state {
            case .ready:
                Button("가구 인식 시작") { session.startDetecting() }
                    .buttonStyle(VOFilledButtonStyle())

            case .detecting:
                Button("촬영 시작") { session.startCapturing() }
                    .buttonStyle(VOFilledButtonStyle())

            case .capturing:
                if session.userCompletedScanPass {
                    HStack(spacing: 12) {
                        Button("뒤집어서 더 찍기") { session.beginNewScanPassAfterFlip() }
                            .buttonStyle(VOOutlineButtonStyle())
                        Button("완료") { session.finish() }
                            .buttonStyle(VOFilledButtonStyle())
                    }
                }

            case .finishing:
                ProgressView()
                    .tint(.white)

            case .failed:
                VStack(spacing: 12) {
                    Text("촬영에 실패했어요. 다시 시도해주세요")
                        .font(.regular12)
                        .foregroundStyle(.white)
                    Button("돌아가기") { vm.retakeFurniture() }
                        .buttonStyle(VOOutlineButtonStyle())
                }

            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 30)
        .padding(.bottom, 50)
    }

    // MARK: 캡처 완료 → 재구성 파이프라인으로 전달

    private func finishAndProcess() {
        let thumbnail = firstCapturedImage() ?? UIImage(systemName: "cube") ?? UIImage()
        vm.processLidarScan(imagesDirectory: imagesDirectory, thumbnail: thumbnail)
    }

    private func firstCapturedImage() -> UIImage? {
        let exts: Set<String> = ["heic", "jpg", "jpeg", "png"]
        guard let files = try? FileManager.default.contentsOfDirectory(at: imagesDirectory, includingPropertiesForKeys: nil) else {
            return nil
        }
        guard let firstURL = files
            .filter({ exts.contains($0.pathExtension.lowercased()) })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            .first else { return nil }
        return UIImage(contentsOfFile: firstURL.path)
    }
}

#Preview { FurnitureLidarCaptureView(vm: ScanViewModel()) }
