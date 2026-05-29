import SwiftUI

extension Color {
    static let voBlue = Color(red: 0.60, green: 0.75, blue: 0.90)
}

struct VOFilledButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color.voBlue.opacity(configuration.isPressed ? 0.7 : 1))
            .clipShape(Capsule())
    }
}

struct VOOutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.voBlue)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .overlay(Capsule().stroke(Color.voBlue, lineWidth: 1.5))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
