import AppKit
import Combine
import XCTest
@testable import TypeWhisper

final class ManagedPolicyValidatorTests: XCTestCase {
    private let readAt = Date(timeIntervalSince1970: 1_800_000_000)

    func testCatalogMatchesTheWindowsContract() {
        XCTAssertEqual(ManagedPolicyKeys.all.map(\.name), [
            "TranscriptionProviderId", "TranscriptionModelId", "LlmProviderId", "LlmModelId",
            "AllowedTranscriptionProviders", "AllowedLlmProviders", "AllowedPlugins",
            "AllowCloudTranscription", "AllowCloudTextProcessing", "AllowPluginDownloads", "AllowModelDownloads",
            "UpdateMode", "UpdateChannel", "AllowedUpdateChannels", "LaunchAtLogin",
            "SkipOnboardingWhenReady", "SuppressOptionalPrompts", "ManagedLicenseKey",
        ])
        XCTAssertEqual(
            Set(ManagedPolicyKeys.all.filter(\.allowsRecommendation).map(\.name)),
            ["TranscriptionProviderId", "TranscriptionModelId", "LlmProviderId", "LlmModelId",
             "UpdateChannel", "LaunchAtLogin", "SuppressOptionalPrompts"]
        )
        for definition in ManagedPolicyKeys.all {
            if let partner = definition.pairedWith {
                XCTAssertEqual(ManagedPolicyKeys.definition(named: partner)?.pairedWith, definition.name)
            }
        }
        XCTAssertEqual(ManagedPolicyKeys.all.filter(\.sensitive).map(\.name), ["ManagedLicenseKey"])
        XCTAssertNil(ManagedPolicyKeys.definition(named: "allowCloudTranscription"))
    }

    func testUnreadableSourceBlocksEveryKeyAndCarriesNoValues() {
        let snapshot = validate(.unreadable("CFPreferences"))

        XCTAssertEqual(snapshot.status, .unreadable)
        XCTAssertTrue(snapshot.enforcedValues.isEmpty)
        XCTAssertTrue(snapshot.isBlocked(ManagedPolicyKeys.allowCloudTranscription))
        XCTAssertEqual(snapshot.issues.count, 1)
        XCTAssertTrue(snapshot.issues[0].message.contains("CFPreferences"))
    }

    func testAbsentReadingIsUnmanagedWithoutIssues() {
        let snapshot = validate(.absent)

        XCTAssertEqual(snapshot.status, .absent)
        XCTAssertFalse(snapshot.isManaged)
        XCTAssertTrue(snapshot.issues.isEmpty)
        XCTAssertFalse(snapshot.isBlocked(ManagedPolicyKeys.updateMode))
    }

    func testBooleanAcceptsOnlyPropertyListBooleans() {
        let snapshot = validate(forced: [
            "AllowCloudTranscription": .boolean(false),
            "AllowCloudTextProcessing": .boolean(true),
            "AllowPluginDownloads": .integer(0),
            "AllowModelDownloads": .string("false"),
        ])

        XCTAssertEqual(snapshot.enforced("AllowCloudTranscription"), .boolean(false))
        XCTAssertEqual(snapshot.enforced("AllowCloudTextProcessing"), .boolean(true))
        XCTAssertEqual(snapshot.invalidEnforcedKeys, ["AllowPluginDownloads", "AllowModelDownloads"])
        XCTAssertTrue(snapshot.isBlocked("AllowPluginDownloads"))
        XCTAssertTrue(snapshot.issues.allSatisfy { $0.message.contains("must be a Boolean") })
        XCTAssertEqual(snapshot.status, .present)
        XCTAssertTrue(snapshot.isManaged)
    }

    func testEnumerationAcceptsItsRangeAndRejectsEverythingElse() {
        for value in 0...2 {
            XCTAssertEqual(validate(forced: ["UpdateMode": .integer(value)]).enforced("UpdateMode"), .enumeration(value))
        }
        for raw: ManagedPolicyRawValue in [.integer(-1), .integer(3), .boolean(true), .string("1"), .unsupported(typeName: "real")] {
            let snapshot = validate(forced: ["UpdateMode": raw])
            XCTAssertNil(snapshot.enforced("UpdateMode"), "\(raw)")
            XCTAssertTrue(snapshot.isBlocked("UpdateMode"), "\(raw)")
            XCTAssertEqual(snapshot.issues.map(\.message), ["UpdateMode must be an integer between 0 and 2."])
        }
    }

