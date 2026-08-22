import SwiftUI
import RealityKit
import PhotosUI
import UniformTypeIdentifiers

// MARK: - 가구 등록 방법 선택
//
// 1) LiDAR로 실측 스캔 — 카메라로 가구 주위를 직접 돌며 스캔 (사진 불가, 반드시 라이브 촬영)
// 2) 사진으로 AI 3D 생성 — 카메라/사진보관함/탐색 중 아무 사진이나 골라서 Meshy AI/Tripo3D로 변환,
//    실측 치수는 사용자가 직접 입력해서 그 크기에 맞게 리스케일

struct FurnitureMethodPickerView: View {
    @ObservedObject var vm: ScanViewModel

    @State private var showLidarUnsupportedAlert = false
    @State private var showSourceSheet = false
    @State private var selectedSource: FurnitureImageSource = .camera
    @State private var photosPickerItem: PhotosPickerItem? = nil
    @State private var showPhotosPicker = false
    @State private var showFileImporter = false
    @State private var showCameraPicker = false
    @State private var showCameraUnavailableAlert = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                vm.phase = vm.savedFurniture.isEmpty ? .main : .furnitureList
            } label: {
                Image(systemName: "chevron.left")
                    .font(.semiBold20)
                    .foregroundStyle(Color.voBlue)
                    .padding(.horizontal, 30)
                    .padding(.top, 20)
                    .padding(.bottom, 24)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("가구를 어떻게 등록할까요?")
                    .font(.title2.bold())
                Text("두 가지 방법 중 하나를 골라주세요")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 28)

            VStack(spacing: 16) {
                methodCard(
                    icon: "arkit",
                    title: "LiDAR로 실측 스캔",
                    detail: "가구 주위를 직접 돌면서 촬영하면\n실제 크기 그대로 자동으로 측정돼요",
                    footnote: "iPhone/iPad Pro 계열 (LiDAR 탑재 기기)만 가능",
                    action: startLidarMethod
                )

                methodCard(
                    icon: "photo.on.rectangle.angled",
                    title: "사진으로 AI 3D 생성",
                    detail: "사진 한 장으로 3D 모델을 만들고\n실제 치수를 직접 입력해요",
                    footnote: "카메라 촬영 / 사진 보관함 / 파일에서 선택",
                    action: { showSourceSheet = true }
                )
            }
            .padding(.horizontal, 24)

            Spacer()
        }
        .overlay {
            if showSourceSheet {
                sourceSheet
            }
        }
        .alert("이 기기에서는 사용할 수 없어요", isPresented: $showLidarUnsupportedAlert) {
            Button("확인") {}
        } message: {
            Text("LiDAR 실측 스캔에는 LiDAR 스캐너가 필요해요. iPhone/iPad Pro 계열 기기에서 이용해주세요.\n사진으로 AI 3D 생성을 이용해주세요.")
        }
        .photosPicker(isPresented: $showPhotosPicker, selection: $photosPickerItem, matching: .images)
        .onChange(of: photosPickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    vm.chooseAIMethod(with: image)
                }
                photosPickerItem = nil
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                vm.chooseAIMethod(with: image)
            }
        }
        .fullScreenCover(isPresented: $showCameraPicker) {
            CameraPicker { image in
                vm.chooseAIMethod(with: image)
            }
            .ignoresSafeArea()
        }
        .alert("카메라를 사용할 수 없어요", isPresented: $showCameraUnavailableAlert) {
            Button("확인") {}
        } message: {
            Text("이 기기(시뮬레이터 등)에는 카메라가 없어요. 사진 보관함이나 탐색을 이용해주세요.")
        }
    }

    // MARK: - 방법 카드

    private func methodCard(icon: String, title: String, detail: String, footnote: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .foregroundStyle(Color.voBlue)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.semiBold16)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.regular12)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(footnote)
                        .font(.regular11)
                        .foregroundStyle(Color.voBlue)
                        .padding(.top, 2)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
            }
            .padding(18)
            .voGlassCard(cornerRadius: 16)
        }
        .buttonStyle(.plain)
    }

    private func startLidarMethod() {
        guard ObjectCaptureSession.isSupported else {
            showLidarUnsupportedAlert = true
            return
        }
        vm.chooseLidarMethod()
    }

    // MARK: - 이미지 소스 선택 시트 (AI 방법)

    private var sourceSheet: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { showSourceSheet = false }

            VStack(alignment: .leading, spacing: 0) {
                sourceRow(.camera, title: "사진 찍기")
                Divider().padding(.leading, 20)
                sourceRow(.photoLibrary, title: "사진 보관함")
                Divider().padding(.leading, 20)
                sourceRow(.files, title: "탐색")

                Button("이미지 선택") {
                    showSourceSheet = false
                    switch selectedSource {
                    case .camera:
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            showCameraPicker = true
                        } else {
                            showCameraUnavailableAlert = true
                        }
                    case .photoLibrary: showPhotosPicker = true
                    case .files:        showFileImporter = true
                    }
                }
                .buttonStyle(VOFilledButtonStyle())
                .padding(16)
            }
            .voGlassCard(cornerRadius: 16)
            .padding(.horizontal, 30)
        }
    }

    private func sourceRow(_ source: FurnitureImageSource, title: String) -> some View {
        Button { selectedSource = source } label: {
            HStack(spacing: 10) {
                Image(systemName: selectedSource == source ? "checkmark.square.fill" : "square")
                    .foregroundStyle(selectedSource == source ? Color.voBlue : Color(.systemGray3))
                Text(title)
                    .font(.regular14)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 이미지 소스

private enum FurnitureImageSource {
    case photoLibrary, camera, files
}

// MARK: - 시스템 카메라 (UIImagePickerController)
// 커스텀 AVCaptureSession 대신 Apple이 관리하는 피커를 사용 — 세션 생명주기 버그가 없고
// 시뮬레이터에서 카메라 미지원도 자연스럽게 처리됨.

private struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage) -> Void
        init(onCapture: @escaping (UIImage) -> Void) { self.onCapture = onCapture }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            picker.dismiss(animated: true)
            if let image = info[.originalImage] as? UIImage {
                onCapture(image)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

#Preview { FurnitureMethodPickerView(vm: ScanViewModel()) }
