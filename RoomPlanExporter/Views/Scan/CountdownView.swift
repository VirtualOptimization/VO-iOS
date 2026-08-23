import SwiftUI

struct CountdownView: View {
    @ObservedObject var vm: ScanViewModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 20) {
                Text("\(vm.countdownValue)")
                    .font(.system(size: 50, weight: .bold))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.easeInOut(duration: 0.3), value: vm.countdownValue)

                Text("곧 촬영이 시작됩니다\n준비해주세요!")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
            }
        }
    }
}

#Preview {
    let vm = ScanViewModel()
    vm.countdownValue = 3
    return CountdownView(vm: vm)
}
