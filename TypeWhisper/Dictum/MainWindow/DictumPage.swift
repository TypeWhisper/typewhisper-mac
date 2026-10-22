import SwiftUI

enum DictumPage: String, CaseIterable, Identifiable {
    case home, history, dictionary, style, general, speech, aiModels

    var id: String { rawValue }
    var titleKey: String {
        switch self {
        case .home: "Home"
        case .history: "History"
        case .dictionary: "Dictionary"
        case .style: "Style"
        case .general: "General"
        case .speech: "Speech"
        case .aiModels: "AI Models"
        }
    }
    var title: String {
        String(localized: String.LocalizationValue(titleKey), table: "DictumShell")
    }
    var symbol: String {
        switch self {
        case .home: "house"
        case .history: "clock"
        case .dictionary: "book"
        case .style: "wand.and.sparkles"
        case .general: "gearshape"
        case .speech: "waveform"
        case .aiModels: "sparkles"
        }
    }
    var shortcut: KeyEquivalent { KeyEquivalent(shortcutCharacter) }
    var shortcutCharacter: Character {
        Character(String(Self.allCases.firstIndex(of: self)! + 1))
    }
    var isSettings: Bool { [.general, .speech, .aiModels].contains(self) }
}
