import SwiftUI

struct MainView: View {
    @ObservedObject var vm: ScanViewModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 20) {
                Text("보는 것을 넘어, 최적을 찾다")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Image("logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 200)
            }

            Spacer()

            VStack(spacing: 12) {
                Button("공간 촬영") { vm.showGuide() }
                    .buttonStyle(VOOutlineButtonStyle())

                Button("결과 조회") { vm.showInquiry() }
                    .buttonStyle(VOFilledButtonStyle())
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 52)
        }
    }
}

#Preview { MainView(vm: ScanViewModel()) }
