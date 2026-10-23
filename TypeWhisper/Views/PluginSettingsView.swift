import AppKit
import Combine
import SwiftUI
import TypeWhisperPluginSDK

struct PluginScreenshotPagination {
    static let overlap: CGFloat = 48

    static func pageOffsets(
        contentHeight: CGFloat,
        viewportHeight: CGFloat
    ) -> [CGFloat] {
        guard contentHeight > viewportHeight + 1, viewportHeight > overlap + 1 else {
            return [0]
        }

        let maximumOffset = contentHeight - viewportHeight
        let stride = viewportHeight - overlap
        let additionalPageCount = Int(ceil(maximumOffset / stride))
        return (0...additionalPageCount).map { pageIndex in
            min(CGFloat(pageIndex) * stride, maximumOffset)
        }
    }
}

private struct PluginScreenshotScrollState: Codable {
    let windowNumber: Int
    let pageIndex: Int
    let pageCount: Int
    let contentHeight: Double
    let viewportHeight: Double
    let scrollOffset: Double
    let backingScaleFactor: Double
    let windowFrameHeight: Double
    let titlebarHeight: Double
    let scrollViewportMinY: Double
    let scrollViewportMaxY: Double
}

@MainActor
final class PluginSettingsScreenshotCaptureController {
    private let window: NSWindow
    private let readyFileURL: URL
    private let commandFileURL: URL
    private var scrollView: NSScrollView?
    private var pageOffsets: [CGFloat] = [0]
    private var contentHeight: CGFloat = 0
    private var viewportHeight: CGFloat = 0
    private var scrollViewportMinY: CGFloat = 0
    private var scrollViewportMaxY: CGFloat = 0
    private var lastCommand: String?
    private var commandMonitor: Task<Void, Never>?

    init(window: NSWindow, readyFileURL: URL, commandFileURL: URL) {
        self.window = window
        self.readyFileURL = readyFileURL
        self.commandFileURL = commandFileURL
    }

    deinit {
        commandMonitor?.cancel()
    }

    func start() {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        if let candidate = primaryScrollableView() {
            scrollView = candidate
            candidate.hasVerticalScroller = false
            contentHeight = documentHeight(of: candidate)
            let clipView = candidate.contentView
            viewportHeight = clipView.documentVisibleRect.height
            let viewportRect = clipView.convert(clipView.bounds, to: nil)
            scrollViewportMinY = viewportRect.minY
            scrollViewportMaxY = viewportRect.maxY
            pageOffsets = PluginScreenshotPagination.pageOffsets(
                contentHeight: contentHeight,
                viewportHeight: viewportHeight
            )
            scroll(toPage: 0)
        } else {
            contentHeight = window.contentLayoutRect.height
            viewportHeight = contentHeight
            scrollViewportMinY = 0
            scrollViewportMaxY = viewportHeight
        }

        writeReadyState(pageIndex: 0)
        guard pageOffsets.count > 1 else { return }

        commandMonitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                self.processCommandIfNeeded()
            }
        }
    }

    private func processCommandIfNeeded() {
        guard let value = try? String(contentsOf: commandFileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value != lastCommand,
              let pageIndex = Int(value),
              pageOffsets.indices.contains(pageIndex) else { return }

        lastCommand = value
        scroll(toPage: pageIndex)

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.writeReadyState(pageIndex: pageIndex)
        }
    }

    private func scroll(toPage pageIndex: Int) {
        guard let scrollView, let documentView = scrollView.documentView else { return }
        let offset = pageOffsets[pageIndex]
        let maximumOffset = max(0, contentHeight - viewportHeight)
        let targetY = documentView.isFlipped ? offset : maximumOffset - offset
        scrollView.contentView.scroll(
            to: NSPoint(x: scrollView.contentView.bounds.minX, y: targetY)
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        window.displayIfNeeded()
    }

    private func writeReadyState(pageIndex: Int) {
        let state = PluginScreenshotScrollState(
            windowNumber: window.windowNumber,
            pageIndex: pageIndex,
            pageCount: pageOffsets.count,
            contentHeight: contentHeight,
            viewportHeight: viewportHeight,
            scrollOffset: pageOffsets[pageIndex],
            backingScaleFactor: window.backingScaleFactor,
            windowFrameHeight: window.frame.height,
            titlebarHeight: window.frame.height - window.contentLayoutRect.height,
            scrollViewportMinY: scrollViewportMinY,
            scrollViewportMaxY: scrollViewportMaxY
        )

        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: readyFileURL, options: .atomic)
        } catch {
            fputs("Could not write plugin screenshot state: \(error)\n", stderr)
        }
    }

    private func primaryScrollableView() -> NSScrollView? {
        guard let contentView = window.contentView else { return nil }
        return scrollViews(in: contentView)
            .filter { scrollView in
                documentHeight(of: scrollView) > scrollView.contentView.documentVisibleRect.height + 1
            }
            .max { lhs, rhs in
                let lhsOverflow = documentHeight(of: lhs) - lhs.contentView.documentVisibleRect.height
                let rhsOverflow = documentHeight(of: rhs) - rhs.contentView.documentVisibleRect.height
                if lhsOverflow == rhsOverflow {
                    return lhs.contentView.bounds.width < rhs.contentView.bounds.width
                }
                return lhsOverflow < rhsOverflow
            }
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        let current = (view as? NSScrollView).map { [$0] } ?? []
        return current + view.subviews.flatMap(scrollViews(in:))
    }

    private func documentHeight(of scrollView: NSScrollView) -> CGFloat {
        guard let documentView = scrollView.documentView else { return 0 }
        return max(documentView.bounds.height, documentView.frame.height)
    }
}

