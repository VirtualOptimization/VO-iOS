import SwiftUI

// MARK: - Underline Text Field

struct UnderlineField: View {
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false

    @State private var isRevealed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Group {
                    if isSecure && !isRevealed {
                        SecureField(placeholder, text: $text)
                    } else {
                        TextField(placeholder, text: $text)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                }
                .font(.regular14)

                if isSecure {
                    Button {
                        isRevealed.toggle()
                    } label: {
                        Image(systemName: isRevealed ? "eye.slash" : "eye")
                            .font(.system(size: 15))
                            .foregroundStyle(Color(.systemGray))
                    }
                }
            }
            .padding(.vertical, 16)

            Rectangle()
                .fill(Color(.systemGray5))
                .frame(height: 1)
        }
    }
}

// MARK: - Checkbox Toggle

struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(configuration.isOn ? Color.voBlue : Color(.systemGray3))
                    .font(.system(size: 15))
                configuration.label
            }
        }
        .buttonStyle(.plain)
    }
}
