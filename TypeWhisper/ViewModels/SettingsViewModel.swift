import Foundation
import Combine

enum LanguageSelectionNilBehavior: Sendable {
    case inheritGlobal
    case auto
}

enum LanguageSelectionMode: String, Sendable {
    case inheritGlobal = "inherit"
    case auto
    case exact
    case multiple
}

enum LanguageSelection: Equatable, Sendable {
    case inheritGlobal
    case auto
    case exact(String)
    case hints([String])

    init(storedValue rawValue: String?, nilBehavior: LanguageSelectionNilBehavior) {
        guard let rawValue else {
            self = nilBehavior == .inheritGlobal ? .inheritGlobal : .auto
            return
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self = nilBehavior == .inheritGlobal ? .inheritGlobal : .auto
            return
        }

        if trimmed.caseInsensitiveCompare("auto") == .orderedSame {
            self = .auto
            return
        }

        if let data = trimmed.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            let normalized = Self.normalizedCodes(decoded)
            switch normalized.count {
            case 0:
                self = nilBehavior == .inheritGlobal ? .inheritGlobal : .auto
            case 1:
                self = .exact(normalized[0])
            default:
                self = .hints(normalized)
            }
            return
        }

        self = .exact(trimmed)
    }

    var mode: LanguageSelectionMode {
        switch self {
        case .inheritGlobal:
            return .inheritGlobal
        case .auto:
            return .auto
        case .exact:
            return .exact
        case .hints:
            return .multiple
        }
    }

    var requestedLanguage: String? {
        switch self {
        case .exact(let code):
            return code
        case .inheritGlobal, .auto, .hints:
            return nil
        }
    }

    var selectedCodes: [String] {
        switch self {
        case .exact(let code):
            return [code]
        case .hints(let codes):
            return Self.normalizedCodes(codes)
        case .inheritGlobal, .auto:
            return []
        }
    }

    var isRestrictingDetection: Bool {
        switch self {
        case .exact, .hints:
            return true
        case .inheritGlobal, .auto:
            return false
        }
    }

    func storedValue(nilBehavior: LanguageSelectionNilBehavior) -> String? {
        switch self {
        case .inheritGlobal:
            return nilBehavior == .inheritGlobal ? nil : "auto"
        case .auto:
            return "auto"
        case .exact(let code):
            return code
        case .hints(let codes):
            let normalized = Self.normalizedCodes(codes)
            switch normalized.count {
            case 0:
                return nilBehavior == .inheritGlobal ? nil : "auto"
            case 1:
                return normalized[0]
            default:
                guard let data = try? JSONEncoder().encode(normalized),
                      let encoded = String(data: data, encoding: .utf8) else {
                    return normalized.joined(separator: ",")
                }
                return encoded
            }
        }
    }

    func withSelectedCodes(_ codes: [String], nilBehavior: LanguageSelectionNilBehavior) -> LanguageSelection {
        let normalized = Self.normalizedCodes(codes)
        switch normalized.count {
        case 0:
            return nilBehavior == .inheritGlobal ? .inheritGlobal : .auto
        case 1:
            return .exact(normalized[0])
        default:
            return .hints(normalized)
        }
    }

    func normalizedForSupportedLanguages(_ supportedLanguages: [String]) -> LanguageSelection {
        let supportedSet = Set(supportedLanguages)
        guard !supportedSet.isEmpty else {
            switch self {
            case .hints(let codes):
                return withSelectedCodes(codes, nilBehavior: .auto)
            default:
                return self
            }
        }

        switch self {
        case .exact(let code):
            return supportedSet.contains(code) ? .exact(code) : .auto
        case .hints(let codes):
            let filtered = codes.filter { supportedSet.contains($0) }
            return withSelectedCodes(filtered, nilBehavior: .auto)
        case .inheritGlobal, .auto:
            return self
        }
    }

    private static func normalizedCodes(_ codes: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []

        for rawCode in codes {
            let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !code.isEmpty else { continue }
            guard seen.insert(code).inserted else { continue }
            normalized.append(code)
        }

        return normalized
    }
}

@MainActor
final class SettingsViewModel: ObservableObject {
    nonisolated(unsafe) static var _shared: SettingsViewModel?
    static var shared: SettingsViewModel {
        guard let instance = _shared else {
            fatalError("SettingsViewModel not initialized")
        }
        return instance
    }

    @Published var languageSelection: LanguageSelection {
        didSet {
            UserDefaults.standard.set(
                languageSelection.storedValue(nilBehavior: .auto),
                forKey: UserDefaultsKeys.selectedLanguage
            )
        }
    }
    @Published var selectedTask: TranscriptionTask {
        didSet {
            UserDefaults.standard.set(selectedTask.rawValue, forKey: UserDefaultsKeys.selectedTask)
        }
    }
    @Published var translationEnabled: Bool {
        didSet {
            UserDefaults.standard.set(translationEnabled, forKey: UserDefaultsKeys.translationEnabled)
        }
    }
    @Published var translationTargetLanguage: String {
        didSet {
            UserDefaults.standard.set(translationTargetLanguage, forKey: UserDefaultsKeys.translationTargetLanguage)
        }
    }
    private let modelManager: ModelManagerService
    private var cancellables = Set<AnyCancellable>()

    init(modelManager: ModelManagerService) {
        self.modelManager = modelManager
        self.languageSelection = LanguageSelection(
            storedValue: UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedLanguage),
            nilBehavior: .auto
        )
        self.selectedTask = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedTask)
            .flatMap { TranscriptionTask(rawValue: $0) } ?? .transcribe
        self.translationEnabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.translationEnabled)
        self.translationTargetLanguage = UserDefaults.standard.string(forKey: UserDefaultsKeys.translationTargetLanguage) ?? "en"
    }

    var selectedLanguage: String? {
        languageSelection.requestedLanguage
    }

    func observePluginManager() {
        PluginManager.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    var availableLanguages: [(code: String, name: String)] {
        var codes = Set<String>()
        for engine in PluginManager.shared.transcriptionEngines {
            for code in engine.supportedLanguages {
                codes.insert(code)
            }
        }
        return codes.map { code in
            let name = Locale.current.localizedString(forIdentifier: code) ?? code
            return (code: code, name: name)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var supportsTranslation: Bool {
        modelManager.supportsTranslation
    }
}
