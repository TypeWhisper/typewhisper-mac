import XCTest
@testable import TypeWhisper

final class LocalTermPackFileTests: XCTestCase {
    func testDecodesRegistryFormatWithMetadataTermsAndCorrections() throws {
        let file = try LocalTermPackFile.decode(Self.packJSON(extra: """
          "names": { "de": "Team-Begriffe", "ja": "  " },
          "descriptions": { "de": "Begriffe aus dem Team" },
        """))

        XCTAssertEqual(file.id, "team-terms")
        XCTAssertEqual(file.name, "Team Terms")
        XCTAssertEqual(file.description, "Words our team uses")
        XCTAssertEqual(file.icon, "person.3")
        XCTAssertEqual(file.version, "1.2.0")
        XCTAssertEqual(file.author, "Dana")
        XCTAssertEqual(file.terms, ["Kubernetes", "TypeWhisper"])
        XCTAssertEqual(file.corrections, [
            TermPackCorrection(original: "type whisper", replacement: "TypeWhisper", caseSensitive: false),
        ])
        XCTAssertEqual(file.names, ["de": "Team-Begriffe"])
        XCTAssertEqual(file.descriptions, ["de": "Begriffe aus dem Team"])

        let pack = file.termPack
        XCTAssertEqual(pack.source, .local)
        XCTAssertEqual(pack.entryCount, 3)
        XCTAssertFalse(pack.requiresCommercialLicense)
    }

    func testCommunityPackFilesInTheRepositoryImportAsLocalPacks() throws {
        let directory = TestSupport.repoRoot.appendingPathComponent("termpacks", isDirectory: true)
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertFalse(urls.isEmpty)

        for url in urls {
            let data = try Data(contentsOf: url)
            let file = try LocalTermPackFile.decode(data)
            let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(file.id, raw["id"] as? String, url.lastPathComponent)
            XCTAssertEqual(file.terms.count, (raw["terms"] as? [Any])?.count ?? 0, url.lastPathComponent)
            XCTAssertEqual(file.corrections.count, (raw["corrections"] as? [Any])?.count ?? 0, url.lastPathComponent)
        }
    }

    func testMalformedAndWrongShapeFilesFailClearly() {
        XCTAssertThrowsError(try LocalTermPackFile.decode(Data("{ \"id\": ".utf8))) {
            XCTAssertEqual($0 as? LocalTermPackError, .malformedJSON)
        }
        XCTAssertThrowsError(try LocalTermPackFile.decode(Data())) {
            XCTAssertEqual($0 as? LocalTermPackError, .malformedJSON)
        }
        // A dictionary export is a list of entries.
        XCTAssertThrowsError(try LocalTermPackFile.decode(Data("[{\"type\": \"term\", \"original\": \"Rust\"}]".utf8))) {
            XCTAssertEqual($0 as? LocalTermPackError, .listInsteadOfPack)
        }
        XCTAssertThrowsError(try LocalTermPackFile.decode(Data("\"team-terms\"".utf8))) {
            XCTAssertEqual($0 as? LocalTermPackError, .notATermPack)
        }
        XCTAssertThrowsError(try LocalTermPackFile.decode(Data(repeating: 0x20, count: LocalTermPackFile.maximumFileSize + 1))) {
            XCTAssertEqual($0 as? LocalTermPackError, .fileTooLarge)
        }
        XCTAssertNotNil(LocalTermPackError.malformedJSON.errorDescription)
    }

    func testErrorMessagesShortenLongValuesFromTheFile() {
        let longID = String(repeating: "x", count: 500)
        let message = LocalTermPackError.invalidID(longID).localizedDescription

        XCTAssertFalse(message.contains(longID))
        XCTAssertTrue(message.contains(String(repeating: "x", count: 80) + "…"))
        XCTAssertTrue(LocalTermPackError.duplicateTerm("Tokio").localizedDescription.contains("Tokio"))
    }

    func testEmptyPacksFail() {
        XCTAssertThrowsError(try LocalTermPackFile.decode(Self.packJSON(terms: "[]", corrections: "[]"))) {
            XCTAssertEqual($0 as? LocalTermPackError, .emptyPack("Team Terms"))
        }
        XCTAssertThrowsError(try LocalTermPackFile.decode(Self.packJSON(terms: nil, corrections: nil))) {
            XCTAssertEqual($0 as? LocalTermPackError, .emptyPack("Team Terms"))
        }
    }