    func testTextIsTrimmedAndRejectsEmptyControlLongAndNonStringValues() {
        let trimmed = validate(forced: ["ManagedLicenseKey": .string("  KEY-123 \n")])
        XCTAssertEqual(trimmed.enforced("ManagedLicenseKey"), .text("KEY-123"))

        let invalid: [ManagedPolicyRawValue] = [
            .string("   "),
            .string("line\u{0007}bell"),
            .string(String(repeating: "a", count: ManagedPolicyValidator.maximumTextLength + 1)),
            .integer(5),
        ]
        for raw in invalid {
            let snapshot = validate(forced: ["ManagedLicenseKey": raw])
            XCTAssertNil(snapshot.enforced("ManagedLicenseKey"))
            XCTAssertEqual(snapshot.invalidEnforcedKeys, ["ManagedLicenseKey"])
            XCTAssertFalse(snapshot.issues[0].message.contains("bell"), "Issues must not carry values")
        }
        let longest = String(repeating: "a", count: ManagedPolicyValidator.maximumTextLength)
        XCTAssertEqual(validate(forced: ["ManagedLicenseKey": .string(longest)]).enforced("ManagedLicenseKey"), .text(longest))
    }

    func testPairRequiresBothMembersAtTheSameScope() {
        let providerOnly = validate(forced: ["TranscriptionProviderId": .string("com.typewhisper.parakeet")])
        XCTAssertNil(providerOnly.enforced("TranscriptionProviderId"))
        XCTAssertEqual(providerOnly.invalidEnforcedKeys, ["TranscriptionProviderId", "TranscriptionModelId"])
        XCTAssertEqual(providerOnly.issues.map(\.key), ["TranscriptionModelId"])

        let split = validate(forced: [
            "LlmProviderId": .string("com.typewhisper.claude"),
            "Recommended": .dictionary(["LlmModelId": .string("claude-sonnet")]),
        ])
        XCTAssertTrue(split.enforcedValues.isEmpty)
        XCTAssertTrue(split.recommendedValues.isEmpty)
        XCTAssertEqual(split.invalidEnforcedKeys, ["LlmProviderId", "LlmModelId"])

        let recommendedModelOnly = validate(forced: [
            "Recommended": .dictionary(["TranscriptionModelId": .string("parakeet-tdt-0.6b-v3")]),
        ])
        XCTAssertTrue(recommendedModelOnly.recommendedValues.isEmpty)
        XCTAssertTrue(recommendedModelOnly.invalidEnforcedKeys.isEmpty, "Invalid recommendations never block")
        XCTAssertEqual(recommendedModelOnly.issues.map(\.scope), [.recommended])
    }

    func testPairWithBothMembersIsAcceptedAtEitherScope() {
        let snapshot = validate(forced: [
            "TranscriptionProviderId": .string("com.typewhisper.parakeet"),
            "TranscriptionModelId": .string("parakeet-tdt-0.6b-v3"),
            "Recommended": .dictionary([
                "LlmProviderId": .string("com.typewhisper.local-llm-mlx"),
                "LlmModelId": .string("qwen3-4b"),
            ]),
        ])

        XCTAssertEqual(snapshot.enforced("TranscriptionProviderId"), .text("com.typewhisper.parakeet"))
        XCTAssertEqual(snapshot.enforced("TranscriptionModelId"), .text("parakeet-tdt-0.6b-v3"))
        XCTAssertEqual(snapshot.recommended("LlmProviderId"), .text("com.typewhisper.local-llm-mlx"))
        XCTAssertEqual(snapshot.recommended("LlmModelId"), .text("qwen3-4b"))
        XCTAssertTrue(snapshot.issues.isEmpty)
    }

    func testPairWithOneInvalidMemberIsRejectedAsAWhole() {
        let snapshot = validate(forced: [
            "LlmProviderId": .string("com.typewhisper.claude"),
            "LlmModelId": .string(""),
        ])

        XCTAssertNil(snapshot.enforced("LlmProviderId"))
        XCTAssertEqual(snapshot.invalidEnforcedKeys, ["LlmProviderId", "LlmModelId"])
        XCTAssertEqual(snapshot.issues.map(\.message), ["LlmModelId must not be empty."])
    }

