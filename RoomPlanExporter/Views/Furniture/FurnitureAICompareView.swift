import SwiftUI
import PhotosUI

// MARK: - Tripo3D vs Meshy 비교 테스트 화면
//
// 개발/테스트 전용: 사진 한 장을 골라 두 AI 서비스로 동시에 변환 요청을 보내고,
// 결과 3D 모델을 나란히 비교해볼 수 있게 한다. 저장/등록 플로우와는 무관한 독립 화면.

private enum CompareState {
    case idle
    case loading(String)
    case success(URL)
    case failure(String)
}

struct FurnitureAICompareView: View {
    @ObservedObject var vm: ScanViewModel

    @State private var pickedImage: UIImage? = nil
    @State private var photosPickerItem: PhotosPickerItem? = nil
    @State private var showPhotosPicker = false

    @State private var tripoState: CompareState = .idle
    @State private var meshyState: CompareState = .idle
    @State private var compareTask: Task<Void, Never>? = nil

    private var isRunning: Bool {
        for state in [tripoState, meshyState] {
            if case .loading = state { return true }
        }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    photoPicker
                        .padding(.top, 20)

                    if pickedImage != nil {
                        Button(isRunning ? "비교 중..." : "두 AI로 비교하기") { startCompare() }
                            .buttonStyle(VOFilledButtonStyle())
                            .disabled(isRunning)
                            .opacity(isRunning ? 0.6 : 1)
                            .padding(.horizontal, 40)
                    }

                    resultCard(title: "Tripo3D", state: tripoState)
                    resultCard(title: "Meshy", state: meshyState)
                }
                .padding(.bottom, 40)
            }
        }
        .onDisappear { compareTask?.cancel() }
        .photosPicker(isPresented: $showPhotosPicker, selection: $photosPickerItem, matching: .images)
        .onChange(of: photosPickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    pickedImage = image
                    tripoState = .idle
                    meshyState = .idle
                }
                photosPickerItem = nil
            }
        }
    }

    // MARK: Header

    private var header: some View {
        ZStack {
            Text("🧪 AI 3D 변환 비교 테스트")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            HStack {
                Button {
                    compareTask?.cancel()
                    vm.phase = .furnitureMethodPicker
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.semiBold20)
                        .foregroundStyle(.white)
                }
                Spacer()
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 24)
        .background(Color.voBlue)
    }

    // MARK: 사진 선택

    private var photoPicker: some View {
        Button { showPhotosPicker = true } label: {
            Group {
                if let pickedImage {
                    Image(uiImage: pickedImage)
                        .resizable()
                        .scaledToFit()
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 32))
                        Text("비교할 사진을 골라주세요")
                            .font(.regular13)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 160)
                }
            }
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 30)
    }

    // MARK: 결과 카드

    @ViewBuilder
    private func resultCard(title: String, state: CompareState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.semiBold14)
                .padding(.horizontal, 30)

            Group {
                switch state {
                case .idle:
                    emptyResultBox(text: "대기 중")
                case .loading(let progress):
                    emptyResultBox {
                        VStack(spacing: 10) {
                            ProgressView().progressViewStyle(.circular)
                            Text(progress)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                case .success(let url):
                    FurnitureModelPreviewCard(url: url)
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal, 30)
                case .failure(let message):
                    emptyResultBox {
                        VStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 20)
                        }
                    }
                }
            }
        }
    }

    private func emptyResultBox(text: String) -> some View {
        emptyResultBox { Text(text).font(.regular13).foregroundStyle(.secondary) }
    }

    private func emptyResultBox<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .frame(height: 220)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 30)
    }

    // MARK: 비교 실행 (둘 다 동시에)

    private func startCompare() {
        guard let pickedImage, let jpeg = pickedImage.jpegData(compressionQuality: 0.85) else { return }
        tripoState = .loading("시작 중...")
        meshyState = .loading("시작 중...")

        compareTask?.cancel()
        compareTask = Task {
            async let tripoResult: Void = runTripo(imageData: jpeg)
            async let meshyResult: Void = runMeshy(imageData: jpeg)
            _ = await (tripoResult, meshyResult)
        }
    }

    private func runTripo(imageData: Data) async {
        do {
            let url = try await TripoService().process(imageData: imageData) { progress in
                await MainActor.run { tripoState = .loading(progress) }
            }
            guard !Task.isCancelled else { return }
            tripoState = .success(url)
        } catch {
            guard !Task.isCancelled else { return }
            tripoState = .failure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func runMeshy(imageData: Data) async {
        do {
            let url = try await MeshyService().process(imageData: imageData) { progress in
                await MainActor.run { meshyState = .loading(progress) }
            }
            guard !Task.isCancelled else { return }
            meshyState = .success(url)
        } catch {
            guard !Task.isCancelled else { return }
            meshyState = .failure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}

#Preview { FurnitureAICompareView(vm: ScanViewModel()) }
