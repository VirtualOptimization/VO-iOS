import SwiftUI

// MARK: - 사진 확인 + AI 서비스 선택 + 실측 치수 입력
//
// "사진으로 AI 3D 생성" 방법에서만 쓰는 화면. 사진만으로는 실제 크기를 알 수 없어서
// 사용자가 입력한 가로/세로/높이(cm)로 생성된 모델을 리스케일해서 최종 USDZ를 만든다
// (ScanViewModel+Furniture.startFurnitureAIProcessing).

struct FurnitureAIEntryView: View {
    let image: UIImage
    @ObservedObject var vm: ScanViewModel

    @State private var widthText: String = ""
    @State private var depthText: String = ""
    @State private var heightText: String = ""
    @FocusState private var isFocused: Bool

    private var canStart: Bool {
        Double(widthText) != nil && Double(depthText) != nil && Double(heightText) != nil
    }

    var body: some View {
        VStack(spacing: 0) {
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
            .padding(.bottom, 20)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
                        .padding(.horizontal, 30)

                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("실제 치수를 입력해주세요")
                                .font(.semiBold14)
                            Text("사진만으로는 실제 크기를 알 수 없어서, 입력한 치수에 맞게 모델 크기를 조정해요")
                                .font(.regular12)
                                .foregroundStyle(.secondary)

                            HStack(spacing: 12) {
                                dimensionField("가로", text: $widthText)
                                dimensionField("세로", text: $depthText)
                                dimensionField("높이", text: $heightText)
                            }
                        }
                    }
                    .padding(.horizontal, 30)
                }
                .padding(.top, 6)
                .padding(.bottom, 40)
            }

            Button("3D 변환 시작") { start() }
                .buttonStyle(VOFilledButtonStyle())
                .disabled(!canStart)
                .opacity(canStart ? 1 : 0.5)
                .padding(.horizontal, 40)
                .padding(.bottom, 52)
        }
        .contentShape(Rectangle())
        .onTapGesture { isFocused = false }
    }

    // MARK: Dimension field

    private func dimensionField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.regular11)
                .foregroundStyle(.secondary)
            HStack(spacing: 2) {
                TextField("0", text: text)
                    .keyboardType(.decimalPad)
                    .font(.regular14)
                    .focused($isFocused)
                Text("cm")
                    .font(.regular11)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 6)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color(.systemGray5)).frame(height: 1)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Start

    private func start() {
        guard let w = Double(widthText), let d = Double(depthText), let h = Double(heightText),
              let jpeg = image.jpegData(compressionQuality: 0.85) else { return }
        isFocused = false
        vm.startFurnitureAIProcessing(imageData: jpeg, thumbnail: image,
                                       widthCm: w, depthCm: d, heightCm: h)
    }
}

#Preview {
    FurnitureAIEntryView(image: UIImage(systemName: "cabinet.fill")!, vm: ScanViewModel())
}
