import SwiftUI
import RoomPlan

struct UploadCompleteView: View {
    let room: CapturedRoom
    let roomId: Int
    @ObservedObject var vm: ScanViewModel

    @State private var name: String = ""
    @FocusState private var isFocused: Bool
    @State private var saved = false


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
                    .foregroundStyle(Color.voBlue)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.voBlue.opacity(0.12), in: Capsule())
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

            // 3D 뷰어 — 저장 확정 전엔 로컬 렌더러, 확정되면 서버 색상이 반영된 렌더러로 전환
            ServerOriginalPreview(roomId: roomId, vm: vm)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

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
        // onTapGesture는 버튼과 같은 제스처 우선순위를 다퉈서 탭 반응이 늦어지므로
        // simultaneousGesture로 버튼 탭을 막지 않게 처리
        .simultaneousGesture(TapGesture().onEnded { isFocused = false })
        // 업로드 직후 화면이 뜨자마자 원본 버전을 확정해서 서버 색상이 반영된 뷰어로 바로 전환
        // (이름 저장 버튼을 따로 눌러야만 색이 뜨는 건 사용자 입장에서 헷갈림)
        .onAppear {
            if vm.savedOriginalDetail == nil {
                vm.finalizeSave(roomId: roomId)
            }
        }
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
        if vm.savedOriginalDetail == nil {
            vm.finalizeSave(roomId: roomId)
        }
    }
}
