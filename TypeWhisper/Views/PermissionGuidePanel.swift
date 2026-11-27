import AppKit
import SwiftUI

/// The list in System Settings > Privacy & Security that a permission guide points to.
enum PermissionGuideKind: Equatable {
    /// Accessibility, called Device Control and Data Access from macOS 27.
    case accessibility
    /// Input Monitoring.
    case inputMonitoring

    var listName: String {
        switch self {
        case .accessibility:
            AccessibilityPermissionPane.localizedName()
        case .inputMonitoring:
            localizedAppText("Input Monitoring", de: "Eingabeüberwachung", ja: "入力監視", zh: "输入监控", es: "Monitorización de entrada")
        }
    }
}

/// Shows a small panel beside System Settings while the user grants a permission there.
///
/// macOS lets no installer or app grant Accessibility or Input Monitoring itself; the user has
/// to turn on the switch. The panel names the list and the switch, offers the app icon to drag
/// into the list when TypeWhisper is missing from it, and appears only while System Settings
/// is in front. When the grant is visible to the running app, the panel closes on its own and
/// TypeWhisper comes back to the front.
@MainActor
final class PermissionGuideController {
    static let shared = PermissionGuideController()

    /// Posted after a guided permission was granted and TypeWhisper was brought back.
    static let didGrantAccess = Notification.Name("PermissionGuideDidGrantAccess")

    private var panel: PermissionGuidePanel?
    private var model: PermissionGuideModel?
    private var watchTask: Task<Void, Never>?
    private var lastPlacedOrigin: NSPoint?
    private var userMovedPanel = false

    /// Whether a guide is waiting for a permission.
    var isActive: Bool { watchTask != nil }

    /// Starts guiding after System Settings was asked to open the list for `kind`.
    ///
    /// - Parameter isGranted: Checked twice a second. Pass `nil` when the running app cannot
    ///   see the grant, as in the App Store edition, where CoreGraphics keeps its first answer
    ///   until a restart; the panel then offers to restart TypeWhisper instead.
    func begin(kind: PermissionGuideKind, isGranted: (@MainActor () -> Bool)?) {
        end()

        let model = PermissionGuideModel(
            kind: kind,
            appName: Self.appName,
            detectsGrant: isGranted != nil
        )
        model.onClose = { [weak self] in self?.end() }
        model.onRestart = {
            PermissionGuideController.shared.end()
            ApplicationRelauncher.relaunch()
        }
        self.model = model
        watchTask = Task { [weak self] in
            await self?.watch(isGranted: isGranted)
        }
    }

    /// Closes the panel and stops waiting.
    func end() {
        watchTask?.cancel()
        watchTask = nil
        panel?.orderOut(nil)
        panel = nil
        model = nil
        lastPlacedOrigin = nil
        userMovedPanel = false
    }