    func testRequiredMetadataIsChecked() {
        for field in ["id", "name", "description", "icon", "version", "author"] {
            var object = Self.packObject()
            object.removeValue(forKey: field)
            XCTAssertThrowsError(try LocalTermPackFile.decode(Self.data(object)), field) {
                XCTAssertEqual($0 as? LocalTermPackError, .missingField(field))
            }

            object[field] = "   "
            XCTAssertThrowsError(try LocalTermPackFile.decode(Self.data(object)), field) {
                let expected: LocalTermPackError = field == "id" ? .invalidID("   ") : .missingField(field)
                XCTAssertEqual($0 as? LocalTermPackError, expected)
            }

            object[field] = 3
            XCTAssertThrowsError(try LocalTermPackFile.decode(Self.data(object)), field) {
                XCTAssertEqual($0 as? LocalTermPackError, .invalidField(field))
            }
        }

        var object = Self.packObject()
        object["names"] = ["de": 1]
        XCTAssertThrowsError(try LocalTermPackFile.decode(Self.data(object))) {
            XCTAssertEqual($0 as? LocalTermPackError, .invalidField("names"))
        }
    }

    func testIDsAndVersionsFollowTheRegistryRules() {
        for id in ["team-terms", "a", "web3", "rust-2024-ed"] {
            XCTAssertTrue(LocalTermPackFile.isValidID(id), id)
        }
        for id in ["Team-Terms", "team terms", "team_terms", "-team", "team-", "team--terms", "../team", "tëam",
                   String(repeating: "a", count: LocalTermPackFile.maximumIDLength + 1)] {
            XCTAssertFalse(LocalTermPackFile.isValidID(id), id)
        }
        for version in ["1.0", "1.0.0", "10.20.30.40"] {
            XCTAssertTrue(LocalTermPackFile.isValidVersion(version), version)
        }
        for version in ["1", "1.", ".1", "1..0", "v1.0", "1.0-beta", "1.a"] {
            XCTAssertFalse(LocalTermPackFile.isValidVersion(version), version)
        }

        var object = Self.packObject()
        object["id"] = "Team Terms"
        XCTAssertThrowsError(try LocalTermPackFile.decode(Self.data(object))) {
            XCTAssertEqual($0 as? LocalTermPackError, .invalidID("Team Terms"))
        }
        object = Self.packObject()
        object["version"] = "1"
        XCTAssertThrowsError(try LocalTermPackFile.decode(Self.data(object))) {
            XCTAssertEqual($0 as? LocalTermPackError, .invalidVersion("1"))
        }
    }

    func testInvalidAndDuplicateEntriesFail() {
        let cases: [(terms: String?, corrections: String?, error: LocalTermPackError)] = [
            ("\"Rust\"", nil, .invalidField("terms")),
            ("[\"Rust\", 3]", nil, .invalidTerm(position: 2)),
            ("[\"Rust\", \"  \"]", nil, .invalidTerm(position: 2)),
            ("[\"Rust\", \"rust \"]", nil, .duplicateTerm("rust")),
            (nil, "{}", .invalidField("corrections")),
            (nil, "[{\"original\": \"teh\"}]", .invalidCorrection(position: 1)),
            (nil, "[{\"original\": \" \", \"replacement\": \"the\"}]", .invalidCorrection(position: 1)),
            (nil, "[{\"original\": \"teh\", \"replacement\": \"the\", \"caseSensitive\": \"no\"}]", .invalidCorrection(position: 1)),
            (nil, "[{\"original\": \"teh\", \"replacement\": \"the\"}, {\"original\": \"Teh\", \"replacement\": \"The\"}]", .duplicateCorrection("Teh")),
        ]
        for testCase in cases {
            XCTAssertThrowsError(
                try LocalTermPackFile.decode(Self.packJSON(terms: testCase.terms, corrections: testCase.corrections)),
                "\(testCase.error)"
            ) {
                XCTAssertEqual($0 as? LocalTermPackError, testCase.error)
            }
        }
    }

    func testTrimsTextAndDefaultsCorrectionsToCaseSensitive() throws {
        let file = try LocalTermPackFile.decode(Self.packJSON(
            terms: "[\"  Tokio \\n\"]",
            corrections: "[{\"original\": \" um \", \"replacement\": \"\"}]"
        ))

        XCTAssertEqual(file.terms, ["Tokio"])
        // An empty replacement removes the word, as in the dictionary.
        XCTAssertEqual(file.corrections, [TermPackCorrection(original: "um", replacement: "", caseSensitive: true)])
    }

