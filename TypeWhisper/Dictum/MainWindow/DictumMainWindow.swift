import AppKit
import SwiftUI

@MainActor final class DictumNavigation: ObservableObject {
    static let shared = DictumNavigation()
    @Published var page: DictumPage = .home

    func open(_ page: DictumPage? = nil) {
        if let page { self.page = page }
        ManagedAppWindowOpener.shared.open(id: "dictum")
    }
}

struct DictumMainWindow: Scene {
    var body: some Scene {
        WindowGroup("dictum", id: "dictum") {
            if AppConstants.isRunningTests {
                EmptyView()
            } else {
                DictumMainView()
                    .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1040, height: 680)
        .windowResizability(.contentMinSize)
        .handlesExternalEvents(matching: [])
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button {
                    DictumNavigation.shared.open(.general)
                } label: { Text("Settings…", tableName: "DictumShell") }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

struct DictumMainView: View {
    @ObservedObject private var navigation = DictumNavigation.shared

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            Sidebar(page: $navigation.page)
                .navigationSplitViewColumnWidth(min: 212, ideal: 212, max: 212)
                .ignoresSafeArea(.container, edges: .top)
        } detail: {
            pageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DictumTheme.windowBackground)
                .ignoresSafeArea(.container, edges: .top)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .ignoresSafeArea()
        .font(DictumTheme.Typography.body)
        .foregroundStyle(DictumTheme.textPrimary)
        .frame(minWidth: 860, minHeight: 560)
        .background(DictumWindowAccessor(page: navigation.page))
    }

    @ViewBuilder private var pageContent: some View {
        switch navigation.page {
        case .home: HomePage()
        case .history: DictumHistoryPage()
        case .dictionary: DictionaryPage()
        case .style: StylePage()
        case .general: GeneralPage()
        case .speech: SpeechPage()
        case .aiModels: AIModelsPage()
        }
    }
}

struct DictumPageFrame<Actions: View, Content: View>: View {
    let page: DictumPage
    let actions: Actions
    let content: Content

    init(page: DictumPage, @ViewBuilder actions: () -> Actions, @ViewBuilder content: () -> Content) {
        self.page = page
        self.actions = actions()
        self.content = content()
    }

    init(page: DictumPage, @ViewBuilder content: () -> Content) where Actions == EmptyView {
        self.init(page: page, actions: { EmptyView() }, content: content)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(page.title).font(DictumTheme.Typography.toolbar).accessibilityAddTraits(.isHeader)
                Spacer()
                actions
            }
            .padding(.leading, 28).padding(.trailing, 20).frame(height: 52)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct DictumWindowAccessor: NSViewRepresentable {
    let page: DictumPage

    final class WindowView: NSView {
        override func layout() {
            super.layout()
            if let window { positionWindowButtons(window) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            configure(window)
        }

        func configure(_ window: NSWindow) {
            window.isRestorable = false
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.toolbar = nil
            window.titlebarSeparatorStyle = .none
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(kind)?.isHidden = false
            }
            window.minSize = NSSize(width: 860, height: 560)
            positionWindowButtons(window)
            DispatchQueue.main.async { [weak self, weak window] in
                guard let window else { return }
                window.toolbar = nil
                self?.positionWindowButtons(window)
            }
        }

        private func positionWindowButtons(_ window: NSWindow) {
            guard !window.styleMask.contains(.fullScreen) else { return }
            for (index, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
                guard let button = window.standardWindowButton(kind), let parent = button.superview else { continue }
                let origin = parent.convert(NSPoint(
                    x: 26 + CGFloat(index) * 20 - button.frame.width / 2,
                    y: window.frame.height - 25 - button.frame.height / 2
                ), from: nil)
                if button.frame.origin != origin { button.setFrameOrigin(origin) }
            }
        }
    }
    func makeNSView(context: Context) -> WindowView { WindowView() }
    func updateNSView(_ nsView: WindowView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window { nsView.configure(window) }
        }
    }
}
