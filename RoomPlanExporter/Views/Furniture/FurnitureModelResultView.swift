import SwiftUI
import RealityKit
import SceneKit
import QuickLook

struct FurnitureModelResultView: View {
    @ObservedObject var vm: ScanViewModel
    let modelURL: URL
    let thumbnail: UIImage

    @State private var name: String = ""
    @State private var showQLPreview = false
    @State private var showRegisteredAlert = false
    @FocusState private var isFocused: Bool

    private var trimmedName: String {
        let t = name.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "가구" : t
    }

    var body: some View {
        VStack(spacing: 0) {
            backButton
            nameField
                .padding(.horizontal, 24)
                .padding(.top, 4)
            Spacer()
            modelViewer
            fileInfo
            Spacer()
            actionButtons
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .contentShape(Rectangle())
        .onTapGesture { isFocused = false }
        .sheet(isPresented: $showQLPreview) {
            QuickLookPreview(url: modelURL)
        }
        .alert("등록 완료", isPresented: $showRegisteredAlert) {
            Button("확인") {
                vm.saveFurnitureWithModel(image: thumbnail, name: trimmedName, modelURL: modelURL)
            }
        } message: {
            Text("'\(trimmedName)'가 등록되었습니다.")
        }
    }

    // MARK: Back button

    private var backButton: some View {
        HStack {
            Button { vm.retakeFurniture() } label: {
                Image(systemName: "chevron.left")
                    .font(.semiBold20)
                    .foregroundStyle(Color.voBlue)
            }
            Spacer()
        }
        .padding(.horizontal, 30)
        .padding(.top, 20)
    }

    // MARK: Name field (언더라인 스타일)

    private var nameField: some View {
        HStack(spacing: 8) {
            TextField("가구 이름을 입력해주세요", text: $name)
                .focused($isFocused)
                .font(.body)
            Image(systemName: "pencil")
                .foregroundStyle(Color.voBlue)
        }
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(.systemGray5)).frame(height: 1)
        }
    }

    // MARK: 3D 모델 뷰어

    private var modelViewer: some View {
        ZStack {
            Color.clear
                .frame(height: 240)
                .voGlassCard(cornerRadius: 20)

            FurnitureModelPreviewCard(url: modelURL)
                .id(modelURL)
                .frame(height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 20))

            // QuickLook 버튼
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        showQLPreview = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(Color.black.opacity(0.4), in: Circle())
                            .frame(width: 44, height: 44)   // 보이는 원은 작게 유지, 터치 영역만 44pt로 확장
                            .contentShape(Rectangle())
                    }
                    .padding(4)
                }
            }
        }
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .padding(.horizontal, 30)
    }

    // MARK: 파일 정보 (실제로 어떤 포맷/크기로 저장됐는지 확인용)

    private var fileInfo: some View {
        let ext = modelURL.pathExtension.uppercased()
        let size = (try? FileManager.default.attributesOfItem(atPath: modelURL.path))?[.size] as? Int
        return HStack(spacing: 6) {
            Text("\(ext)\(size.map { " · " + ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "")")
                .font(.caption)
                .foregroundStyle(.secondary)
            ShareLink(item: modelURL) {
                Image(systemName: "square.and.arrow.up")
                    .font(.caption)
                    .foregroundStyle(Color.voBlue)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
        }
        .padding(.top, 6)
    }

    // MARK: Buttons

    private var actionButtons: some View {
        VStack(spacing: 14) {
            Button("등록하기") {
                isFocused = false
                showRegisteredAlert = true
            }
            .buttonStyle(VOFilledButtonStyle())

            Button("다시 업로드하기") { vm.retakeFurniture() }
                .buttonStyle(VOOutlineButtonStyle())
        }
        .padding(.horizontal, 40)
        .padding(.bottom, 50)
    }
}

// MARK: - RealityKit 3D 뷰어 (USDZ/GLB)