@MainActor
final class PluginSettingsWindowManager {
    static let shared = PluginSettingsWindowManager()

    private var windows: [String: NSWindow] = [:]
    private var delegates: [String: PluginSettingsWindowDelegate] = [:]

    func managedWindow(for pluginId: String) -> NSWindow? {
        windows[pluginId]
    }

    func closeWindow(for pluginId: String) {
        guard let window = windows.removeValue(forKey: pluginId) else { return }

        delegates.removeValue(forKey: pluginId)
        window.delegate = nil
        window.close()

        // A closed NSWindow with isReleasedWhenClosed=false retains its hosting view.
        // Tear down the plugin-owned SwiftUI graph before its runtime registration is removed.
        window.contentView = nil
    }

    func present(_ plugin: LoadedPlugin) {
        guard let settingsView = plugin.instance.settingsView else { return }
        let layout = plugin.instance as? any PluginSettingsWindowLayoutProviding
        let preferredSize = layout?.preferredSettingsWindowSize ?? CGSize(width: 560, height: 440)
        let minimumSize = layout?.minimumSettingsWindowSize ?? CGSize(width: 500, height: 400)
        let settingsViewManagesScrolling = layout?.settingsViewManagesScrolling ?? false

        if let window = windows[plugin.id] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: preferredSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let hostingView = NSHostingView(
            rootView: PluginSettingsWindowContent(
                settingsView: settingsView,
                settingsViewManagesScrolling: settingsViewManagesScrolling
            )
                .environment(\.pluginSettingsClose, { [weak window] in
                    window?.close()
                })
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        )
        hostingView.sizingOptions = []
        window.title = plugin.manifest.name
        window.contentMinSize = minimumSize
        window.isReleasedWhenClosed = false
        window.contentView = hostingView

        let autosaveName = "plugin-settings.\(plugin.id)"
        if !window.setFrameUsingName(autosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(autosaveName)

        let delegate = PluginSettingsWindowDelegate(pluginId: plugin.id) { [weak self] pluginId in
            self?.windows[pluginId] = nil
            self?.delegates[pluginId] = nil
        }
        delegates[plugin.id] = delegate
        windows[plugin.id] = window
        window.delegate = delegate
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct PluginSettingsWindowContent: View {
    let settingsView: AnyView
    let settingsViewManagesScrolling: Bool

    var body: some View {
        if settingsViewManagesScrolling {
            settingsView
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                settingsView
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private final class PluginSettingsWindowDelegate: NSObject, NSWindowDelegate {
    private let pluginId: String
    private let onClose: (String) -> Void

    init(pluginId: String, onClose: @escaping (String) -> Void) {
        self.pluginId = pluginId
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose(pluginId)
    }
}

struct PluginSettingsView: View {
    @ObservedObject private var pluginManager = PluginManager.shared
    @ObservedObject private var modelManager = ServiceContainer.shared.modelManagerService
    let focusedPluginId: String

    var body: some View {
        Group {
            if let plugin = pluginManager.loadedPlugins.first(where: { $0.id == focusedPluginId }) {
                pluginPage(plugin)
            } else {
                ContentUnavailableView(
                    String(localized: "Integration Unavailable"),
                    systemImage: "puzzlepiece.extension"
                )
            }
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    private func pluginPage(_ plugin: LoadedPlugin) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: plugin.manifest.iconSystemName ?? "puzzlepiece.extension")
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .accessibilityHidden(true)
                Text(plugin.manifest.name)
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(plugin.manifest.version)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if plugin.isEnabled {
                    engineControl(plugin)
                    Button(localizedAppText("Disable", de: "Deaktivieren", ja: "無効にする")) {
                        pluginManager.setPluginEnabled(plugin.id, enabled: false)
                    }
                } else {
                    Button(String(localized: "Enable")) {
                        pluginManager.setPluginEnabled(plugin.id, enabled: true)
                    }
                }
            }
            .controlSize(.small)
            .padding(.horizontal, SettingsLayoutMetrics.pagePadding)
            .padding(.vertical, 14)
            Divider()
            InstalledPluginRow(plugin: plugin)
                .padding(.horizontal, SettingsLayoutMetrics.pagePadding)
            if plugin.isEnabled, plugin.supportsSettingsWindow,
               let settingsView = plugin.instance.settingsView {
                let layout = plugin.instance as? any PluginSettingsWindowLayoutProviding
                PluginSettingsWindowContent(
                    settingsView: settingsView,
                    settingsViewManagesScrolling: layout?.settingsViewManagesScrolling ?? false
                )
                .padding(SettingsLayoutMetrics.pagePadding)
            } else {
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func engineControl(_ plugin: LoadedPlugin) -> some View {
        let providerIds = pluginManager.transcriptionProviderIds(exposedBy: plugin.instance)
        if let selectedProviderId = modelManager.selectedProviderId, providerIds.contains(selectedProviderId) {
            Label(
                localizedAppText("Active engine", de: "Aktive Engine", ja: "使用中のエンジン"),
                systemImage: "checkmark.circle.fill"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(.green)
        } else if let engine = plugin.instance as? any TranscriptionEnginePlugin {
            Button {
                modelManager.selectProvider(engine.providerId)
            } label: {
                Label(
                    localizedAppText("Use as engine", de: "Als Engine verwenden", ja: "エンジンとして使用"),
                    systemImage: "waveform"
                )
            }
            .disabled(!modelManager.canPrepareForTranscription(engine))
        }
    }
}

extension LoadedPlugin {
    var iconResourceURL: URL? {
        guard let resourceName = manifest.iconResourceName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !resourceName.isEmpty else {
            return nil
        }

        let resourcesURL = (bundle.resourceURL ?? sourceURL.appendingPathComponent("Contents/Resources"))
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let url = resourcesURL
            .appendingPathComponent(resourceName)
            .resolvingSymlinksInPath()
            .standardizedFileURL

        guard url.pathComponents.starts(with: resourcesURL.pathComponents),
              url.pathComponents.count > resourcesURL.pathComponents.count else {
            return nil
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }

        return url
    }
}


private struct InstalledPluginRow: View {
    let plugin: LoadedPlugin
    @State private var pluginActivity: PluginSettingsActivity?
    @State private var modelsExpanded = false
    @State private var modelPendingDeletion: PluginModelInfo?
    @State private var deletingModelId: String?
    @State private var modelDeleteError: String?

    private let activityTimer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        let models = downloadedModels

        VStack(spacing: 0) {
            if hasStatus(models: models) {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    if !models.isEmpty {
                        Button {
                            modelsExpanded.toggle()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: modelsExpanded ? "chevron.down" : "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .frame(width: 10)
                                Label(downloadedModelCountTitle(models.count), systemImage: "externaldrive")
                                    .labelStyle(.titleAndIcon)
                            }
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(downloadedModelCountTitle(models.count))
                        .accessibilityValue(modelsExpanded
                            ? localizedAppText("Expanded", de: "Ausgeklappt", ja: "展開", zh: "已展开")
                            : localizedAppText("Collapsed", de: "Eingeklappt", ja: "折りたたみ", zh: "已折叠"))
                    }

                    pluginActions
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            if modelsExpanded && !models.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                        DownloadedPluginModelRow(
                            model: model,
                            isDeleting: deletingModelId == model.id,
                            onDelete: {
                                modelPendingDeletion = model
                            }
                        )
                        .disabled(deletingModelId != nil)

                        if index < models.count - 1 {
                            Divider()
                                .padding(.leading, 57)
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .padding(.bottom, SettingsLayoutMetrics.sectionSpacing)
            }
        }
        .onAppear {
            refreshPluginActivity()
        }
        .onReceive(activityTimer) { _ in
            refreshPluginActivity()
        }
        .alert(
            String(localized: "Remove Downloaded Model"),
            isPresented: Binding(
                get: { modelPendingDeletion != nil },
                set: { if !$0 { modelPendingDeletion = nil } }
            ),
            presenting: modelPendingDeletion
        ) { model in
            Button(String(localized: "Remove"), role: .destructive) {
                deleteDownloadedModel(model)
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                modelPendingDeletion = nil
            }
        } message: { model in
            Text(deleteConfirmationMessage(for: model, downloadedCount: models.count))
        }
        .alert(
            String(localized: "Could Not Remove Model"),
            isPresented: Binding(
                get: { modelDeleteError != nil },
                set: { if !$0 { modelDeleteError = nil } }
            )
        ) {
            Button(String(localized: "OK")) { modelDeleteError = nil }
        } message: {
            if let modelDeleteError {
                Text(modelDeleteError)
            }
        }
    }

    private var downloadedModels: [PluginModelInfo] {
        guard plugin.isRuntimeLoaded,
              let modelManager = plugin.instance as? any PluginDownloadedModelManaging else {
            return []
        }
        return modelManager.downloadedModels
            .sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
    }

    @ViewBuilder
    private var pluginActions: some View {
        if let pluginActivity {
            PluginSettingsActivityView(activity: pluginActivity)
        }
    }

    private func hasStatus(models: [PluginModelInfo]) -> Bool {
        !models.isEmpty || pluginActivity != nil
    }

    private func downloadedModelCountTitle(_ count: Int) -> String {
        if count == 1 {
            return String(localized: "1 downloaded model")
        }
        return String(localized: "\(count) downloaded models")
    }

    private func deleteConfirmationMessage(for model: PluginModelInfo, downloadedCount: Int) -> String {
        if downloadedCount <= 1, PluginManager.shared.disablesWithoutDownloadedModels(plugin) {
            return String(localized: "Remove \(model.displayName)? This will delete the downloaded model files and disable \(plugin.manifest.name).")
        }
        return String(localized: "Remove \(model.displayName)? This will delete the downloaded model files. \(plugin.manifest.name) will stay installed and enabled.")
    }

    private func deleteDownloadedModel(_ model: PluginModelInfo) {
        modelPendingDeletion = nil
        deletingModelId = model.id

        Task { @MainActor in
            do {
                try await PluginManager.shared.deleteDownloadedModel(pluginId: plugin.id, modelId: model.id)
            } catch {
                modelDeleteError = error.localizedDescription
            }
            deletingModelId = nil
        }
    }

    private func refreshPluginActivity() {
        guard plugin.isRuntimeLoaded else {
            pluginActivity = nil
            return
        }
        pluginActivity = (plugin.instance as? any PluginSettingsActivityReporting)?.currentSettingsActivity
    }
}

private struct DownloadedPluginModelRow: View {
    let model: PluginModelInfo
    let isDeleting: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.loaded == true ? "checkmark.circle.fill" : "externaldrive")
                .foregroundStyle(model.loaded == true ? .green : .secondary)
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)

                    if model.loaded == true {
                        Text(String(localized: "Loaded"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }

                if !model.sizeDescription.isEmpty || model.languageCount > 0 {
                    Text(modelDetailText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isStaticText)

            Spacer(minLength: 12)

            if isDeleting {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(localizedAppText(
                        "Removing \(model.displayName)",
                        de: "\(model.displayName) wird entfernt",
                        ja: "\(model.displayName)を削除中",
                        zh: "正在移除\(model.displayName)"
                    ))
            } else {
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Remove downloaded model"))
                .accessibilityLabel(String(localized: "Remove \(model.displayName)"))
            }
        }
        .padding(.leading, 29)
        .padding(.trailing, 14)
        .padding(.vertical, 7)
    }

    private var modelDetailText: String {
        var parts: [String] = []
        if !model.sizeDescription.isEmpty {
            parts.append(model.sizeDescription)
        }
        if model.languageCount > 0 {
            parts.append(String(localized: "\(model.languageCount) languages"))
        }
        return parts.joined(separator: " - ")
    }
}


private struct PluginSettingsActivityView: View {
    let activity: PluginSettingsActivity

    var body: some View {
        if let progress = activity.progress {
            HStack(spacing: 6) {
                // Not only red: an error also shows the warning sign, as it does without progress.
                if activity.isError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                ProgressView(value: progress)
                    .frame(width: 80)
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(activity.isError ? .red : .secondary)
                    .monospacedDigit()
                    .frame(width: 32, alignment: .trailing)
                Text(activity.message)
                    .font(.caption)
                    .foregroundStyle(activity.isError ? .red : .secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel(accessibilityMessage)
            .accessibilityValue("\(Int(progress * 100))%")
        } else {
            HStack(spacing: 6) {
                if activity.isError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(activity.message)
                    .font(.caption)
                    .foregroundStyle(activity.isError ? .red : .secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel(accessibilityMessage)
        }
    }

    /// VoiceOver says "Error" instead of relying on the red color and the icon.
    private var accessibilityMessage: String {
        activity.isError ? String(localized: "Error: \(activity.message)") : activity.message
    }
}

func validatedExternalURL(_ urlString: String?) -> URL? {
    guard let value = urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty,
          let components = URLComponents(string: value),
          let scheme = components.scheme?.lowercased(),
          (scheme == "https" || scheme == "http"),
          components.host != nil,
          let url = components.url else {
        return nil
    }
    return url
}

func validatedHTTPSURL(_ urlString: String?) -> URL? {
    guard let url = validatedExternalURL(urlString),
          url.scheme?.lowercased() == "https" else {
        return nil
    }
    return url
}