    func testAcceptsByteOrderMark() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + Self.packJSON()
        XCTAssertEqual(try LocalTermPackFile.decode(data).id, "team-terms")
    }

    func testExportedJSONDecodesToTheSamePackInTheRegistryFormat() throws {
        let file = try LocalTermPackFile.decode(Self.packJSON(extra: """
          "names": { "de": "Team-Begriffe" },
        """))

        let exported = try file.encodedData()
        XCTAssertEqual(try LocalTermPackFile.decode(exported), file)
        XCTAssertEqual(try file.encodedData(), exported, "Exports are stable")

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: exported) as? [String: Any])
        XCTAssertEqual(
            Set(object.keys),
            ["id", "name", "description", "names", "icon", "version", "author", "terms", "corrections"]
        )
        let correction = try XCTUnwrap((object["corrections"] as? [[String: Any]])?.first)
        XCTAssertEqual(correction["caseSensitive"] as? Bool, false)
        XCTAssertEqual(exported.last, 0x0A)

        // A pack without corrections leaves the key out, like the registry files.
        let termsOnly = try LocalTermPackFile.decode(Self.packJSON(corrections: nil))
        let termsOnlyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: termsOnly.encodedData()) as? [String: Any]
        )
        XCTAssertNil(termsOnlyObject["corrections"])
        XCTAssertNil(termsOnlyObject["names"])
    }

    // MARK: - Fixtures

    static func packObject(
        id: String = "team-terms",
        name: String = "Team Terms",
        version: String = "1.2.0"
    ) -> [String: Any] {
        [
            "id": id,
            "name": name,
            "description": "Words our team uses",
            "icon": "person.3",
            "version": version,
            "author": "Dana",
            "terms": ["Kubernetes", "TypeWhisper"],
        ]
    }

    static func data(_ object: [String: Any]) -> Data {
        // Fixtures are plain dictionaries; serialization cannot fail.
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// A pack file as a user writes it; `terms` and `corrections` are raw JSON or left out when nil.
    static func packJSON(
        id: String = "team-terms",
        name: String = "Team Terms",
        version: String = "1.2.0",
        terms: String? = "[\"Kubernetes\", \" TypeWhisper\"]",
        corrections: String? = "[{\"original\": \"type whisper\", \"replacement\": \"TypeWhisper\", \"caseSensitive\": false}]",
        extra: String = ""
    ) -> Data {
        var lines = [
            "{",
            extra,
            "  \"id\": \"\(id)\",",
            "  \"name\": \"\(name)\",",
            "  \"description\": \"Words our team uses\",",
            "  \"icon\": \"person.3\",",
            "  \"version\": \"\(version)\",",
        ]
        if let terms { lines.append("  \"terms\": \(terms),") }
        if let corrections { lines.append("  \"corrections\": \(corrections),") }
        lines.append("  \"author\": \"Dana\"")
        lines.append("}")
        return Data(lines.joined(separator: "\n").utf8)
    }
}

@MainActor
final class LocalTermPackStoreTests: XCTestCase {
    func testSavesLoadsReplacesAndRemovesPacks() throws {
        let directory = try TestSupport.makeTemporaryDirectory(prefix: "LocalTermPackStore")
        defer { TestSupport.remove(directory) }

        let store = LocalTermPackStore(directory: directory)
        XCTAssertTrue(store.packs.isEmpty)

        let first = try LocalTermPackFile.decode(LocalTermPackFileTests.packJSON(name: "Zulu Terms"))
        let second = try LocalTermPackFile.decode(LocalTermPackFileTests.packJSON(id: "alpha-terms", name: "Alpha Terms"))
        try store.save(first)
        try store.save(second)
        XCTAssertEqual(store.packs.map(\.id), ["alpha-terms", "team-terms"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("team-terms.json").path))

        let reloaded = LocalTermPackStore(directory: directory)
        XCTAssertEqual(reloaded.file(withID: "team-terms"), first)
        XCTAssertEqual(reloaded.pack(withID: "alpha-terms")?.source, .local)

        let replacement = try LocalTermPackFile.decode(LocalTermPackFileTests.packJSON(version: "2.0.0", terms: "[\"Helm\"]"))
        try reloaded.save(replacement)
        XCTAssertEqual(LocalTermPackStore(directory: directory).file(withID: "team-terms"), replacement)

        try reloaded.remove(id: "team-terms")
        XCTAssertNil(reloaded.pack(withID: "team-terms"))
        XCTAssertEqual(LocalTermPackStore(directory: directory).packs.map(\.id), ["alpha-terms"])
    }