struct ModelViewer: UIViewRepresentable {
    let url: URL
    var onResult: ((Result<Void, Error>) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        view.environment.background = .color(.clear)

        Task {
            do {
                // RealityKit의 Entity.load는 USDZ만 네이티브 지원 — GLB 등은 로드 시 noImporter로
                // 실패하므로, USDZ가 아니면 SceneKit을 거쳐 임시 USDZ로 먼저 변환한다.
                let loadURL = try Self.usdzURL(for: url)
                let entity = try await Entity.load(contentsOf: loadURL)
                let anchor = AnchorEntity(world: .zero)

                // 바운딩 박스 기반 자동 스케일
                let bounds = entity.visualBounds(relativeTo: nil)
                let maxDim = max(bounds.extents.x, bounds.extents.y, bounds.extents.z)
                let scale: Float = maxDim > 0 ? 0.5 / maxDim : 1
                entity.scale = SIMD3(repeating: scale)
                entity.position = -bounds.center * scale

                anchor.addChild(entity)
                await MainActor.run {
                    view.scene.addAnchor(anchor)
                    context.coordinator.modelEntity = entity
                    context.coordinator.initialScale = scale
                    onResult?(.success(()))
                }

                // 자동 회전 (Y축) – 사용자가 직접 돌리기 시작하면 멈춤
                var spin = OrbitAnimation(duration: 8, axis: [0, 1, 0],
                                          startTransform: entity.transform,
                                          spinClockwise: false, orientToPath: false,
                                          rotationCount: 1, bindTarget: .transform,
                                          repeatMode: .repeat)
                spin.repeatMode = .repeat
                entity.playAnimation(try AnimationResource.generate(with: spin),
                                     transitionDuration: 0, startsPaused: false)
            } catch {
                print("❌ 3D 모델 로드 실패 (\(url.lastPathComponent)): \(error)")
                await MainActor.run { onResult?(.failure(error)) }
            }
        }

        // 카메라
        let cam = PerspectiveCamera()
        cam.camera.fieldOfViewInDegrees = 60
        cam.position = [0, 0.3, 1.2]
        cam.look(at: .zero, from: cam.position, relativeTo: nil)
        let camAnchor = AnchorEntity(world: .zero)
        camAnchor.addChild(cam)
        view.scene.addAnchor(camAnchor)

        // 조명
        let light = DirectionalLight()
        light.light.intensity = 2000
        light.light.color = .white
        light.orientation = simd_quatf(angle: -.pi / 4, axis: [1, 0, 0])
        let lightAnchor = AnchorEntity(world: .zero)
        lightAnchor.addChild(light)
        view.scene.addAnchor(lightAnchor)

        // 제스처 – 드래그로 회전, 핀치로 확대/축소
        view.addGestureRecognizer(UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan)))
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch)))

        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    // MARK: GLB 등 → USDZ 변환 (RealityKit이 직접 못 읽는 포맷 대응)

    private static func usdzURL(for source: URL) throws -> URL {
        guard source.pathExtension.lowercased() != "usdz" else { return source }

        let scene = try SCNScene(url: source, options: nil)
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).usdz")
        guard scene.write(to: dest, options: nil, delegate: nil, progressHandler: nil) else {
            throw NSError(domain: "ModelViewer", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "USDZ 변환 실패"])
        }
        return dest
    }

    // MARK: Coordinator (드래그 회전 · 핀치 확대)

    class Coordinator: NSObject {
        weak var modelEntity: Entity?
        var initialScale: Float = 1.0   // 로드 직후 자동 맞춤 배율 (핀치 배율의 기준값)
        private var gestureStartScale: Float = 1.0

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let modelEntity else { return }
            if g.state == .began { modelEntity.stopAllAnimations() }
            let delta = Float(g.translation(in: g.view).x) * 0.01
            modelEntity.orientation *= simd_quatf(angle: delta, axis: [0, 1, 0])
            g.setTranslation(.zero, in: g.view)
        }

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            guard let modelEntity else { return }
            if g.state == .began { gestureStartScale = modelEntity.scale.x }
            let newScale = max(initialScale * 0.3, min(initialScale * 3.0, gestureStartScale * Float(g.scale)))
            modelEntity.scale = SIMD3(repeating: newScale)
        }
    }
}

// MARK: - 모델 뷰어 + 로딩/에러 상태 표시

struct FurnitureModelPreviewCard: View {
    let url: URL

    @State private var isLoading = true
    @State private var loadErrorText: String? = nil

    var body: some View {
        ZStack {
            ModelViewer(url: url) { result in
                isLoading = false
                switch result {
                case .success:      loadErrorText = nil
                case .failure(let e): loadErrorText = e.localizedDescription
                }
            }

            if isLoading {
                ProgressView().progressViewStyle(.circular)
            } else if let loadErrorText {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("모델을 불러오지 못했어요")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(loadErrorText)
                        .font(.caption2)
                        .foregroundStyle(Color(.tertiaryLabel))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }
            }
        }
    }
}

// MARK: - QuickLook Preview

private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let vc = QLPreviewController()
        vc.dataSource = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController,
                               previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
