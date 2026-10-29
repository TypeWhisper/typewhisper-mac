import AppKit
import SwiftUI

struct WhatsNewView: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: "waveform")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 60, height: 60)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text("New in TypeWhisper")
                        .font(.system(size: 26, weight: .bold))
                        .accessibilityAddTraits(.isHeader)
                    Text("A few improvements for your everyday dictation.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 22) {
                highlight(
                    "text.book.closed",
                    title: String(localized: "Give your vocabulary a boost"),
                    detail: String(localized: "Add a term in Dictionary to enable Vocabulary Boosting for Parakeet. Term packs now use precise matching to keep everyday words intact.")
                )
                highlight(
                    "calendar.badge.clock",
                    title: String(localized: "More control over meeting recordings"),
                    detail: String(localized: "Using automatic recording with Premium? Calendars can now ask before recording events without other attendees.")
                )
                highlight(
                    "square.and.arrow.down",
                    title: String(localized: "Bring settings back without duplicates"),
                    detail: String(localized: "Importing a backup skips unchanged items. Choose Replace existing items when you want to update matching workflows, profiles and prompt actions.")
                )
            }

            Divider()

            HStack {
                Spacer()
                Button("Continue", action: onDismiss)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(28)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func highlight(_ symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 21))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 26)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A standalone, nonmodal window: dismissing it never advances into another
/// startup sheet or reopens setup. It does not activate the app or steal focus.
/// While TypeWhisper is active it floats above Settings and the other app
/// windows; other apps can still cover it once the user switches away.
@MainActor
final class WhatsNewWindowController: NSWindowController, NSWindowDelegate {
    private let coordinator: WhatsNewCoordinator
    nonisolated(unsafe) private var activationObservers: [NSObjectProtocol] = []

    init(coordinator: WhatsNewCoordinator) {
        self.coordinator = coordinator
        let window = WhatsNewWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "New in TypeWhisper")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        // Keep native focus, keyboard closing and rounded corners while making
        // the content the entire visible window, without titlebar controls.
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.identifier = NSUserInterfaceItemIdentifier("whats-new")
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        super.init(window: window)
        window.delegate = self
        let contentView = NSHostingView(rootView: WhatsNewView { [weak self] in
            self?.close()
        })
        contentView.safeAreaRegions = []
        window.contentView = contentView
        // Full-size content fills the frame; setContentSize would still add the
        // hidden titlebar's height below the fixed-height SwiftUI view.
        window.setFrame(NSRect(origin: .zero, size: contentView.fittingSize), display: false)
        window.center()
        coordinator.dismissPresentation = { [weak self] in self?.close() }

        updateLevel(appIsActive: NSApp.isActive)
        for (name, isActive) in [
            (NSApplication.didBecomeActiveNotification, true),
            (NSApplication.didResignActiveNotification, false)
        ] {
            activationObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateLevel(appIsActive: isActive) }
            })
        }
    }

    deinit {
        activationObservers.forEach(NotificationCenter.default.removeObserver)
    }

    func updateLevel(appIsActive: Bool) {
        window?.level = appIsActive ? .floating : .normal
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        coordinator.acknowledgePresentation()
    }
}

/// Escape closes the overview like Continue; there is no separate Skip button.
private final class WhatsNewWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}