    func testSkipsInvalidFilesAndLoadsEachIDOnce() throws {
        let directory = try TestSupport.makeTemporaryDirectory(prefix: "LocalTermPackStoreInvalid")
        defer { TestSupport.remove(directory) }

        let broken = directory.appendingPathComponent("broken.json")
        try Data("{".utf8).write(to: broken)
        let copy = directory.appendingPathComponent("a-copy.json")
        try LocalTermPackFileTests.packJSON(terms: "[\"Copy\"]").write(to: copy)
        try LocalTermPackFileTests.packJSON(terms: "[\"Original\"]").write(to: directory.appendingPathComponent("team-terms.json"))

        let store = LocalTermPackStore(directory: directory)
        XCTAssertEqual(store.packs.map(\.id), ["team-terms"])
        XCTAssertEqual(store.file(withID: "team-terms")?.terms, ["Original"])

        // Removing the pack deletes every copy, so it does not come back; invalid files stay.
        try store.remove(id: "team-terms")
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: broken.path))
        XCTAssertTrue(LocalTermPackStore(directory: directory).packs.isEmpty)
    }

    func testReplacingAPackFileNamedInAnotherCaseKeepsTheNewFile() throws {
        let directory = try TestSupport.makeTemporaryDirectory(prefix: "LocalTermPackStoreCase")
        defer { TestSupport.remove(directory) }

        // Copied in by hand; on a case-insensitive volume this is the same file as `team-terms.json`.
        try LocalTermPackFileTests.packJSON(terms: "[\"Original\"]")
            .write(to: directory.appendingPathComponent("Team-Terms.json"))
        let store = LocalTermPackStore(directory: directory)
        XCTAssertEqual(store.file(withID: "team-terms")?.terms, ["Original"])

        let replacement = try LocalTermPackFile.decode(LocalTermPackFileTests.packJSON(version: "2.0.0", terms: "[\"Replaced\"]"))
        try store.save(replacement)

        XCTAssertEqual(LocalTermPackStore(directory: directory).file(withID: "team-terms"), replacement)
        try store.remove(id: "team-terms")
        XCTAssertTrue(LocalTermPackStore(directory: directory).packs.isEmpty)
    }
}

@MainActor
final class LocalTermPackDictionaryTests: XCTestCase {
    func testImportAddsPackTurnedOffAndTogglingAddsAndRemovesOnlyItsEntries() throws {
        let fixture = try makeFixture()
        fixture.service.addEntry(type: .term, original: "Rust")
        fixture.viewModel.activatePack(try XCTUnwrap(TermPack.allPacks.first { $0.id == "ios-macos" }))
        let entriesBefore = Set(fixture.service.entries.map(\.original))

        fixture.viewModel.importLocalTermPack(data: LocalTermPackFileTests.packJSON(
            terms: "[\"Rust\", \"SwiftUI\", \"Tokio\"]",
            corrections: "[{\"original\": \"teh\", \"replacement\": \"the\", \"caseSensitive\": false}]"
        ))

        XCTAssertNil(fixture.viewModel.localTermPackImportError)
        XCTAssertNotNil(fixture.viewModel.importMessage)
        let pack = try XCTUnwrap(fixture.viewModel.visibleLocalPacks.first)
        XCTAssertEqual(pack.id, "team-terms")
        XCTAssertFalse(fixture.viewModel.isPackActivated(pack))
        XCTAssertEqual(Set(fixture.service.entries.map(\.original)), entriesBefore)

        fixture.viewModel.togglePack(pack)

        XCTAssertTrue(fixture.viewModel.isPackActivated(pack))
        XCTAssertEqual(fixture.viewModel.activatedPackStates[pack.id]?.source, "local")
        // The manual "Rust" and the built-in pack's "SwiftUI" keep their owners.
        XCTAssertEqual(fixture.viewModel.activatedPackStates[pack.id]?.installedTerms, ["Tokio"])
        XCTAssertEqual(Set(fixture.service.entries.map(\.original)), entriesBefore.union(["Tokio", "teh"]))
        XCTAssertEqual(fixture.service.entries.first { $0.original == "teh" }?.replacement, "the")

        fixture.viewModel.togglePack(pack)

        XCTAssertFalse(fixture.viewModel.isPackActivated(pack))
        XCTAssertEqual(Set(fixture.service.entries.map(\.original)), entriesBefore)
        XCTAssertTrue(fixture.viewModel.isPackActivated(try XCTUnwrap(TermPack.allPacks.first { $0.id == "ios-macos" })))
    }

    func testImportNeverTakesOverBuiltInOrCommunityIDs() throws {
        let fixture = try makeFixture()
        fixture.registry.communityPacks = [makeCommunityPack(id: "rust-dev", terms: ["Cargo"])]
        let webDev = try XCTUnwrap(TermPack.allPacks.first { $0.id == "web-dev" })
        fixture.viewModel.activatePack(webDev)
        let statesBefore = fixture.viewModel.activatedPackStates.mapValues(\.installedTerms)
        let entriesBefore = fixture.service.entries.map(\.id)

        let attempts: [(id: String, error: LocalTermPackError)] = [
            ("web-dev", .builtInID("web-dev")),
            ("rust-dev", .communityID("rust-dev")),
            // Commercial industry packs are registry packs even before the registry loads.
            ("legal", .communityID("legal")),
        ]
        for attempt in attempts {
            fixture.viewModel.importLocalTermPack(data: LocalTermPackFileTests.packJSON(id: attempt.id, terms: "[\"Overwrite\"]"))
            XCTAssertEqual(fixture.viewModel.localTermPackImportError, attempt.error.localizedDescription, attempt.id)
            fixture.viewModel.clearLocalTermPackImportError()
        }

        XCTAssertTrue(fixture.store.packs.isEmpty)
        XCTAssertNil(fixture.viewModel.pendingLocalTermPackReplacement)
        XCTAssertEqual(fixture.viewModel.activatedPackStates.mapValues(\.installedTerms), statesBefore)
        XCTAssertEqual(fixture.service.entries.map(\.id), entriesBefore)
        XCTAssertFalse(fixture.service.entries.contains { $0.original == "Overwrite" })
    }