    func testListDeduplicatesTrimsAndKeepsOrder() {
        let snapshot = validate(forced: [
            "AllowedPlugins": .array([
                .string(" com.typewhisper.parakeet "), .string("com.typewhisper.whisperkit"), .string("com.typewhisper.parakeet"),
            ]),
        ])

        XCTAssertEqual(snapshot.enforced("AllowedPlugins"), .list(["com.typewhisper.parakeet", "com.typewhisper.whisperkit"]))
    }

    func testEmptyListDeniesEverythingAndKeepsTheNoneEntry() {
        XCTAssertEqual(validate(forced: ["AllowedUpdateChannels": .array([])]).enforced("AllowedUpdateChannels"), .list([]))
        XCTAssertEqual(
            validate(forced: ["AllowedUpdateChannels": .array([.string("none")])]).enforced("AllowedUpdateChannels"),
            .list(["none"])
        )
    }

    func testListRejectsNonArraysNonStringsInvalidEntriesAndTooManyEntries() {
        let tooMany = (0...ManagedPolicyValidator.maximumListEntries).map { ManagedPolicyRawValue.string("plugin-\($0)") }
        let cases: [(ManagedPolicyRawValue, String)] = [
            (.string("com.typewhisper.parakeet"), "AllowedPlugins must be an array of strings."),
            (.array([.string("a"), .integer(1)]), "AllowedPlugins must contain only strings."),
            (.array([.string(" ")]), "AllowedPlugins contains an entry that is empty, too long or has control characters."),
            (.array(tooMany), "AllowedPlugins must not exceed 256 entries."),
        ]
        for (raw, message) in cases {
            let snapshot = validate(forced: ["AllowedPlugins": raw])
            XCTAssertNil(snapshot.enforced("AllowedPlugins"))
            XCTAssertTrue(snapshot.isBlocked("AllowedPlugins"))
            XCTAssertEqual(snapshot.issues.map(\.message), [message])
        }
        let atLimit = (1...ManagedPolicyValidator.maximumListEntries).map { ManagedPolicyRawValue.string("plugin-\($0)") }
        XCTAssertEqual(validate(forced: ["AllowedPlugins": .array(atLimit)]).enforced("AllowedPlugins")?.listItems?.count, 256)
    }

    func testRestrictionsUnderRecommendedAreIgnoredNotPromoted() {
        let snapshot = validate(forced: [
            "Recommended": .dictionary([
                "AllowCloudTranscription": .boolean(false),
                "AllowedPlugins": .array([]),
                "ManagedLicenseKey": .string("KEY"),
            ]),
        ])

        XCTAssertTrue(snapshot.enforcedValues.isEmpty)
        XCTAssertTrue(snapshot.recommendedValues.isEmpty)
        XCTAssertTrue(snapshot.invalidEnforcedKeys.isEmpty)
        XCTAssertEqual(Set(snapshot.issues.compactMap(\.key)), ["AllowCloudTranscription", "AllowedPlugins", "ManagedLicenseKey"])
        XCTAssertTrue(snapshot.issues.allSatisfy { $0.message.contains("can only be enforced") })
    }

    func testRecommendationsAreAcceptedForTheAllowedKeys() {
        let snapshot = validate(forced: [
            "Recommended": .dictionary([
                "UpdateChannel": .integer(2),
                "LaunchAtLogin": .boolean(true),
                "SuppressOptionalPrompts": .boolean(false),
            ]),
        ])

        XCTAssertEqual(snapshot.recommended("UpdateChannel"), .enumeration(2))
        XCTAssertEqual(snapshot.recommended("LaunchAtLogin"), .boolean(true))
        XCTAssertEqual(snapshot.recommended("SuppressOptionalPrompts"), .boolean(false))
        XCTAssertTrue(snapshot.enforcedValues.isEmpty)
        XCTAssertTrue(snapshot.isManaged)
    }

