import SwiftUI

struct MainView: View {
    @ObservedObject var vm: ScanViewModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 8) {
                Text("보는 것을 넘어, 최적을 찾다")
                    .font(.semiBold14)
                    .foregroundStyle(.gray)

                Image("logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 250)
                    .padding(.top, -60)
            }


            VStack(spacing: 18) {
                Button("공간 촬영") { vm.showGuide() }
                    .buttonStyle(VOOutlineButtonStyle())

                Button("결과 조회") { vm.showInquiry() }
                    .buttonStyle(VOFilledButtonStyle())
            }
            .padding(.horizontal, 50)
            
            Spacer()
        }
    }
}

#Preview { MainView(vm: ScanViewModel()) }
