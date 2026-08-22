import SwiftUI

struct FurnitureProcessingView: View {
    let thumbnail: UIImage
    @ObservedObject var vm: ScanViewModel

    @State private var showCancelConfirm = false

    var body: some View {
        ZStack {
            Color.clear   // ZStack이 LoadingView의 좁은 콘텐츠 폭이 아니라 화면 전체로 확장되게 함
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            LoadingView(
                // Meshy AI/Tripo3D의 실시간 진행 상태(업로드/변환%/다운로드)를 그대로 노출 — 멈춘 것처럼 보이지 않게
                statusText: vm.furnitureProgressText.isEmpty ? "가구 생성 중.." : vm.furnitureProgressText,
                tips: [
                    "가구를 인식하고 있어요",
                    "촬영하신 사진으로\n3D 모델을 만들고 있어요",
                    "화질에 따라 몇 분 정도\n걸릴 수 있어요",
                    "화면을 끄지 마세요"
                ]
            )
            // ZStack 기본 정렬(center)로 LoadingView는 화면 중앙에 유지하고,
            // 취소 버튼만 이 프레임으로 좌상단에 고정 — 형제뷰 전체에 topLeading을 걸면 LoadingView까지 왼쪽으로 밀림
            Button("취소") { showCancelConfirm = true }
                .font(.semiBold14)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .confirmationDialog("3D 생성을 취소할까요?", isPresented: $showCancelConfirm, titleVisibility: .visible) {
            Button("취소하기", role: .destructive) { vm.cancelFurnitureGeneration() }
            Button("계속 진행", role: .cancel) {}
        }
    }
}
