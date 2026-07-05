import Foundation
import SwiftData

@Model
final class UsageStatisticsMetadata {
    @Attribute(.unique)
    var key: String
    var value: String

    init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}