    func testInvalidRecommendationIsReportedWithoutBlocking() {
        let snapshot = validate(forced: ["Recommended": .dictionary(["UpdateChannel": .integer(7)])])

        XCTAssertNil(snapshot.recommended("UpdateChannel"))
        XCTAssertFalse(snapshot.isBlocked("UpdateChannel"))
        XCTAssertEqual(snapshot.issues, [ManagedPolicyIssue(
            key: "UpdateChannel",
            scope: .recommended,
            message: "UpdateChannel must be an integer between 0 and 2."
        )])
    }

    func testRecommendedThatIsNotADictionaryIsReported() {
        let snapshot = validate(forced: ["Recommended": .array([.string("UpdateChannel")])])

        XCTAssertTrue(snapshot.recommendedValues.isEmpty)
        XCTAssertEqual(snapshot.issues.map(\.key), ["Recommended"])
    }

    func testUnknownKeysAreReportedAndCaseMismatchesNameTheSupportedKey() {
        let snapshot = validate(forced: [
            "allowCloudTranscription": .boolean(false),
            "FutureSetting": .integer(1),
            "Recommended": .dictionary(["launchAtLogin": .boolean(true)]),
        ])

        XCTAssertTrue(snapshot.enforcedValues.isEmpty)
        XCTAssertTrue(snapshot.recommendedValues.isEmpty)
        XCTAssertTrue(snapshot.invalidEnforcedKeys.isEmpty)
        XCTAssertEqual(snapshot.issues.map(\.message), [
            "FutureSetting is not a dictum managed setting and is not applied as one.",
            "allowCloudTranscription is not a dictum managed setting; keys are case-sensitive (did you mean AllowCloudTranscription?).",
            "launchAtLogin is not a dictum managed setting; keys are case-sensitive (did you mean LaunchAtLogin?).",
        ])
    }

    func testProfileMetadataKeysAreNeitherSettingsNorReported() {
        let snapshot = validate(forced: [
            "PayloadUUID": .string("668AB38C-BC32-560D-9C5D-C7FCB5D4FD32"),
            "_manualProfile": .boolean(true),
            "AllowCloudTranscription": .boolean(false),
        ])

        XCTAssertEqual(snapshot.enforcedValues, ["AllowCloudTranscription": .boolean(false)])
        XCTAssertTrue(snapshot.issues.isEmpty)
        XCTAssertEqual(validate(forced: ["PayloadUUID": .string("A"), "_manualProfile": .boolean(true)]).status, .absent)
    }

    func testOtherForcedKeysOfTheDomainDoNotMakeThePolicyPresent() {
        let snapshot = validate(forced: ["SUEnableAutomaticChecks": .boolean(false)])

        XCTAssertEqual(snapshot.status, .absent)
        XCTAssertFalse(snapshot.isManaged)
        XCTAssertEqual(snapshot.issues.map(\.message), [
            "SUEnableAutomaticChecks is not a dictum managed setting and is not applied as one.",
        ])
        XCTAssertEqual(validate(forced: ["Recommended": .dictionary([:])]).status, .present)
        XCTAssertEqual(validate(forced: ["UpdateMode": .integer(1), "SUEnableAutomaticChecks": .boolean(false)]).status, .present)
    }

    func testValuesSetOutsideAProfileAreReportedExceptTheManagedLicenseKey() {
        let snapshot = validate(ManagedPolicyReading(unmanagedKeys: ["AllowCloudTranscription", "ManagedLicenseKey", "Recommended"]))

        XCTAssertEqual(snapshot.status, .absent)
        XCTAssertFalse(snapshot.isManaged)
        XCTAssertEqual(snapshot.issues.map(\.message), [
            "AllowCloudTranscription is set outside a configuration profile and is ignored.",
            "Recommended is set outside a configuration profile and is ignored.",
        ])
    }

