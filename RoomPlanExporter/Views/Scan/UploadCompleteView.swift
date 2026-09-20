import SwiftUI
import RoomPlan

struct UploadCompleteView: View {
    let room: CapturedRoom
    let roomId: Int
    @ObservedObject var vm: ScanViewModel

    @State private var name: String = ""
    @FocusState private var isFocused: Bool


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

            // 방 이름 — 완료 키, 내 방 보러가기, 메인으로를 누를 때 저장된다
            HStack(spacing: 8) {
                TextField("방 이름을 입력해주세요", text: $name)
                    .focused($isFocused)
                    .font(.title3.bold())
                    .onSubmit { commitName() }
                Image(systemName: "pencil")
                    .foregroundStyle(Color.voBlue)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color(.systemGray5)).frame(height: 1)
                    .padding(.horizontal, 24)
            }
            .onAppear { name = vm.savedSpaces.first { $0.roomId == roomId }?.name ?? "내 공간" }

            Divider()

            ServerOriginalPreview(roomId: roomId, vm: vm)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 하단 버튼 — 저장까지가 한 흐름, 최적화·편집·AI 상담은 내 방 조회에서
            VStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                    Text("내 방에서 최적화, 가구 편집, AI 상담을 해볼 수 있어요")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)

                Button("내 방 편집하러 가기") {
                    commitName()
                    vm.openSavedRoom(roomId: roomId)
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
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let spaceId else { return }
        vm.updateSpaceName(trimmed, id: spaceId)
        if vm.savedOriginalDetail == nil {
            vm.finalizeSave(roomId: roomId)
        }
    }
}

/// Original room always uses server assets, never a colored local placeholder.
private struct ServerOriginalPreview: View {
    let roomId: Int
    @ObservedObject var vm: ScanViewModel
    @State private var fetched: RoomVersionDetail?
    @State private var error: String?
    @State private var retry = 0

    var body: some View {
        Group {
            if let detail = fetched ?? vm.savedOriginalDetail {
                // 일부 가구 모델을 못 불러와도 OBB 박스로 대체돼서 화면은 정상 표시되므로,
                // 사용자에게 굳이 오류를 보여주지 않고 콘솔 로그로만 남긴다.
                FurnitureRealityKitView(detail: detail, isTransparent: true, allowsLocalFallback: false,
                                        onAssetFailure: { print("⚠️ 가구 모델 로드 실패: \($0)") })
                    .id("\(detail.renderingID)-\(retry)")
            } else if let error {
                VStack(spacing: 12) {
                    Text(error).multilineTextAlignment(.center)
                    Button("다시 불러오기") { retry += 1 }
                }.padding()
            } else {
                ProgressView("서버의 원본 공간을 불러오는 중…")
            }
        }
        .task(id: retry) {
            guard vm.savedOriginalDetail == nil || retry > 0 else { return }
            error = nil
            guard let token = KeychainTokenStore.get(.accessToken) else {
                error = "원본 공간을 조회할 정보가 없습니다. 내 공간에서 다시 열어주세요."
                return
            }
            do {
                fetched = try await RoomOptimizerService().fetchVersionDetail(
                    roomId: roomId, versionType: "origin", accessToken: token)
            } catch {
                guard !Task.isCancelled else { return }
                self.error = "서버 원본 공간을 아직 불러오지 못했어요. 잠시 후 다시 시도해주세요."
            }
        }
    }
}
