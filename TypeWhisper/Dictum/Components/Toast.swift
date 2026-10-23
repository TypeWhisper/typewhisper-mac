import SwiftUI

struct Toast: View {
    let message: LocalizedStringKey
    @Binding var isPresented: Bool
    var tableName: String = "DictumShell"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if isPresented {
                Text(message, tableName: tableName).font(.system(size: 12.5)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(.black.opacity(0.92), in: Capsule())
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
            }
        }
        .animation(DictumTheme.Motion.accessible(DictumTheme.Motion.base, reduceMotion: reduceMotion), value: isPresented)
        .task(id: isPresented) {
            guard isPresented else { return }
            do { try await Task.sleep(for: .milliseconds(1400)) } catch { return }
            isPresented = false
        }
    }
}