    func testSnapshotResolvesByPrecedence() {
        let snapshot = validate(forced: [
            "LaunchAtLogin": .boolean(false),
            "Recommended": .dictionary(["UpdateChannel": .integer(1), "SuppressOptionalPrompts": .boolean(true)]),
        ])

        XCTAssertEqual(
            snapshot.resolveBoolean("LaunchAtLogin", applicationDefault: false, userPreference: true),
            ResolvedManagedSetting(value: false, source: .enforcedPolicy)
        )
        XCTAssertEqual(
            snapshot.resolveEnumeration("UpdateChannel", applicationDefault: 0),
            ResolvedManagedSetting(value: 1, source: .recommendedPolicy)
        )
        XCTAssertEqual(
            snapshot.resolveEnumeration("UpdateChannel", applicationDefault: 0, userPreference: 0),
            ResolvedManagedSetting(value: 0, source: .userPreference)
        )
        XCTAssertEqual(
            snapshot.resolveText("TranscriptionProviderId", applicationDefault: "default").source,
            .applicationDefault
        )
    }

    func testContentEqualsIgnoresRevisionAndReadTime() {
        let forced: [String: ManagedPolicyRawValue] = ["UpdateMode": .integer(1)]
        let first = ManagedPolicyValidator.validate(ManagedPolicyReading(forcedValues: forced), revision: 1, readAt: readAt)
        let second = ManagedPolicyValidator.validate(
            ManagedPolicyReading(forcedValues: forced), revision: 2, readAt: readAt.addingTimeInterval(30)
        )
        let changed = ManagedPolicyValidator.validate(
            ManagedPolicyReading(forcedValues: ["UpdateMode": .integer(0)]), revision: 3, readAt: readAt
        )

        XCTAssertTrue(first.contentEquals(second))
        XCTAssertFalse(first.contentEquals(changed))
    }

    func testRetainingValuesKeepsEarlierValuesWithTheNewStatus() {
        let readable = validate(forced: ["AllowModelDownloads": .boolean(false)])
        let unreadable = ManagedPolicyValidator.validate(.unreadable("timeout"), revision: 2, readAt: readAt)
            .retainingValues(from: readable)

        XCTAssertEqual(unreadable.status, .unreadable)
        XCTAssertEqual(unreadable.revision, 2)
        XCTAssertEqual(unreadable.enforced("AllowModelDownloads"), .boolean(false))
        XCTAssertTrue(unreadable.isBlocked("AllowModelDownloads"))
        XCTAssertEqual(unreadable.issues.count, 1)
    }

    /// VoiceOver reads each row of the Managed Settings table as one line.
    @MainActor
    func testManagedSettingsRowsReadAsOneLine() {
        let snapshot = validate(forced: [
            "AllowCloudTranscription": .boolean(false),
            "AllowPluginDownloads": .integer(0),
        ])

        let labels = ManagedSettingsSection.rows(snapshot).map(ManagedSettingsSection.accessibilityLabel(for:))

        XCTAssertEqual(labels, [
            "AllowCloudTranscription, \(String(localized: "Enforced")), \(String(localized: "Off"))",
            "AllowPluginDownloads, \(String(localized: "Enforced")), "
                + String(localized: "Invalid value; the setting stays blocked"),
        ])
    }

    private func validate(forced: [String: ManagedPolicyRawValue]) -> ManagedPolicySnapshot {
        validate(ManagedPolicyReading(forcedValues: forced))
    }

    private func validate(_ reading: ManagedPolicyReading) -> ManagedPolicySnapshot {
        ManagedPolicyValidator.validate(reading, revision: 1, readAt: readAt)
    }
}

final class ManagedSettingResolverTests: XCTestCase {
    func testAllSourceCombinationsUseTheDeclaredPrecedence() {
        for enforced in [nil, 4] as [Int?] {
            for user in [nil, 3] as [Int?] {
                for recommended in [nil, 2] as [Int?] {
                    let resolved = ManagedSettingResolver.resolve(
                        applicationDefault: 1,
                        explicitUserPreference: user,
                        recommendedPolicy: recommended,
                        enforcedPolicy: enforced
                    )
                    let expected: ResolvedManagedSetting<Int> = if let enforced {
                        .init(value: enforced, source: .enforcedPolicy)
                    } else if let user {
                        .init(value: user, source: .userPreference)
                    } else if let recommended {
                        .init(value: recommended, source: .recommendedPolicy)
                    } else {
                        .init(value: 1, source: .applicationDefault)
                    }
                    XCTAssertEqual(resolved, expected)
                }
            }
        }
    }

