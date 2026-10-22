import SwiftUI

struct DictumControlStyle: ButtonStyle {
    enum Kind { case popup, smallButton }
    var kind: Kind = .popup

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(DictumControlSurface(kind: kind, isPressed: configuration.isPressed))
    }
}

private struct DictumControlSurface: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    let kind: DictumControlStyle.Kind
    var isPressed = false

    func body(content: Content) -> some View {
        content
            .font(.system(size: kind == .smallButton ? 12 : 13))
            .foregroundStyle(DictumTheme.textPrimary)
            .padding(.leading, kind == .smallButton ? 9 : 10)
            .padding(.trailing, kind == .smallButton ? 9 : 6)
            .frame(height: 24)
            .background {
                RoundedRectangle(cornerRadius: kind == .smallButton ? 5 : 6)
                    .fill(DictumTheme.control)
                    .overlay {
                        RoundedRectangle(cornerRadius: kind == .smallButton ? 5 : 6)
                            .strokeBorder(DictumTheme.controlBorder, lineWidth: 0.5)
                    }
                    .shadow(color: DictumTheme.controlShadow, radius: 1.5, y: 1)
            }
            .brightness(isPressed ? -0.04 : 0)
            .opacity(isEnabled ? 1 : 0.45)
    }
}

struct DictumPopup<Selection: Hashable, Options: View>: View {
    let title: LocalizedStringKey
    @Binding var selection: Selection
    var tableName: String = "DictumShell"
    let value: Text
    @ViewBuilder let options: () -> Options

    var body: some View {
        Menu {
            Picker(selection: $selection, content: options) {
                Text(title, tableName: tableName)
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            value
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .padding(.trailing, 20)
        .overlay(alignment: .trailing) {
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(DictumTheme.textPrimary.opacity(0.55))
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        .modifier(DictumControlSurface(kind: .popup))
        .fixedSize()
        .accessibilityLabel(Text(title, tableName: tableName))
        .accessibilityValue(value)
    }
}
