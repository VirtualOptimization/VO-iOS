import SwiftUI
import RoomPlan

struct UploadCompleteView: View {
    let room: CapturedRoom
    let roomId: Int
    @ObservedObject var vm: ScanViewModel

    @State private var name: String = ""
    @FocusState private var isFocused: Bool
    @State private var saved = false

    @State private var isTransparent = false
    @State private var material = RoomMaterial.presets[0]

    private var spaceId: UUID? {
        vm.savedSpaces.first { $0.roomId == roomId }?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            // 배너
            ZStack {
                Text("내 방 저장 완료 !")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                HStack {
                    Image("logo_white")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 42)
                    Spacer()
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 20)
            .voGlassBanner()

            // 방 이름 + 저장하기
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    TextField("방 이름을 입력해주세요", text: $name)
                        .focused($isFocused)
                        .font(.title3.bold())
                        .onSubmit { commitName() }
                    Image(systemName: "pencil")
                        .foregroundStyle(Color.voBlue)
                }

                Button {
                    isFocused = false
                    commitName()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: saved ? "checkmark" : "square.and.arrow.down")
                        Text(saved ? "저장됨" : "저장하기")
                    }
                    .font(.semiBold12)
                    .foregroundStyle(saved ? .green : Color.voBlue)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background((saved ? Color.green : Color.voBlue).opacity(0.12), in: Capsule())
                }
                .animation(.easeInOut(duration: 0.2), value: saved)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color(.systemGray5)).frame(height: 1)
                    .padding(.horizontal, 24)
            }
            .onAppear { name = vm.savedSpaces.first { $0.roomId == roomId }?.name ?? "내 공간" }
            .onChange(of: name) { _, _ in saved = false }

            Divider()

            // 3D 뷰어
            RoomViewerView(capturedRoom: room, isTransparent: isTransparent,
                           wallColor: material.wallColor, floorColor: material.floorColor,
                           furnitureTint: material.furnitureColor, colorCustomizable: true)
                .id("\(isTransparent)-\(material.id)")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottomTrailing) {
                    RoomStyleToggle(isTransparent: $isTransparent)
                        .padding(12)
                }
                .overlay(alignment: .bottomLeading) {
                    MaterialSwatchPicker(selected: $material)
                        .padding(12)
                }

            // 하단 버튼
            VStack(spacing: 12) {
                Button("최적화 하기") {
                    commitName()
                    vm.requestOptimization(room: room, roomId: roomId)
                }
                .buttonStyle(VOFilledButtonStyle())

                Button("메인으로") {
                    commitName()
                    vm.retake()
                }
                .buttonStyle(VOOutlineButtonStyle())
            }
            .padding(.horizontal, 50)
            .padding(.vertical, 20)
        }
        .contentShape(Rectangle())
        .onTapGesture { isFocused = false }
        .alert("최적화 실패", isPresented: .constant(vm.optimizeError != nil), actions: {
            Button("확인") { vm.optimizeError = nil }
        }, message: {
            Text(vm.optimizeError ?? "")
        })
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let spaceId else { return }
        vm.updateSpaceName(trimmed, id: spaceId)
        saved = true
    }
}