    func testExplicitFactoryDefaultWinsOverRecommendation() {
        for factoryDefault in [false, true] {
            let resolved = ManagedSettingResolver.resolve(
                applicationDefault: factoryDefault,
                explicitUserPreference: factoryDefault,
                recommendedPolicy: !factoryDefault
            )
            XCTAssertEqual(resolved, .init(value: factoryDefault, source: .userPreference))
            XCTAssertFalse(resolved.isEnforced)
        }
    }

    func testEnforcementAddedAndRemovedRevealsTheRetainedUserChoice() {
        let userChoice = true
        let enforced = ManagedSettingResolver.resolve(
            applicationDefault: false, explicitUserPreference: userChoice, enforcedPolicy: false
        )
        XCTAssertEqual(enforced, .init(value: false, source: .enforcedPolicy))
        XCTAssertTrue(enforced.isEnforced)

        let removed = ManagedSettingResolver.resolve(applicationDefault: false, explicitUserPreference: userChoice)
        XCTAssertEqual(removed, .init(value: true, source: .userPreference))
    }
}

@MainActor
final class ManagedPolicyServiceTests: XCTestCase {
    func testFirstReadIsPublishedEvenWhenPolicyIsAbsent() {
        let service = ManagedPolicyService(source: FakeManagedPolicySource(.absent))

        XCTAssertEqual(service.current.revision, 0)
        let snapshot = service.refresh()

        XCTAssertEqual(snapshot.revision, 1)
        XCTAssertEqual(service.current.revision, 1)
        XCTAssertEqual(service.current.status, .absent)
    }

    func testRefreshWithoutContentChangeKeepsTheSnapshot() {
        let source = FakeManagedPolicySource(ManagedPolicyReading(forcedValues: ["UpdateMode": .integer(1)]))
        let service = ManagedPolicyService(source: source)
        service.refresh()
        var publications = 0
        let subscription = service.$current.dropFirst().sink { _ in publications += 1 }

        service.refresh()
        service.refresh()

        XCTAssertEqual(service.current.revision, 1)
        XCTAssertEqual(publications, 0)
        XCTAssertEqual(source.readCount, 3)
        subscription.cancel()
    }

    func testRefreshWithContentChangePublishesANewRevision() {
        let source = FakeManagedPolicySource(.absent)
        let service = ManagedPolicyService(source: source)
        service.refresh()

        source.reading = ManagedPolicyReading(forcedValues: ["AllowCloudTranscription": .boolean(false)])
        service.refresh()

        XCTAssertEqual(service.current.revision, 2)
        XCTAssertEqual(service.current.enforced("AllowCloudTranscription"), .boolean(false))

        source.reading = .absent
        service.refresh()

        XCTAssertEqual(service.current.revision, 3)
        XCTAssertFalse(service.current.isManaged)
    }

    func testUnreadableReadRetainsValuesAndBlocksUntilReadableAgain() {
        let readable = ManagedPolicyReading(forcedValues: ["AllowPluginDownloads": .boolean(false)])
        let source = FakeManagedPolicySource(readable)
        let service = ManagedPolicyService(source: source)
        service.refresh()

        source.reading = .unreadable("timeout")
        service.refresh()

        XCTAssertEqual(service.current.status, .unreadable)
        XCTAssertEqual(service.current.enforced("AllowPluginDownloads"), .boolean(false))
        XCTAssertTrue(service.current.isBlocked("UpdateMode"))

        source.reading = readable
        service.refresh()

        XCTAssertEqual(service.current.status, .present)
        XCTAssertFalse(service.current.isBlocked("UpdateMode"))
        XCTAssertEqual(service.current.revision, 3)
    }

    func testColdStartWithUnreadableSourceBlocksWithoutValues() {
        let service = ManagedPolicyService(source: FakeManagedPolicySource(.unreadable("denied")))

        service.refresh()

        XCTAssertEqual(service.current.status, .unreadable)
        XCTAssertTrue(service.current.enforcedValues.isEmpty)
        XCTAssertTrue(service.current.isBlocked("AllowCloudTextProcessing"))
    }