    func testCommunityPackThatIsOnWhileTheRegistryIsOfflineKeepsItsID() throws {
        let fixture = try makeFixture()
        fixture.registry.communityPacks = [makeCommunityPack(id: "rust-dev", terms: ["Cargo"])]
        fixture.viewModel.activatePack(try XCTUnwrap(fixture.registry.communityPacks.first))
        fixture.registry.communityPacks = []

        fixture.viewModel.importLocalTermPack(data: LocalTermPackFileTests.packJSON(id: "rust-dev"))

        XCTAssertEqual(fixture.viewModel.localTermPackImportError, LocalTermPackError.communityID("rust-dev").localizedDescription)
        XCTAssertEqual(fixture.viewModel.activatedPackStates["rust-dev"]?.source, "community")
        XCTAssertTrue(fixture.store.packs.isEmpty)
    }

    func testMalformedOrEmptyFilesShowAnErrorAndStoreNothing() throws {
        let fixture = try makeFixture()

        fixture.viewModel.importLocalTermPack(data: Data("{ not json".utf8))
        XCTAssertEqual(fixture.viewModel.localTermPackImportError, LocalTermPackError.malformedJSON.localizedDescription)
        fixture.viewModel.clearLocalTermPackImportError()

        fixture.viewModel.importLocalTermPack(data: LocalTermPackFileTests.packJSON(terms: "[]", corrections: nil))
        XCTAssertEqual(fixture.viewModel.localTermPackImportError, LocalTermPackError.emptyPack("Team Terms").localizedDescription)

        let missingFile = fixture.directory.appendingPathComponent("missing.json")
        fixture.viewModel.importLocalTermPack(from: missingFile)
        XCTAssertEqual(fixture.viewModel.localTermPackImportError, LocalTermPackError.unreadableFile.localizedDescription)

        XCTAssertTrue(fixture.store.packs.isEmpty)
        XCTAssertNil(fixture.viewModel.importMessage)
        XCTAssertTrue(fixture.service.entries.isEmpty)
    }

    func testDictionaryImportOfATermPackFileAddsItAsALocalPack() throws {
        let fixture = try makeFixture()

        fixture.viewModel.importDictionary(data: LocalTermPackFileTests.packJSON())

        XCTAssertNil(fixture.viewModel.error)
        XCTAssertNil(fixture.viewModel.localTermPackImportError)
        XCTAssertNotNil(fixture.viewModel.importMessage)
        XCTAssertEqual(fixture.viewModel.visibleLocalPacks.map(\.id), ["team-terms"])
        XCTAssertEqual(fixture.viewModel.filterTab, .termPacks)
        XCTAssertTrue(fixture.service.entries.isEmpty)

        // Other JSON objects are still not a dictionary.
        fixture.viewModel.importDictionary(data: Data("{\"name\": \"Not a pack\"}".utf8))

        XCTAssertEqual(fixture.viewModel.error, DictionaryImportError.invalidFormat.localizedDescription)
        XCTAssertEqual(fixture.store.packs.count, 1)
    }

    func testImportingTheSameIDAgainAsksFirstAndUpdatesAnActivePack() throws {
        let fixture = try makeFixture()
        fixture.viewModel.importLocalTermPack(data: LocalTermPackFileTests.packJSON(terms: "[\"Alpha\", \"Beta\"]", corrections: nil))
        let original = try XCTUnwrap(fixture.viewModel.visibleLocalPacks.first)
        fixture.viewModel.activatePack(original)
        let beta = try XCTUnwrap(fixture.service.entries.first { $0.original == "Beta" })
        fixture.service.setEntryEnabled(beta, enabled: false)
        fixture.viewModel.clearImportMessage()

        let update = LocalTermPackFileTests.packJSON(name: "Team Terms 2", version: "2.0.0", terms: "[\"Alpha\", \"Beta\", \"Gamma\"]", corrections: nil)
        fixture.viewModel.importLocalTermPack(data: update)

        let replacement = try XCTUnwrap(fixture.viewModel.pendingLocalTermPackReplacement)
        XCTAssertEqual(replacement.existingName, "Team Terms")
        XCTAssertEqual(replacement.id, "team-terms")
        XCTAssertEqual(fixture.store.file(withID: "team-terms")?.version, "1.2.0")

        fixture.viewModel.cancelLocalTermPackReplacement()
        XCTAssertNil(fixture.viewModel.pendingLocalTermPackReplacement)
        XCTAssertEqual(fixture.store.file(withID: "team-terms")?.version, "1.2.0")
        XCTAssertFalse(fixture.service.entries.contains { $0.original == "Gamma" })

        fixture.viewModel.importLocalTermPack(data: update)
        fixture.viewModel.confirmLocalTermPackReplacement()

        XCTAssertNil(fixture.viewModel.pendingLocalTermPackReplacement)
        XCTAssertEqual(fixture.store.file(withID: "team-terms")?.version, "2.0.0")
        XCTAssertEqual(fixture.viewModel.visibleLocalPacks.map(\.name), ["Team Terms 2"])
        XCTAssertEqual(fixture.viewModel.activatedPackStates["team-terms"]?.installedVersion, "2.0.0")
        XCTAssertEqual(Set(fixture.service.entries.map(\.original)), ["Alpha", "Beta", "Gamma"])
        XCTAssertEqual(fixture.service.entries.first { $0.original == "Beta" }?.isEnabled, false)
        XCTAssertNotNil(fixture.viewModel.importMessage)
    }

