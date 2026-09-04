import CryptoKit
import Darwin
import Foundation

@main
struct PerformanceBenchmark {
    @MainActor
    static func main() throws {
        let name = CommandLine.arguments[1]
        let directory = URL(fileURLWithPath: CommandLine.arguments[2])
        let loader = PunctuationRulesLoader { language in
            try? Data(contentsOf: directory.appendingPathComponent("\(language).json"))
        }
        let punctuation = SpeechPunctuationService(rulesLoader: loader)
        let diff = TextDiffService()

        if name == "verify" {
            var digest = SHA256()
            var checks = 0
            // Repeated words exercise the existing LCS tie-breaking policy.
            var sequences = [""]
            var level = [""]
            for _ in 0..<4 {
                level = level.flatMap { prefix in ["a", "b", "🌍"].map { prefix.isEmpty ? $0 : prefix + " " + $0 } }
                sequences.append(contentsOf: level)
            }
            for original in sequences {
                for processed in sequences {
                    let result = diff.computeWordDiff(original: original, processed: processed)
                    let left = result.compactMap { segment -> String? in
                        switch segment { case .unchanged(let word), .removed(let word): word; case .added: nil }
                    }.joined(separator: " ")
                    let right = result.compactMap { segment -> String? in
                        switch segment { case .unchanged(let word), .added(let word): word; case .removed: nil }
                    }.joined(separator: " ")
                    precondition(left == original && right == processed)
                    digest.update(data: serialize(result))
                    checks += 1
                }
            }
            for language in ["de", "en", "it", "ja"] {
                let rules = loader.ruleSet(for: language)!
                for scenario in rules.verificationScenarios {
                    precondition(punctuation.normalize(text: scenario.spoken, language: language) == scenario.expected)
                    checks += 1
                }
                for rule in rules.rules {
                    for padding in [" ", "  ", "\t", "\n", "\r\n", "\u{00a0}", String(repeating: " ", count: 50)] {
                        for body in [rule.phrase, rule.phrase.uppercased(), "word\(rule.phrase)word",
                                     "🌍\(padding)\(rule.phrase)\(padding)世界", "(\(padding)\(rule.phrase)\(padding))",
                                     "\(rule.replacement)\(padding)\(rule.phrase)", "\(rule.phrase)\(padding)\(rule.replacement)",
                                     "\(rule.phrase)\(padding)\(rule.phrase)"] {
                            for mode in [PunctuationApplicationMode.fullFallback, .selectiveFallback] {
                                let result = punctuation.normalize(text: body, language: language, mode: mode)
                                digest.update(data: Data(result.utf8))
                                digest.update(data: Data([0]))
                                checks += 1
                            }
                        }
                    }
                }
                // Aliases must share semantics; alternating languages must not reuse stale rules.
                precondition(punctuation.normalize(text: rules.rules[0].phrase, language: language + "-XX") ==
                             punctuation.normalize(text: rules.rules[0].phrase, language: language))
            }
            for rate in [8_000, 16_000, 44_100, 48_000] {
                for samples: [Float] in [[], [0], [-2, -1, -0.5, 0, 0.5, 1, 2, .infinity, -.infinity],
                                        (0..<10001).map { Float($0 % 199 - 99) / 87 }] {
                    let data = WavEncoder.encode(samples, sampleRate: rate)
                    precondition(data == PluginWavEncoder.encode(samples, sampleRate: rate))
                    precondition(data.count == 44 + samples.count * 2)
                    for (index, sample) in samples.enumerated() {
                        let expected = UInt16(bitPattern: Int16(max(-1, min(1, sample)) * 32767))
                        precondition(data[44 + index * 2] == UInt8(truncatingIfNeeded: expected))
                        precondition(data[45 + index * 2] == UInt8(truncatingIfNeeded: expected >> 8))
                    }
                    digest.update(data: data)
                    checks += 1
                }
            }
            emit(["case": name, "checks": checks, "digest": hex(digest.finalize())])
            return
        }

        let operation: () -> Data
        let iterations: Int
        if name == "plugin-sort-64" {
            let manager = PluginSortingFixture()
            let root = directory.appendingPathComponent("plugins")
            var urls: [URL] = []
            for index in 0..<64 {
                let shuffled = (index * 37) % 64
                let url = root.appendingPathComponent(String(format: "%03d.bundle", shuffled))
                let resources = url.appendingPathComponent("Contents/Resources")
                try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
                let id = "benchmark.performance.\(shuffled)"
                UserDefaults.standard.register(defaults: ["plugin.\(id).enabled": shuffled % 3 == 0])
                if shuffled % 8 != 0 {
                    let manifest = PluginManifest(id: id, name: id, version: "1.0.0", principalClass: "Plugin")
                    try JSONEncoder().encode(manifest).write(to: resources.appendingPathComponent("manifest.json"))
                }
                urls.append(url)
            }
            // Exercise malformed/missing manifests, both default enabled states,
            // ordering ties, and repeated URLs without loading plugin code.
            urls.append(urls[0])
            operation = {
                var output = ""
                for bundled in [false, true] {
                    output += manager.sortedPluginBundleURLs(urls, isBundledSource: bundled)
                        .map(\.lastPathComponent).joined(separator: "\n")
                }
                return Data(output.utf8)
            }
            iterations = 5
        } else if name.hasPrefix("wav-") {
            let seconds = name.hasSuffix("600s") ? 600 : name.hasSuffix("60s") ? 60 : 10
            let samples = (0..<(16_000 * seconds)).map { Float($0 % 201 - 100) / 90 }
            operation = name.hasPrefix("wav-app") ? { WavEncoder.encode(samples) } : { PluginWavEncoder.encode(samples) }
            iterations = 1
        } else if name.hasPrefix("diff-") {
            let words = (0..<2000).map { "word\($0 % 97)" }
            let original = words.joined(separator: " ")
            var edited = words
            switch name {
            case "diff-middle-edit": edited[1000] = "corrected"
            case "diff-last-edit": edited[1999] = "corrected"
            case "diff-rewrite": edited = (0..<2000).map { "replacement\($0 % 101)" }
            default: break
            }
            let processed = edited.joined(separator: " ")
            operation = { serialize(diff.computeWordDiff(original: original, processed: processed)) }
            iterations = 1
        } else {
            let text: String
            switch name {
            case "punctuation-long": text = String(repeating: "Hallo Komma Welt Punkt Das ist ein Test Fragezeichen ", count: 100)
            case "punctuation-spaces": text = "Hallo" + String(repeating: " ", count: 4000) + "Welt"
            default: text = "Hallo Komma Welt Punkt Das ist ein Test Fragezeichen"
            }
            if name == "punctuation-cold" {
                operation = {
                    let freshLoader = PunctuationRulesLoader { language in
                        try? Data(contentsOf: directory.appendingPathComponent("\(language).json"))
                    }
                    return Data(SpeechPunctuationService(rulesLoader: freshLoader).normalize(text: text, language: "de").utf8)
                }
            } else {
                operation = { Data(punctuation.normalize(text: text, language: "de").utf8) }
            }
            iterations = name == "punctuation-short" ? 100 : name == "punctuation-cold" ? 20 : 1
        }

        // Input creation, compilation and output hashing are outside timed regions.
        // Each case runs in a fresh process; RSS includes inputs and runtime overhead.
        let expected = autoreleasepool(invoking: operation)
        precondition(autoreleasepool(invoking: operation) == expected)
        var timings: [Double] = []
        var checksum = 0
        for _ in 0..<9 {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<iterations {
                checksum &+= autoreleasepool { consume(operation()) }
            }
            timings.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 / Double(iterations))
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        emit(["case": name, "median_ms": timings.sorted()[4], "samples_ms": timings,
              "iterations_per_sample": iterations, "peak_rss_bytes": usage.ru_maxrss,
              "digest": hex(SHA256.hash(data: expected)), "checksum": checksum])
    }

    @inline(never)
    static func consume(_ data: Data) -> Int {
        data.count &+ Int(data.first ?? 0) &+ Int(data.last ?? 0)
    }

    static func serialize(_ segments: [DiffSegment]) -> Data {
        var result = Data()
        for segment in segments {
            switch segment {
            case .unchanged(let text): result.append(contentsOf: ("=\(text)\u{0}").utf8)
            case .removed(let text): result.append(contentsOf: ("-\(text)\u{0}").utf8)
            case .added(let text): result.append(contentsOf: ("+\(text)\u{0}").utf8)
            }
        }
        return result
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func emit(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