    func testActivationWakeAndSessionSwitchRefresh() async {
        let source = FakeManagedPolicySource(.absent)
        let service = ManagedPolicyService(source: source, fallbackTicks: { AsyncStream { _ in } })
        let appCenter = NotificationCenter()
        let workspaceCenter = NotificationCenter()
        service.refresh()
        service.startMonitoring(notificationCenter: appCenter, workspaceNotificationCenter: workspaceCenter)
        defer { service.stopMonitoring() }
        let reads = expectation(description: "each trigger re-reads the source")
        reads.expectedFulfillmentCount = 3
        source.onRead = { reads.fulfill() }

        appCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        workspaceCenter.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        appCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await fulfillment(of: [reads], timeout: 5)

        XCTAssertEqual(source.readCount, 4)
    }

    func testFallbackTickRereadsWithoutNotifications() async {
        let source = FakeManagedPolicySource(.absent)
        let (ticks, tick) = AsyncStream<Void>.makeStream()
        let service = ManagedPolicyService(source: source, fallbackTicks: { ticks })
        service.refresh()
        let published = expectation(description: "the fallback refresh publishes the change")
        let subscription = service.$current.dropFirst().sink { snapshot in
            if snapshot.enforced("UpdateMode") == .enumeration(0) { published.fulfill() }
        }
        service.startMonitoring(notificationCenter: NotificationCenter(), workspaceNotificationCenter: NotificationCenter())

        source.reading = ManagedPolicyReading(forcedValues: ["UpdateMode": .integer(0)])
        tick.yield()
        await fulfillment(of: [published], timeout: 5)

        XCTAssertEqual(service.current.revision, 2)
        service.stopMonitoring()
        subscription.cancel()
    }

    func testStopMonitoringEndsTheFallbackAndRemovesObservers() async {
        let source = FakeManagedPolicySource(.absent)
        let (ticks, tick) = AsyncStream<Void>.makeStream()
        let stopped = expectation(description: "the fallback stream is released")
        tick.onTermination = { _ in stopped.fulfill() }
        let service = ManagedPolicyService(source: source, fallbackTicks: { ticks })
        let appCenter = NotificationCenter()
        service.startMonitoring(notificationCenter: appCenter, workspaceNotificationCenter: NotificationCenter())

        service.stopMonitoring()
        await fulfillment(of: [stopped], timeout: 5)
        appCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        XCTAssertEqual(source.readCount, 0)
    }

    func testDefaultTicksStopWhenTheConsumerStops() async {
        var iterator = ManagedPolicyService.ticks(every: .milliseconds(1)).makeAsyncIterator()
        let first: Void? = await iterator.next()
        XCTAssertNotNil(first)
    }
}

final class ManagedPreferencesPolicySourceTests: XCTestCase {
    func testPropertyListConversionKeepsBooleansIntegersAndStringsApart() {
        XCTAssertEqual(ManagedPolicyRawValue(propertyList: kCFBooleanTrue as Any), .boolean(true))
        XCTAssertEqual(ManagedPolicyRawValue(propertyList: NSNumber(value: false)), .boolean(false))
        XCTAssertEqual(ManagedPolicyRawValue(propertyList: NSNumber(value: 1)), .integer(1))
        XCTAssertEqual(ManagedPolicyRawValue(propertyList: NSNumber(value: 1.5)), .unsupported(typeName: "real"))
        XCTAssertEqual(ManagedPolicyRawValue(propertyList: "stable"), .string("stable"))
        XCTAssertEqual(ManagedPolicyRawValue(propertyList: Data([1])), .unsupported(typeName: "data"))
        XCTAssertEqual(ManagedPolicyRawValue(propertyList: Date()), .unsupported(typeName: "date"))
        XCTAssertEqual(
            ManagedPolicyRawValue(propertyList: ["UpdateChannel": NSNumber(value: 2), "Items": ["a", NSNumber(value: true)]]),
            .dictionary(["UpdateChannel": .integer(2), "Items": .array([.string("a"), .boolean(true)])])
        )
    }