    func testConfirmingAReplacementRechecksIDsLoadedMeanwhile() throws {
        let fixture = try makeFixture()
        fixture.viewModel.importLocalTermPack(data: LocalTermPackFileTests.packJSON())
        fixture.viewModel.importLocalTermPack(data: LocalTermPackFileTests.packJSON(version: "2.0.0"))
        XCTAssertNotNil(fixture.viewModel.pendingLocalTermPackReplacement)

        fixture.registry.communityPacks = [makeCommunityPack(id: "team-terms", terms: ["Registry"])]
        fixture.viewModel.confirmLocalTermPackReplacement()

        XCTAssertEqual(fixture.viewModel.localTermPackImportError, LocalTermPackError.communityID("team-terms").localizedDescription)
        XCTAssertEqual(fixture.store.file(withID: "team-terms")?.version, "1.2.0")
    }

    func testLocalAndCommunityPacksWithTheSameIDStayApart() throws {
        let fixture = try makeFixture()
        fixture.viewModel.importLocalTermPack(data: LocalTermPackFileTests.packJSON(id: "shared-id", terms: "[\"LocalOnly\", \"Shared\"]", corrections: nil))
        let local = try XCTUnwrap(fixture.viewModel.visibleLocalPacks.first)
        fixture.viewModel.activatePack(local)

        // A community pack published later with the same ID.
        let community = makeCommunityPack(id: "shared-id", terms: ["Shared", "CommunityOnly"])
        fixture.registry.communityPacks = [community]

        XCTAssertEqual(fixture.viewModel.localPackConflict(for: local), .community)
        XCTAssertNil(fixture.viewModel.localPackConflict(for: community))
        XCTAssertTrue(fixture.viewModel.isPackActivated(local))
        XCTAssertFalse(fixture.viewModel.isPackActivated(community))
        XCTAssertFalse(fixture.viewModel.hasUpdate(for: community))

        // The local pack can be turned off, but not on again while the ID is taken.
        fixture.viewModel.togglePack(local)
        XCTAssertFalse(fixture.viewModel.isPackActivated(local))
        XCTAssertFalse(fixture.service.entries.contains { $0.original == "LocalOnly" })
        fixture.viewModel.togglePack(local)
        XCTAssertFalse(fixture.viewModel.isPackActivated(local))
        XCTAssertEqual(fixture.viewModel.error, LocalTermPackError.communityID("shared-id").localizedDescription)
        fixture.viewModel.clearError()

        // Turning the community pack on works as before.
        fixture.viewModel.togglePack(community)
        XCTAssertTrue(fixture.viewModel.isPackActivated(community))
        XCTAssertFalse(fixture.viewModel.isPackActivated(local))
        XCTAssertEqual(Set(fixture.service.entries.map(\.original)), ["Shared", "CommunityOnly"])
    }

    func testCommunityPacksClaimSharedEntriesBeforeLocalPacks() throws {
        let fixture = try makeFixture()
        let community = makeCommunityPack(id: "zz-community", terms: ["Shared", "CommunityOnly"])
        fixture.registry.communityPacks = [community]
        fixture.viewModel.importLocalTermPack(data: LocalTermPackFileTests.packJSON(id: "aa-local", terms: "[\"Shared\", \"LocalOnly\"]", corrections: nil))
        let local = try XCTUnwrap(fixture.viewModel.visibleLocalPacks.first)

        fixture.viewModel.activatePack(local)
        fixture.viewModel.activatePack(community)

        // The order is by source, not by ID or by when a pack was turned on.
        XCTAssertEqual(fixture.viewModel.activatedPackStates["zz-community"]?.installedTerms, ["Shared", "CommunityOnly"])
        XCTAssertEqual(fixture.viewModel.activatedPackStates["aa-local"]?.installedTerms, ["LocalOnly"])
        XCTAssertEqual(fixture.service.entries.filter { $0.original == "Shared" }.count, 1)
    }