    private func watch(isGranted: (@MainActor () -> Bool)?) async {
        let start = ContinuousClock.now
        var settingsWasRunning = false
        var frontWithoutWindowTicks = 0

        while !Task.isCancelled {
            if let isGranted, isGranted() {
                await finishAfterGrant()
                return
            }

            let elapsed = ContinuousClock.now - start
            let settings = SystemSettingsWindowLocator.runningApplication
            settingsWasRunning = settingsWasRunning || settings != nil
            // System Settings quit, never opened, or the user left it open and walked away.
            let settingsGone = settings == nil && (settingsWasRunning || elapsed > .seconds(10))
            if settingsGone || elapsed > .seconds(20 * 60) {
                end()
                return
            }

            if let settings, SystemSettingsWindowLocator.isFrontmost {
                let settingsFrame = SystemSettingsWindowLocator.frontWindowFrame(
                    processIdentifier: settings.processIdentifier
                )
                // Waits briefly for the window so the panel does not jump once it appears.
                frontWithoutWindowTicks = settingsFrame == nil ? frontWithoutWindowTicks + 1 : 0
                if settingsFrame != nil || frontWithoutWindowTicks > 4 {
                    showPanel(besideSettingsFrame: settingsFrame)
                }
            } else {
                panel?.orderOut(nil)
            }

            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func finishAfterGrant() async {
        let wasVisible = panel?.isVisible == true
        let userIsInSettings = SystemSettingsWindowLocator.isFrontmost
        model?.isGranted = true
        if wasVisible {
            // Long enough to read the confirmation before the panel goes away.
            try? await Task.sleep(for: .milliseconds(1200))
        }
        end()

        // Only pulls TypeWhisper forward when the user is still in System Settings.
        if userIsInSettings || SystemSettingsWindowLocator.isFrontmost {
            _ = NSRunningApplication.current.activate()
            NSApp.activate(ignoringOtherApps: true)
        }
        NotificationCenter.default.post(name: Self.didGrantAccess, object: nil)
    }

    private func showPanel(besideSettingsFrame settingsFrame: NSRect?) {
        guard let model else { return }
        let panel = self.panel ?? makePanel(model: model)

        if panel.isVisible, let lastPlacedOrigin, panel.frame.origin != lastPlacedOrigin {
            userMovedPanel = true
        }
        if !userMovedPanel {
            let screen = Self.screen(for: settingsFrame)
            let origin = PermissionGuidePlacement.origin(
                panelSize: panel.frame.size,
                settingsFrame: settingsFrame,
                visibleFrame: screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            )
            if panel.frame.origin != origin {
                panel.setFrameOrigin(origin)
            }
            lastPlacedOrigin = origin
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func makePanel(model: PermissionGuideModel) -> PermissionGuidePanel {
        let panel = PermissionGuidePanel()
        panel.title = model.title
        let hosting = NSHostingView(rootView: PermissionGuideView(model: model))
        // Measured while SwiftUI still reports its sizes, which `sizingOptions = []` turns off.
        let size = hosting.fittingSize
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        panel.setContentSize(size)
        self.panel = panel
        return panel
    }

    private static func screen(for settingsFrame: NSRect?) -> NSScreen? {
        guard let settingsFrame else { return NSScreen.main }
        return NSScreen.screens.max { lhs, rhs in
            lhs.frame.intersection(settingsFrame).area < rhs.frame.intersection(settingsFrame).area
        } ?? NSScreen.main
    }

    /// The name System Settings lists, such as "TypeWhisper" or "TypeWhisper Dev". The lists
    /// show the app's file name, not its display name.
    private static var appName: String {
        let name = FileManager.default.displayName(atPath: Bundle.main.bundlePath)
        let withoutExtension = (name as NSString).deletingPathExtension
        return withoutExtension.isEmpty ? "TypeWhisper" : withoutExtension
    }
}

/// Where the guide goes relative to the System Settings window.
enum PermissionGuidePlacement {
    static let gap: CGFloat = 12
    static let margin: CGFloat = 16
    /// Roughly the height of the System Settings toolbar, so the panel starts level with the list.
    static let toolbarHeight: CGFloat = 52

    /// Beside the System Settings window, to its right or else to its left. Without room on
    /// either side, over the window's bottom-right corner, below the end of most lists. Without
    /// a window, at the top right of the screen.
    static func origin(panelSize: NSSize, settingsFrame: NSRect?, visibleFrame: NSRect) -> NSPoint {
        let minX = visibleFrame.minX + margin
        let maxX = visibleFrame.maxX - margin - panelSize.width
        let minY = visibleFrame.minY + margin
        let maxY = visibleFrame.maxY - margin - panelSize.height

        guard let settingsFrame else {
            return NSPoint(x: max(minX, maxX), y: max(minY, maxY))
        }

        let besideY = clamp(settingsFrame.maxY - toolbarHeight - panelSize.height, min: minY, max: maxY)
        let rightX = settingsFrame.maxX + gap
        if rightX + panelSize.width <= visibleFrame.maxX {
            return NSPoint(x: rightX, y: besideY)
        }
        let leftX = settingsFrame.minX - gap - panelSize.width
        if leftX >= visibleFrame.minX {
            return NSPoint(x: leftX, y: besideY)
        }
        return NSPoint(
            x: clamp(settingsFrame.maxX - margin - panelSize.width, min: minX, max: maxX),
            y: clamp(settingsFrame.minY + margin, min: minY, max: maxY)
        )
    }

    private static func clamp(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        guard lower <= upper else { return lower }
        return Swift.min(Swift.max(value, lower), upper)
    }
}

/// Finds System Settings and its front window.
enum SystemSettingsWindowLocator {
    static let bundleIdentifier = "com.apple.systempreferences"

    static var runningApplication: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
    }

    static var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier
    }

    /// The frame of the frontmost System Settings window in screen coordinates. Window bounds
    /// need no Screen Recording permission; only window titles and contents do.
    static func frontWindowFrame(processIdentifier: pid_t) -> NSRect? {
        guard let primaryScreenHeight = NSScreen.screens.first?.frame.maxY,
              let windows = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements],
                  kCGNullWindowID
              ) as? [[String: Any]] else {
            return nil
        }

        // The list runs from front to back.
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processIdentifier,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  bounds.width > 200, bounds.height > 200 else {
                continue
            }
            return cocoaFrame(fromWindowBounds: bounds, primaryScreenHeight: primaryScreenHeight)
        }
        return nil
    }

    /// Window bounds start at the top left of the primary screen, AppKit frames at its bottom left.
    static func cocoaFrame(fromWindowBounds bounds: CGRect, primaryScreenHeight: CGFloat) -> NSRect {
        NSRect(
            x: bounds.minX,
            y: primaryScreenHeight - bounds.maxY,
            width: bounds.width,
            height: bounds.height
        )
    }
}

private extension NSRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

// MARK: - Panel

@MainActor
final class PermissionGuideModel: ObservableObject {
    let kind: PermissionGuideKind
    let appName: String
    let detectsGrant: Bool
    @Published var isGranted = false

    var onClose: (() -> Void)?
    var onRestart: (() -> Void)?

    init(kind: PermissionGuideKind, appName: String, detectsGrant: Bool) {
        self.kind = kind
        self.appName = appName
        self.detectsGrant = detectsGrant
    }

