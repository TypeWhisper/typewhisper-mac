import SwiftUI

struct SupporterBadgeView: View {
    let tier: SupporterTier

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: tierIcon)
                .foregroundStyle(tierColor)
            Text(tierName)
                .font(.caption.bold())
                .foregroundStyle(tierColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tierColor.opacity(0.12), in: Capsule())
    }

    private var tierIcon: String {
        switch tier {
        case .bronze: return "heart.fill"
        case .silver: return "star.fill"
        case .gold: return "crown.fill"
        }
    }

    private var tierName: String {
        switch tier {
        case .bronze: return String(localized: "Bronze Supporter")
        case .silver: return String(localized: "Silver Supporter")
        case .gold: return String(localized: "Gold Supporter")
        }
    }

    private var tierColor: Color {
        switch tier {
        case .bronze: return Color(red: 0.804, green: 0.498, blue: 0.196) // #CD7F32
        case .silver: return Color(red: 0.753, green: 0.753, blue: 0.753) // #C0C0C0
        case .gold: return Color(red: 1.0, green: 0.843, blue: 0.0) // #FFD700
        }
    }
}