    func testActivationStateOfALocalPackMissingOnThisMacIsKeptAndHarmless() throws {
        let fixture = try makeFixture()
        fixture.service.addEntries([(type: .term, original: "Zeta", replacement: nil, caseSensitive: true)])
        let state = ActivatedTermPackState(
            packID: "other-mac-pack",
            source: "local",
            installedVersion: "1.0.0",
            installedTerms: ["Zeta"],
            installedCorrections: [],
            requiresCommercialLicense: false
        )
        fixture.defaults.set(try JSONEncoder().encode([state]), forKey: UserDefaultsKeys.activatedTermPackStates)

        let viewModel = makeViewModel(fixture)
        XCTAssertTrue(viewModel.visibleLocalPacks.isEmpty)
        XCTAssertNotNil(viewModel.activatedPackStates["other-mac-pack"])

        // Other packs can be turned on and off without dropping the state or its entries.
        let devOps = try XCTUnwrap(TermPack.allPacks.first { $0.id == "devops" })
        viewModel.activatePack(devOps)
        viewModel.deactivatePack(devOps)
        XCTAssertNotNil(viewModel.activatedPackStates["other-mac-pack"])
        XCTAssertTrue(fixture.service.entries.contains { $0.original == "Zeta" })
        XCTAssertNotNil(makeViewModel(fixture).activatedPackStates["other-mac-pack"])

        // Pack entries stay out of sync.
        let syncStore = TypeWhisperUserDataSyncStore(
            dictionaryService: fixture.service,
            snippetService: SnippetService(appSupportDirectory: fixture.directory),
            defaults: fixture.defaults
        )
        XCTAssertFalse(syncStore.snapshot().dictionaryEntries.contains { $0.original == "Zeta" })

        // Importing the pack here picks the state up and applies the file.
        viewModel.importLocalTermPack(data: LocalTermPackFileTests.packJSON(id: "other-mac-pack", terms: "[\"Zeta\", \"Eta\"]", corrections: nil))
        let pack = try XCTUnwrap(viewModel.visibleLocalPacks.first)
        XCTAssertTrue(viewModel.isPackActivated(pack))
        XCTAssertEqual(viewModel.activatedPackStates["other-mac-pack"]?.installedTerms, ["Zeta", "Eta"])
        XCTAssertTrue(fixture.service.entries.contains { $0.original == "Eta" })
    }

    func testActiveLocalPackEntriesAreNotSynced() throws {
        let fixture = try makeFixture()
        fixture.service.addEntry(type: .term, original: "ManualTerm")
        fixture.viewModel.importLocalTermPack(data: LocalTermPackFileTests.packJSON(terms: "[\"PrivateTerm\"]"))
        fixture.viewModel.activatePack(try XCTUnwrap(fixture.viewModel.visibleLocalPacks.first))

        let syncStore = TypeWhisperUserDataSyncStore(
            dictionaryService: fixture.service,
            snippetService: SnippetService(appSupportDirectory: fixture.directory),
            defaults: fixture.defaults
        )
        let synced = syncStore.snapshot().dictionaryEntries.map(\.original)
        XCTAssertTrue(synced.contains("ManualTerm"))
        XCTAssertFalse(synced.contains("PrivateTerm"))
        XCTAssertFalse(synced.contains("type whisper"))
    }

    func testExportedPackImportsOnAnotherMac() throws {
        let source = try makeFixture()
        source.viewModel.importLocalTermPack(data: LocalTermPackFileTests.packJSON(extra: """
          "names": { "de": "Team-Begriffe" },
        """))
        let exported = try XCTUnwrap(source.viewModel.exportedLocalTermPackData(id: "team-terms"))

        let target = try makeFixture()
        let exportURL = target.directory.appendingPathComponent("team-terms.json")
        try exported.write(to: exportURL)
        target.viewModel.importLocalTermPack(from: exportURL)

        XCTAssertNil(target.viewModel.localTermPackImportError)
        XCTAssertEqual(target.store.file(withID: "team-terms"), source.store.file(withID: "team-terms"))
        let pack = try XCTUnwrap(target.viewModel.visibleLocalPacks.first)
        target.viewModel.activatePack(pack)
        XCTAssertEqual(Set(target.service.entries.map(\.original)), ["Kubernetes", "TypeWhisper", "type whisper"])
    }