    var title: String {
        localizedAppText(
            "Turn on \(appName)",
            de: "\(appName) einschalten",
            ja: "\(appName) をオンにする",
            zh: "开启 \(appName)",
            es: "Activa \(appName)"
        )
    }

    var instruction: String {
        let list = kind.listName
        return localizedAppText(
            "In \u{201C}\(list)\u{201D}, turn on the switch next to \(appName).",
            de: "Schalte unter \u{201E}\(list)\u{201C} den Schalter neben \(appName) ein.",
            ja: "「\(list)」で \(appName) の横のスイッチをオンにしてください。",
            zh: "在“\(list)”中打开 \(appName) 旁边的开关。",
            es: "En \u{201C}\(list)\u{201D}, activa el interruptor junto a \(appName)."
        )
    }

    var dragHint: String {
        localizedAppText(
            "Not in the list? Drag this icon into it.",
            de: "Nicht in der Liste? Zieh dieses Symbol hinein.",
            ja: "リストにない場合は、このアイコンをリストにドラッグしてください。",
            zh: "不在列表中？把这个图标拖进列表。",
            es: "¿No aparece en la lista? Arrastra este icono a ella."
        )
    }

    var dragAccessibilityLabel: String {
        localizedAppText(
            "\(appName) app icon. Drag it into the list in System Settings.",
            de: "App-Symbol von \(appName). Zieh es in die Liste in den Systemeinstellungen.",
            ja: "\(appName) のアプリアイコン。システム設定のリストにドラッグします。",
            zh: "\(appName) 应用图标。将其拖到系统设置的列表中。",
            es: "Icono de \(appName). Arrástralo a la lista de Ajustes del Sistema."
        )
    }

    var waitingText: String {
        localizedAppText(
            "Waiting for access\u{2026}",
            de: "Warte auf die Freigabe\u{2026}",
            ja: "アクセスの許可を待っています\u{2026}",
            zh: "正在等待授权\u{2026}",
            es: "Esperando el acceso\u{2026}"
        )
    }

    var grantedText: String {
        localizedAppText(
            "\(appName) is allowed.",
            de: "\(appName) ist erlaubt.",
            ja: "\(appName) が許可されました。",
            zh: "已允许 \(appName)。",
            es: "\(appName) tiene acceso."
        )
    }

    var restartNote: String {
        localizedAppText(
            "macOS applies the permission after \(appName) restarts.",
            de: "macOS übernimmt die Berechtigung erst nach einem Neustart von \(appName).",
            ja: "この許可は \(appName) の再起動後に適用されます。",
            zh: "macOS 会在 \(appName) 重新启动后应用此权限。",
            es: "macOS aplica el permiso cuando \(appName) se reinicia."
        )
    }

    var restartTitle: String {
        localizedAppText(
            "Restart \(appName)",
            de: "\(appName) neu starten",
            ja: "\(appName) を再起動",
            zh: "重新启动 \(appName)",
            es: "Reiniciar \(appName)"
        )
    }

    var closeTitle: String {
        localizedAppText("Close", de: "Schließen", ja: "閉じる", zh: "关闭", es: "Cerrar")
    }
}

/// Floats above System Settings without taking focus from it, so the switch stays one click away.
private final class PermissionGuidePanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        collectionBehavior = FloatingPanelSpacePolicy.selectionPaletteCollectionBehavior
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct PermissionGuideView: View {
    @ObservedObject var model: PermissionGuideModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button(action: { model.onClose?() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help(model.closeTitle)
                .accessibilityLabel(model.closeTitle)
            }

            Text(model.instruction)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                AppIconDragSource()
                    .frame(width: 44, height: 44)
                    .help(model.dragHint)
                    .accessibilityLabel(model.dragAccessibilityLabel)
                Text(model.dragHint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Only this row changes, so the panel keeps its size when access arrives.
            if model.isGranted {
                Label(model.grantedText, systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
                    .frame(height: 20)
            } else if model.detectsGrant {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(model.waitingText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(height: 20)
            } else {
                Text(model.restartNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(model.restartTitle) { model.onRestart?() }
                    .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12))
        )
        .animation(.easeInOut(duration: 0.2), value: model.isGranted)
    }
}

/// The app icon as a drag source that carries the app's file URL, like a drag from Finder.
/// System Settings adds an app dropped into its privacy lists.
private struct AppIconDragSource: NSViewRepresentable {
    func makeNSView(context: Context) -> AppIconDragView {
        AppIconDragView()
    }

    func updateNSView(_ nsView: AppIconDragView, context: Context) {}
}

private final class AppIconDragView: NSView, NSDraggingSource {
    private var mouseDownEvent: NSEvent?

    override var intrinsicContentSize: NSSize { NSSize(width: 44, height: 44) }

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage.draw(in: bounds)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mouseDownEvent else { return }
        let start = mouseDownEvent.locationInWindow
        let current = event.locationInWindow
        guard hypot(current.x - start.x, current.y - start.y) > 3 else { return }
        self.mouseDownEvent = nil

        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: NSApp.applicationIconImage)
        beginDraggingSession(with: [item], event: mouseDownEvent, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }
}
