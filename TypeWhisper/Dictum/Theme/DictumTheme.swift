import AppKit
import SwiftUI

enum DictumTheme {
    static let accent = color(0x3B5BDB, 0x6E8BFF)
    static let accentSoft = color(0x3B5BDB, 0x6E8BFF, lightAlpha: 0.10, darkAlpha: 0.16)
    static let live = color(0xF2423A, 0xFF5A50)
    static let translate = color(0x8E4FE8, 0xB383FF)
    static let translateSoft = color(0x8E4FE8, 0xB383FF, lightAlpha: 0.12, darkAlpha: 0.16)
    static let success = color(0x23A55A, 0x3CCF72)
    static let warning = color(0xD98A00, 0xFFB340)
    static let danger = color(0xE0434B, 0xFF6369)
    static let windowBackground = color(0xFFFFFF, 0x1E1E20)
    static let card = color(0xF6F6F8, 0x262629)
    static let raised = color(0xFFFFFF, 0x2C2C2F)
    static let selected = color(0x000000, 0xFFFFFF, lightAlpha: 0.075, darkAlpha: 0.09)
    static let control = color(0xFFFFFF, 0x3A3A3D)
    static let controlBorder = color(0x000000, 0xFFFFFF, lightAlpha: 0.16, darkAlpha: 0.10)
    static let controlShadow = color(0x000000, 0x000000, lightAlpha: 0.08, darkAlpha: 0.30)
    static let inset = color(0xF1F1F4, 0x18181A)
    static let textPrimary = color(0x1D1D1F, 0xF2F2F4)
    static let textSecondary = color(0x6E6E73, 0xA1A1A8)
    static let textTertiary = color(0xA1A1A6, 0x6C6C72)
    static let separator = color(0x000000, 0xFFFFFF, lightAlpha: 0.085, darkAlpha: 0.08)
    static let separatorStrong = color(0x000000, 0xFFFFFF, lightAlpha: 0.14, darkAlpha: 0.14)
    static let heat = zip(
        [0xECECF0, 0xCDD6F6, 0x9AAEEE, 0x6A86E3, 0x3B5BDB],
        [0x2C2C30, 0x283463, 0x34479A, 0x4E67D1, 0x7B94FF]
    ).map { color($0.0, $0.1) }

    enum Typography {
        static let onboarding = Font.system(size: 24, weight: .bold)
        static let toolbar = Font.system(size: 15, weight: .semibold)
        static let section = Font.system(size: 13, weight: .semibold)
        static let body = Font.system(size: 13)
        static let secondary = Font.system(size: 12)
        static let caption = Font.system(size: 11)
        static let stat = Font.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit()
        static let reading = Font.system(size: 15)
        static let voiceText = Font.system(size: 15)
        static let timer = Font.system(size: 13, design: .rounded).monospacedDigit()
        static let readingLineSpacing: CGFloat = 10
    }

    enum Layout {
        static let spacing: [CGFloat] = [2, 4, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32]
        static let sidebar: CGFloat = 212
        static let toolbar: CGFloat = 52
        static let contentPadding: CGFloat = 28
        static let sectionGap: CGFloat = 26
        static let gridGap: CGFloat = 12
        static let formWidth: CGFloat = 600
        static let controlRadius: CGFloat = 6
        static let rowRadius: CGFloat = 8
        static let cardRadius: CGFloat = 12
        static let groupRadius: CGFloat = 10
        static let sheetRadius: CGFloat = 12
        static let voiceCollapsedRadius: CGFloat = 22
        static let voiceExpandedRadius: CGFloat = 20
        static let iconSmallRadius: CGFloat = 5
        static let iconLargeRadius: CGFloat = 7
    }

    enum Material {
        static let sidebar = NSVisualEffectView.Material.sidebar
        static let voice = NSVisualEffectView.Material.hudWindow
        static let voiceTint = Color.black.opacity(0.55)
    }

    enum Motion {
        static let fast = Animation.easeOut(duration: 0.12)
        static let base = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.20)
        static let spring = Animation.spring(response: 0.42, dampingFraction: 0.78)
        static let enter = Animation.spring(duration: 0.34)
        static let exit = Animation.easeIn(duration: 0.20)
        static let pop = Animation.spring(duration: 0.38, bounce: 0.3)
        static let reduced = Animation.linear(duration: 0.15)

        static func accessible(_ animation: Animation, reduceMotion: Bool) -> Animation {
            reduceMotion ? reduced : animation
        }
    }

    struct Shadow {
        let color: Color
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat
    }
    static let voiceShadows = [
        Shadow(color: .black.opacity(0.30), radius: 36, x: 0, y: 14),
        Shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 3)
    ]
    static let voiceInnerStroke = Color.white.opacity(0.14)

    private static func color(_ light: Int, _ dark: Int, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255,
                alpha: isDark ? darkAlpha : lightAlpha
            )
        })
    }
}