    func testValuesWrittenWithoutAProfileAreNotApplied() throws {
        let suiteName = "TypeWhisperTests.ManagedPolicy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: ManagedPolicyKeys.allowCloudTranscription)
        defaults.set("KEY", forKey: ManagedPolicyKeys.managedLicenseKey)
        defaults.set(["UpdateChannel": 1], forKey: ManagedPolicyKeys.recommendedDictionary)
        defaults.set("stable", forKey: "updateChannel")

        let reading = ManagedPreferencesPolicySource(applicationID: suiteName).read()
        let snapshot = ManagedPolicyValidator.validate(reading, revision: 1, readAt: Date())

        XCTAssertTrue(reading.readable)
        XCTAssertTrue(reading.forcedValues.isEmpty)
        XCTAssertEqual(reading.unmanagedKeys, ["AllowCloudTranscription", "ManagedLicenseKey", "Recommended"])
        XCTAssertFalse(snapshot.isManaged)
        XCTAssertEqual(snapshot.issues.compactMap(\.key), ["AllowCloudTranscription", "Recommended"])
    }
}

final class ManagedPolicyDiagnosticsTests: XCTestCase {
    func testDiagnosticsMaskSensitiveValuesAndOmitFreeText() {
        let snapshot = ManagedPolicyValidator.validate(ManagedPolicyReading(forcedValues: [
            "ManagedLicenseKey": .string("SECRET-LICENSE"),
            "TranscriptionProviderId": .string("com.typewhisper.parakeet"),
            "TranscriptionModelId": .string("/Users/someone/models/private"),
            "AllowedPlugins": .array([.string("com.typewhisper.whisperkit"), .string("https://example.com/plugin")]),
            "AllowCloudTranscription": .boolean(false),
            "UpdateMode": .integer(1),
            "Private Note For Alice": .string("text"),
            "Recommended": .dictionary(["UpdateChannel": .integer(2)]),
        ]), revision: 4, readAt: Date(timeIntervalSince1970: 1_800_000_000))

        let diagnostics = ManagedPolicyDiagnostics(snapshot: snapshot)

        XCTAssertEqual(diagnostics.status, "present")
        XCTAssertEqual(diagnostics.revision, 4)
        XCTAssertEqual(diagnostics.enforced, [
            .init(name: "AllowCloudTranscription", value: "false", items: nil),
            .init(name: "AllowedPlugins", value: nil, items: ["com.typewhisper.whisperkit", "[omitted]"]),
            .init(name: "ManagedLicenseKey", value: "[set]", items: nil),
            .init(name: "TranscriptionModelId", value: "[omitted]", items: nil),
            .init(name: "TranscriptionProviderId", value: "com.typewhisper.parakeet", items: nil),
            .init(name: "UpdateMode", value: "1", items: nil),
        ])
        XCTAssertEqual(diagnostics.recommended, [.init(name: "UpdateChannel", value: "2", items: nil)])
        XCTAssertEqual(diagnostics.issues, [
            .init(key: "[omitted]", scope: "enforced", message: "[omitted] is not a dictum managed setting and is not applied as one."),
        ])
    }

    func testDiagnosticsEncodeWithoutSecrets() throws {
        let snapshot = ManagedPolicyValidator.validate(
            ManagedPolicyReading(forcedValues: ["ManagedLicenseKey": .string("SECRET-LICENSE")]),
            revision: 1,
            readAt: Date()
        )

        let data = try JSONEncoder().encode(ManagedPolicyDiagnostics(snapshot: snapshot))

        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("SECRET-LICENSE"))
    }

    func testIdentifierKeepsTechnicalIdsOnly() {
        for kept in ["com.typewhisper.parakeet", "parakeet-tdt-0.6b-v3", "openai-compatible:local", "gpt-4o+audio"] {
            XCTAssertEqual(ManagedPolicyDiagnostics.identifier(kept), kept)
        }
        for omitted in ["", "/Users/a", "C:\\models", "C:models", "two words", "../escape", "-leading", "naïve", String(repeating: "a", count: 161)] {
            XCTAssertEqual(ManagedPolicyDiagnostics.identifier(omitted), "[omitted]", omitted)
        }
    }
}

private final class FakeManagedPolicySource: ManagedPolicySource, @unchecked Sendable {
    var reading: ManagedPolicyReading
    var onRead: (() -> Void)?
    private(set) var readCount = 0

    init(_ reading: ManagedPolicyReading) {
        self.reading = reading
    }

    func read() -> ManagedPolicyReading {
        readCount += 1
        onRead?()
        return reading
    }
}
