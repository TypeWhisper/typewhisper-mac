import Foundation
import Combine

enum StyleFormality: String, Codable, CaseIterable, Sendable { case casual, balanced, formal }
enum StyleTone: String, Codable, CaseIterable, Sendable { case warm, direct, upbeat }
enum StyleEmoji: String, Codable, CaseIterable, Sendable { case none, sometimes, often }

struct StyleSettings: Codable, Equatable, Sendable {
    var formality: StyleFormality = .balanced
    var tone: StyleTone = .warm
    var emoji: StyleEmoji = .sometimes
    var signOff: String?
}

struct AppStyle: Codable, Equatable, Identifiable, Sendable {
    enum Group: String, Codable, CaseIterable, Sendable { case chat, mail, docs, code }
    enum Kind: Codable, Equatable, Sendable { case builtInGroup(Group), userApp }
    var id: String
    var kind: Kind
    var name: String
    var bundleIDs: [String]
    var urlPatterns: [String]
    var formality: StyleFormality
    var tone: StyleTone
    var emoji: StyleEmoji
    var addSignOff: Bool = false
    var extraInstructions: String = ""

    var isBuiltIn: Bool {
        if case .builtInGroup = kind { return true }
        return false
    }

    // 同一应用的不同发行版共用一项计数，浏览器内的 Gmail 和 Google Docs 各占一项。
    var applicationCount: Int {
        switch kind {
        case .builtInGroup(.chat): 8
        case .builtInGroup(.mail): 4
        case .builtInGroup(.docs): 6
        case .builtInGroup(.code): 5
        case .userApp: bundleIDs.count
        }
    }

    func matches(bundleID: String?, browserURL: String?) -> Bool {
        if let bundleID, bundleIDs.contains(bundleID) { return true }
        guard let browserURL, let url = URL(string: browserURL),
              let host = url.host?.lowercased() else { return false }
        return urlPatterns.contains { pattern in
            let components = pattern.split(separator: "/", maxSplits: 1).map(String.init)
            guard let domain = components.first, host == domain.lowercased() else { return false }
            return components.count == 1 || url.path.hasPrefix("/" + components[1])
        }
    }

    static let defaults: [AppStyle] = [
        .init(id: "chat", kind: .builtInGroup(.chat), name: "Chat",
              bundleIDs: ["com.tencent.xinWeChat", "com.tinyspeck.slackmacgap", "com.electron.lark", "com.bytedance.Lark", "ru.keepcoder.Telegram", "org.telegram.desktop", "com.apple.MobileSMS", "com.alibaba.DingTalkMac", "com.hnc.Discord", "net.whatsapp.WhatsApp"],
              urlPatterns: [], formality: .casual, tone: .warm, emoji: .sometimes),
        .init(id: "mail", kind: .builtInGroup(.mail), name: "Mail",
              bundleIDs: ["com.apple.mail", "com.microsoft.Outlook", "com.readdle.smartemail-Mac"],
              urlPatterns: ["mail.google.com"], formality: .formal, tone: .warm, emoji: .none, addSignOff: true),
        .init(id: "docs", kind: .builtInGroup(.docs), name: "Docs",
              bundleIDs: ["notion.id", "com.apple.Notes", "com.microsoft.Word", "com.apple.iWork.Pages", "md.obsidian"],
              urlPatterns: ["docs.google.com"], formality: .balanced, tone: .direct, emoji: .none,
              extraInstructions: String(localized: "Use lists where appropriate", table: "DictumStyle")),
        .init(id: "code", kind: .builtInGroup(.code), name: "Code",
              bundleIDs: ["com.todesktop.230313mzl4w4u92", "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.apple.Terminal", "com.googlecode.iterm2"],
              urlPatterns: [], formality: .balanced, tone: .direct, emoji: .none,
              extraInstructions: String(localized: "Keep English technical terms and code identifiers", table: "DictumStyle"))
    ]
}

/// 解析结果是值快照，翻译与润色可以共享，录音期间设置变化不会修改已创建的请求。
struct ResolvedStyle: Equatable, Sendable {
    var formality: StyleFormality
    var tone: StyleTone
    var emoji: StyleEmoji
    var signOff: String?
    var extraInstructions: String
    var group: AppStyle.Group?

    static func resolve(bundleID: String?, browserURL: String?, global: StyleSettings,
                        apps: [AppStyle]) -> Self {
        let matches = apps.filter { $0.matches(bundleID: bundleID, browserURL: browserURL) }
        let selected = matches.first { !$0.isBuiltIn } ?? matches.first
        var group: AppStyle.Group?
        if case .builtInGroup(let value) = matches.first(where: \.isBuiltIn)?.kind { group = value }
        return Self(formality: selected?.formality ?? global.formality,
                    tone: selected?.tone ?? global.tone, emoji: selected?.emoji ?? global.emoji,
                    signOff: (selected?.addSignOff ?? (global.formality == .formal)) ? global.signOff : nil,
                    extraInstructions: selected?.extraInstructions ?? "", group: group)
    }
}

@MainActor
final class StyleStore: ObservableObject {
    static let shared = StyleStore()
    private let defaults: UserDefaults
    @Published var global: StyleSettings { didSet { save(global, key: "dictum.style.global") } }
    @Published var apps: [AppStyle] { didSet { save(apps, key: "dictum.style.apps") } }
    @Published var level: PolishLevel { didSet { defaults.set(level.rawValue, forKey: "dictum.polishLevel") } }
    private var defaultsObserver: AnyCancellable?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        global = defaults.data(forKey: "dictum.style.global").flatMap { try? JSONDecoder().decode(StyleSettings.self, from: $0) } ?? StyleSettings()
        apps = defaults.data(forKey: "dictum.style.apps").flatMap { try? JSONDecoder().decode([AppStyle].self, from: $0) } ?? AppStyle.defaults
        level = defaults.string(forKey: "dictum.polishLevel").flatMap(PolishLevel.init(rawValue:)) ?? .standard
        defaultsObserver = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: defaults)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let updated = defaults.string(forKey: "dictum.polishLevel").flatMap(PolishLevel.init(rawValue:)) ?? .standard
                if self.level != updated { self.level = updated }
            }
    }

    func resolve(bundleID: String?, browserURL: String?) -> ResolvedStyle {
        .resolve(bundleID: bundleID, browserURL: browserURL, global: global, apps: apps)
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}