    func testRemovingAPackDeletesItsFileAndEntries() throws {
        let fixture = try makeFixture()
        fixture.service.addEntry(type: .term, original: "ManualTerm")
        fixture.viewModel.importLocalTermPack(data: LocalTermPackFileTests.packJSON(terms: "[\"Alpha\", \"Beta\"]", corrections: nil))
        let pack = try XCTUnwrap(fixture.viewModel.visibleLocalPacks.first)
        fixture.viewModel.activatePack(pack)
        let beta = try XCTUnwrap(fixture.service.entries.first { $0.original == "Beta" })
        fixture.service.setEntryEnabled(beta, enabled: false)

        fixture.viewModel.requestLocalTermPackRemoval(pack)
        fixture.viewModel.cancelLocalTermPackRemoval()
        XCTAssertEqual(fixture.viewModel.visibleLocalPacks.map(\.id), ["team-terms"])
        XCTAssertTrue(fixture.viewModel.isPackActivated(pack))

        fixture.viewModel.requestLocalTermPackRemoval(pack)
        XCTAssertEqual(fixture.viewModel.pendingLocalTermPackRemoval?.id, "team-terms")
        fixture.viewModel.confirmLocalTermPackRemoval()

        XCTAssertNil(fixture.viewModel.pendingLocalTermPackRemoval)
        XCTAssertTrue(fixture.viewModel.visibleLocalPacks.isEmpty)
        XCTAssertNil(fixture.viewModel.activatedPackStates["team-terms"])
        XCTAssertEqual(fixture.service.entries.map(\.original), ["ManualTerm"])
        XCTAssertNil(fixture.defaults.data(forKey: UserDefaultsKeys.termPackEntryOverrides))
        XCTAssertTrue(LocalTermPackStore(directory: fixture.store.directory).packs.isEmpty)
    }

    func testRemovingAPackKeepsItsFileWhenItsEntriesCannotBeDeleted() throws {
        let fixture = try makeFixture()
        fixture.viewModel.importLocalTermPack(data: LocalTermPackFileTests.packJSON(terms: "[\"Alpha\", \"Beta\"]", corrections: nil))
        let pack = try XCTUnwrap(fixture.viewModel.visibleLocalPacks.first)
        fixture.viewModel.activatePack(pack)
        fixture.service.deleteEntriesSaveOverride = { throw NSError(domain: "LocalTermPackRemovalTest", code: 1) }

        fixture.viewModel.requestLocalTermPackRemoval(pack)
        fixture.viewModel.confirmLocalTermPackRemoval()

        XCTAssertNotNil(fixture.viewModel.error)
        XCTAssertTrue(fixture.viewModel.isPackActivated(pack))
        XCTAssertEqual(Set(fixture.service.entries.map(\.original)), ["Alpha", "Beta"])
        XCTAssertEqual(LocalTermPackStore(directory: fixture.store.directory).packs.map(\.id), ["team-terms"])

        fixture.service.deleteEntriesSaveOverride = nil
        fixture.viewModel.clearError()
        fixture.viewModel.requestLocalTermPackRemoval(pack)
        fixture.viewModel.confirmLocalTermPackRemoval()

        XCTAssertNil(fixture.viewModel.error)
        XCTAssertNil(fixture.viewModel.activatedPackStates["team-terms"])
        XCTAssertTrue(fixture.service.entries.isEmpty)
        XCTAssertTrue(LocalTermPackStore(directory: fixture.store.directory).packs.isEmpty)
    }

    // MARK: - Fixtures

    private struct Fixture {
        let directory: URL
        let defaults: UserDefaults
        let service: DictionaryService
        let registry: TermPackRegistryService
        let store: LocalTermPackStore
        let viewModel: DictionaryViewModel
    }

    private func makeFixture() throws -> Fixture {
        let directory = try TestSupport.makeTemporaryDirectory(prefix: "LocalTermPackDictionary")
        let suiteName = "LocalTermPackDictionary-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            TestSupport.remove(directory)
            defaults.removePersistentDomain(forName: suiteName)
        }
        let service = DictionaryService(appSupportDirectory: directory)
        let registry = TermPackRegistryService(userDefaults: defaults)
        let store = LocalTermPackStore(directory: directory.appendingPathComponent(LocalTermPackStore.directoryName))
        let viewModel = DictionaryViewModel(
            dictionaryService: service,
            termPackRegistryService: registry,
            localTermPackStore: store,
            defaults: defaults
        )
        return Fixture(
            directory: directory,
            defaults: defaults,
            service: service,
            registry: registry,
            store: store,
            viewModel: viewModel
        )
    }

    /// A second view model on the same stores, as after a relaunch.
    private func makeViewModel(_ fixture: Fixture) -> DictionaryViewModel {
        DictionaryViewModel(
            dictionaryService: fixture.service,
            termPackRegistryService: fixture.registry,
            localTermPackStore: fixture.store,
            defaults: fixture.defaults
        )
    }

    private func makeCommunityPack(id: String, terms: [String]) -> TermPack {
        TermPack(
            id: id,
            name: id,
            description: "Community test pack",
            icon: "shippingbox",
            terms: terms,
            corrections: [],
            version: "1.0.0",
            author: "Tests",
            localizedNames: nil,
            localizedDescriptions: nil
        )
    }
}
