import SwiftUI

struct VOFilledButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        if #available(iOS 26.0, *) {
            configuration.label
                .font(.semiBold14)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .glassEffect(.regular.tint(Color.voBlue).interactive(), in: Capsule())
                .opacity(configuration.isPressed ? 0.85 : 1)
        } else {
            configuration.label
                .font(.semiBold14)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.voBlue.opacity(configuration.isPressed ? 0.7 : 1))
                .clipShape(Capsule())
        }
    }
}

struct VOOutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        if #available(iOS 26.0, *) {
            configuration.label
                .font(.semiBold14)
                .foregroundStyle(Color.voBlue)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .glassEffect(.regular.interactive(), in: Capsule())
                .overlay(Capsule().stroke(Color.voBlue.opacity(0.55), lineWidth: 1))
                .opacity(configuration.isPressed ? 0.85 : 1)
        } else {
            configuration.label
                .font(.semiBold14)
                .foregroundStyle(Color.voBlue)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .overlay(Capsule().stroke(Color.voBlue, lineWidth: 1.5))
                .opacity(configuration.isPressed ? 0.7 : 1)
        }
    }
}
