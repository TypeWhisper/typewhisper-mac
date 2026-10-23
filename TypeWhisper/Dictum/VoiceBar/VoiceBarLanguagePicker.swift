import AppKit
import SwiftUI

private final class VoiceBarLanguageButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct VoiceBarLanguagePicker: NSViewRepresentable {
    let target: String
    @Binding var isOpen: Bool

    func makeCoordinator() -> Coordinator { Coordinator(isOpen: $isOpen) }

    func makeNSView(context: Context) -> NSButton {
        let button = VoiceBarLanguageButton(title: "", target: context.coordinator, action: #selector(Coordinator.openMenu(_:)))
        button.isBordered = false
        button.font = .systemFont(ofSize: 12.5)
        button.contentTintColor = NSColor(red: 0.90, green: 0.84, blue: 1, alpha: 1)
        button.wantsLayer = true
        button.layer?.cornerRadius = 13
        button.layer?.backgroundColor = NSColor(red: 0.61, green: 0.36, blue: 0.93, alpha: 0.24).cgColor
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.targetLanguage = target
        button.title = "中文 → \(VoiceBarLanguages.Option(code: target).name) ⌄"
        button.setAccessibilityLabel(button.title)
    }

    @MainActor final class Coordinator: NSObject, NSMenuDelegate {
        var targetLanguage = "en"
        private var isOpen: Binding<Bool>

        init(isOpen: Binding<Bool>) { self.isOpen = isOpen }

        @objc func openMenu(_ sender: NSButton) {
            let menu = NSMenu()
            menu.appearance = NSAppearance(named: .darkAqua)
            menu.delegate = self
            for language in VoiceBarLanguages.options {
                let item = NSMenuItem(title: language.name, action: #selector(selectLanguage(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = language.code
                item.state = language.code == targetLanguage ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let edit = NSMenuItem(title: String(localized: "Edit Languages…", table: "DictumHome"), action: #selector(editLanguages), keyEquivalent: "")
            edit.target = self
            menu.addItem(edit)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + menu.size.height), in: sender)
        }

        @objc private func selectLanguage(_ sender: NSMenuItem) {
            guard let code = sender.representedObject as? String else { return }
            SettingsViewModel.shared.translationTargetLanguage = code
        }

        @objc private func editLanguages() { DictumNavigation.shared.open(.general) }
        func menuWillOpen(_ menu: NSMenu) { isOpen.wrappedValue = true }
        func menuDidClose(_ menu: NSMenu) { isOpen.wrappedValue = false }
    }
}
