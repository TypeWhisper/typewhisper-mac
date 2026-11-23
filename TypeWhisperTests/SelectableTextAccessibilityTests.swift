import Foundation
import XCTest

/// `.textSelection(.enabled)` backs a text with an AppKit element. An accessibility label or value
/// in the same modifier chain makes SwiftUI resolve the label through that element, which asks
/// SwiftUI for it again, so an accessibility client reading the text overflows the main thread's
/// stack (#2004, the Recorder's line for a failed transcript). Such text takes its label through
/// `selectableTextAccessibilityLabel(_:value:)`, which puts it on a container instead.
final class SelectableTextAccessibilityTests: XCTestCase {
    private static let forbiddenModifiers = [
        ".accessibilityLabel(",
        ".accessibilityValue(",
        ".accessibilityElement(",
        ".accessibilityAddTraits(",
        ".accessibilityHint(",
        ".accessibilityLabeledPair(",
        ".accessibilityRepresentation",
    ]

    func testSelectableTextKeepsAccessibilityModifiersOffItsModifierChain() throws {
        let sourceRoot = repositoryRoot.appendingPathComponent("TypeWhisper")
        var findings: [String] = []
        var checkedChains = 0

        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains(".textSelection(.enabled)") {
                checkedChains += 1
                for modifier in Self.modifiers(inChainAround: index, of: lines)
                where Self.forbiddenModifiers.contains(where: modifier.hasPrefix) {
                    findings.append("\(url.lastPathComponent):\(index + 1): \(modifier)")
                }
            }
        }

        XCTAssertGreaterThan(checkedChains, 0, "The scan found no selectable text; check the source path.")
        XCTAssertEqual(findings, [], "Give this text its label with selectableTextAccessibilityLabel(_:value:).")
    }

    func testChainScanSeesModifiersOnTheSameAndTheFollowingLines() {
        let lines = [
            "Label(summary, systemImage: \"exclamationmark.triangle.fill\")",
            "    .foregroundStyle(.red)",
            "    .textSelection(.enabled)",
            "    .accessibilityLabel(localizedAppText(",
            "        \"Error\",",
            "        de: \"Fehler\"",
            "    ))",
            "    .accessibilityValue(value)",
            "Text(error).font(.caption).textSelection(.enabled)",
        ]

        XCTAssertEqual(Self.modifiers(inChainAround: 2, of: lines), [
            ".foregroundStyle(.red)",
            ".textSelection(.enabled)",
            ".accessibilityLabel(localizedAppText(\"Error\",de: \"Fehler\"))",
            ".accessibilityValue(value)",
        ])
        XCTAssertEqual(Self.modifiers(inChainAround: 8, of: lines), [
            ".font(.caption)",
            ".textSelection(.enabled)",
        ])
    }

    /// The top-level modifiers of the expression that line `index` belongs to. The expression starts
    /// at the nearest line above that does not begin with `.` and ends before the first later line
    /// that neither begins with `.` nor continues an open argument list.
    private static func modifiers(inChainAround index: Int, of lines: [String]) -> [String] {
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }

        var first = index
        while first > 0, trimmed[first].hasPrefix(".") {
            first -= 1
        }

        var chain = ""
        var depth = 0
        var lineIndex = first
        while lineIndex < trimmed.count {
            let line = trimmed[lineIndex]
            if lineIndex > first, depth == 0, !line.hasPrefix(".") { break }
            chain += line + "\n"
            for character in line {
                if character == "(" { depth += 1 } else if character == ")" { depth = max(0, depth - 1) }
            }
            lineIndex += 1
        }

        var modifiers: [String] = []
        var current: String?
        var previous: Character = "\n"
        depth = 0
        for character in chain {
            if depth == 0, character == ".", previous == ")" || previous == "\n" {
                if let current { modifiers.append(current) }
                current = ""
            }
            if character == "(" { depth += 1 } else if character == ")" { depth = max(0, depth - 1) }
            if character != "\n" { current?.append(character) }
            if character != " " { previous = character }
        }
        if let current { modifiers.append(current) }
        return modifiers
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
