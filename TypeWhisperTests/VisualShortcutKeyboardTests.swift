import AppKit
import Carbon.HIToolbox
import XCTest
@testable import TypeWhisper

/// Headless coverage for the visual shortcut keyboard view model.
/// All composition rules must mirror the event-driven recorder exactly.
final class VisualShortcutKeyboardTests: XCTestCase {
    private func makeModel(
        editingHotkey: UnifiedHotkey? = nil,
        existingAssignmentDescription: ((UnifiedHotkey) -> String?)? = nil
    ) -> VisualShortcutKeyboardModel {
        VisualShortcutKeyboardModel(
            editingHotkey: editingHotkey,
            existingAssignmentDescription: existingAssignmentDescription,
            keyLabel: { "K\($0)" }
        )
    }

    private func commandA() -> UnifiedHotkey {
        UnifiedHotkey(
            keyCode: 0x00,
            modifierFlags: NSEvent.ModifierFlags.command.rawValue,
            isFn: false
        )
    }

    // MARK: - Composition

    func testEmptyComposition_cannotSave() {
        let model = makeModel()
        XCTAssertNil(model.composedHotkey)
        XCTAssertFalse(model.canSave)
        XCTAssertNil(model.conflictNotice)
    }

    func testToggleKey_selectsAndDeselects() {
        let model = makeModel()
        model.toggleKey(0x00)
        XCTAssertEqual(model.composition.keyCode, 0x00)
        model.toggleKey(0x00)
        XCTAssertNil(model.composition.keyCode)
    }

    func testToggleKey_replacesPreviousKey() {
        let model = makeModel()
        model.toggleKey(0x00)
        model.toggleKey(0x01)
        XCTAssertEqual(model.composition.keyCode, 0x01)
    }

    func testComposeKeyWithModifiers_matchesRecorderOutput() throws {
        let model = makeModel()
        model.toggleModifier(.keyCode(0x37)) // Left Command
        model.toggleKey(0x00) // A

        let composed = try XCTUnwrap(model.composedHotkey)
        // Exactly what the recorder's keyDown path produces.
        let recorderEquivalent = UnifiedHotkey(
            keyCode: 0x00,
            modifierFlags: NSEvent.ModifierFlags.command.rawValue,
            isFn: false
        )
        XCTAssertEqual(composed, recorderEquivalent)
        XCTAssertTrue(composed.conflicts(with: recorderEquivalent))
        XCTAssertEqual(composed.kind, .keyWithModifiers)
    }

    func testSingleModifier_composesModifierOnly() throws {
        let model = makeModel()
        model.toggleModifier(.keyCode(0x3D)) // Right Option

        let composed = try XCTUnwrap(model.composedHotkey)
        XCTAssertEqual(composed.kind, .modifierOnly)
        XCTAssertEqual(composed.keyCode, 0x3D)
        XCTAssertEqual(composed.modifierFlags, 0)
    }

    func testModifierCombo_preservesSideSpecificCodes() throws {
        let model = makeModel()
        model.toggleModifier(.keyCode(0x3B)) // Left Control
        model.toggleModifier(.keyCode(0x38)) // Left Shift

        let composed = try XCTUnwrap(model.composedHotkey)
        XCTAssertEqual(composed.kind, .modifierCombo)
        XCTAssertEqual(composed.keyCode, UnifiedHotkey.modifierComboKeyCode)
        XCTAssertEqual(composed.modifierKeyCodes, [0x3B, 0x38])
        let flags = NSEvent.ModifierFlags(rawValue: composed.modifierFlags)
        XCTAssertTrue(flags.contains(.control))
        XCTAssertTrue(flags.contains(.shift))
    }

    func testFnAlone_composesFnHotkey() throws {
        let model = makeModel()
        model.toggleModifier(.fn)

        let composed = try XCTUnwrap(model.composedHotkey)
        XCTAssertEqual(composed.kind, .fn)
        XCTAssertTrue(composed.isFn)
    }

    func testFnWithKey_setsFunctionFlag() throws {
        let model = makeModel()
        model.toggleModifier(.fn)
        model.toggleKey(0x00)

        let composed = try XCTUnwrap(model.composedHotkey)
        XCTAssertFalse(composed.isFn)
        XCTAssertTrue(NSEvent.ModifierFlags(rawValue: composed.modifierFlags).contains(.function))
    }

    func testDoubleTap_flowsIntoComposedHotkey() throws {
        let model = makeModel()
        model.toggleModifier(.keyCode(0x37))
        model.toggleKey(0x00)
        model.toggleDoubleTap()

        XCTAssertTrue(try XCTUnwrap(model.composedHotkey).isDoubleTap)
        model.toggleDoubleTap()
        XCTAssertFalse(try XCTUnwrap(model.composedHotkey).isDoubleTap)
    }

    func testToggleModifier_deselects() {
        let model = makeModel()
        model.toggleModifier(.keyCode(0x37))
        XCTAssertEqual(model.state(forModifier: .keyCode(0x37)), .active)
        model.toggleModifier(.keyCode(0x37))
        XCTAssertEqual(model.state(forModifier: .keyCode(0x37)), .available)
    }

    func testClear_resetsEverything() {
        let model = makeModel()
        model.toggleModifier(.keyCode(0x37))
        model.toggleModifier(.fn)
        model.toggleKey(0x00)
        model.toggleDoubleTap()
        model.clear()

        XCTAssertNil(model.composedHotkey)
        XCTAssertFalse(model.composition.isFnSelected)
        XCTAssertFalse(model.composition.isDoubleTap)
        XCTAssertTrue(model.composition.modifierKeyCodes.isEmpty)
    }

    // MARK: - Loading stored hotkeys

    func testLoadKeyboardHotkey_preselectsKeyAndLeftModifiers() {
        let model = makeModel(editingHotkey: commandA())
        XCTAssertEqual(model.composition.keyCode, 0x00)
        XCTAssertEqual(model.composition.modifierKeyCodes, [0x37])
        // Round-trips to the identical hotkey.
        XCTAssertEqual(model.composedHotkey, commandA())
    }

    func testLoadSideSpecificCombo_preservesSides() {
        let stored = UnifiedHotkey(
            keyCode: UnifiedHotkey.modifierComboKeyCode,
            modifierFlags: NSEvent.ModifierFlags([.command, .option]).rawValue,
            isFn: false,
            modifierKeyCodes: [0x36, 0x3D] // Right Command, Right Option
        )
        let model = makeModel(editingHotkey: stored)
        XCTAssertEqual(model.composition.modifierKeyCodes, [0x36, 0x3D])
        XCTAssertEqual(model.composedHotkey, stored)
    }

    func testLoadLegacyGenericCombo_unchangedSavePreservesGenericSemantics() {
        // Legacy stored combo: generic flags with no side information.
        let stored = UnifiedHotkey(
            keyCode: UnifiedHotkey.modifierComboKeyCode,
            modifierFlags: NSEvent.ModifierFlags([.command, .option]).rawValue,
            isFn: false
        )
        let model = makeModel(editingHotkey: stored)
        // The UI still shows left-side codes for the generic selection.
        XCTAssertEqual(model.composition.modifierKeyCodes, [0x37, 0x3A])
        // Opening the editor and saving unchanged must round-trip exactly:
        // no invented side-specific codes, so a right-side combination keeps
        // activating it.
        XCTAssertTrue(model.canSave)
        XCTAssertEqual(model.composedHotkey, stored)
    }

    func testLoadLegacyGenericCombo_doubleTapOnlyEditKeepsGenericSemantics() throws {
        let stored = UnifiedHotkey(
            keyCode: UnifiedHotkey.modifierComboKeyCode,
            modifierFlags: NSEvent.ModifierFlags([.command, .option]).rawValue,
            isFn: false
        )
        let model = makeModel(editingHotkey: stored)
        model.toggleDoubleTap()
        let composed = try XCTUnwrap(model.composedHotkey)
        XCTAssertTrue(composed.isDoubleTap)
        XCTAssertTrue(composed.modifierKeyCodes.isEmpty)
    }

    func testLoadLegacyGenericCombo_physicalChangePersistsSides() throws {
        let stored = UnifiedHotkey(
            keyCode: UnifiedHotkey.modifierComboKeyCode,
            modifierFlags: NSEvent.ModifierFlags([.command, .option]).rawValue,
            isFn: false
        )
        let model = makeModel(editingHotkey: stored)
        // Explicitly changing the physical selection replaces the generic
        // semantics with the exact side-specific codes.
        model.toggleModifier(.keyCode(0x37)) // deselect Left Command
        model.toggleModifier(.keyCode(0x36)) // select Right Command
        let composed = try XCTUnwrap(model.composedHotkey)
        XCTAssertEqual(composed.modifierKeyCodes, [0x36, 0x3A])
    }

    func testLoadModifierOnly_preselectsPhysicalKey() {
        let stored = UnifiedHotkey(keyCode: 0x3D, modifierFlags: 0, isFn: false)
        let model = makeModel(editingHotkey: stored)
        XCTAssertEqual(model.composition.modifierKeyCodes, [0x3D])
        XCTAssertEqual(model.state(forModifier: .keyCode(0x3D)), .active)
    }

    func testLoadModifierOnly_addingFnPreservesPhysicalSide() throws {
        // Stored Right Option shortcut: its key code identifies the physical
        // modifier.
        let stored = UnifiedHotkey(keyCode: 0x3D, modifierFlags: 0, isFn: false)
        let model = makeModel(editingHotkey: stored)
        model.toggleModifier(.fn)

        let composed = try XCTUnwrap(model.composedHotkey)
        XCTAssertEqual(composed.kind, .modifierCombo)
        // The physical side survives adding Fn: the saved hotkey keeps the
        // stored Right Option code instead of a generic Option+Fn combo.
        XCTAssertEqual(composed.modifierKeyCodes, [0x3D])
        let flags = NSEvent.ModifierFlags(rawValue: composed.modifierFlags)
        XCTAssertTrue(flags.contains(.option))
        XCTAssertTrue(flags.contains(.function))
    }

    func testModifierPreview_matchesEditedSelectionSpecificity() throws {
        // Legacy generic Command+Option combo: the selection only becomes
        // explicitly edited once the user changes it.
        let stored = UnifiedHotkey(
            keyCode: UnifiedHotkey.modifierComboKeyCode,
            modifierFlags: NSEvent.ModifierFlags([.command, .option]).rawValue,
            isFn: false
        )
        // The candidate the preview must NOT evaluate: generic semantics.
        let genericCandidate = UnifiedHotkey(
            keyCode: UnifiedHotkey.modifierComboKeyCode,
            modifierFlags: NSEvent.ModifierFlags([.command, .option, .shift]).rawValue,
            isFn: false
        )
        var previewedCandidate: UnifiedHotkey?
        let model = makeModel(
            editingHotkey: stored,
            existingAssignmentDescription: { candidate in
                previewedCandidate = candidate
                return candidate == genericCandidate ? "a generic combo slot" : nil
            }
        )
        // The preview must evaluate the same side-specific candidate the real
        // click saves, not the generic one.
        XCTAssertEqual(model.state(forModifier: .keyCode(0x38)), .available)
        XCTAssertNotEqual(previewedCandidate, genericCandidate)
        model.toggleModifier(.keyCode(0x38))
        XCTAssertEqual(previewedCandidate, try XCTUnwrap(model.composedHotkey))
    }

    func testLoadFn_preselectsFn() {
        let stored = UnifiedHotkey(keyCode: 0, modifierFlags: 0, isFn: true)
        let model = makeModel(editingHotkey: stored)
        XCTAssertTrue(model.composition.isFnSelected)
        XCTAssertEqual(model.state(forModifier: .fn), .active)
    }

    func testLoadMouseButton_leavesEmpty() {
        let stored = UnifiedHotkey(mouseButton: 2)
        let model = makeModel(editingHotkey: stored)
        XCTAssertNil(model.composedHotkey)
        XCTAssertFalse(model.canSave)
    }

    // MARK: - Key states

    func testEscapeBare_isReservedAndIgnored() {
        let model = makeModel()
        XCTAssertEqual(model.state(forKey: 0x35), .reserved)
        model.toggleKey(0x35)
        XCTAssertNil(model.composition.keyCode)
        XCTAssertFalse(model.canSave)
    }

    func testEscapeWithModifier_isAvailable() {
        let model = makeModel()
        model.toggleModifier(.keyCode(0x37))
        // Command+Escape is recordable; only the bare key cancels recording.
        XCTAssertEqual(model.state(forKey: 0x35), .available)
    }

    func testEscapeDeselectedCommand_cannotSave() {
        let model = makeModel()
        model.toggleModifier(.keyCode(0x37))
        model.toggleKey(0x35)
        XCTAssertTrue(model.canSave)
        // Removing the modifier strands a bare Escape the recorder cannot
        // capture: the key is dropped and saving is disallowed.
        model.toggleModifier(.keyCode(0x37))
        XCTAssertNil(model.composition.keyCode)
        XCTAssertEqual(model.state(forKey: 0x35), .reserved)
        XCTAssertFalse(model.canSave)
    }

    func testEscapeDeselectedFn_cannotSave() {
        let model = makeModel()
        model.toggleModifier(.fn)
        model.toggleKey(0x35)
        XCTAssertTrue(model.canSave)
        model.toggleModifier(.fn)
        XCTAssertNil(model.composition.keyCode)
        XCTAssertFalse(model.canSave)
    }

    func testConflictingKey_reportsAssignment() {
        let model = makeModel(existingAssignmentDescription: { candidate in
            candidate.keyCode == 0x01 ? "the Toggle shortcut" : nil
        })
        XCTAssertEqual(
            model.state(forKey: 0x01),
            .conflicting(assignment: "the Toggle shortcut")
        )
        XCTAssertEqual(model.state(forKey: 0x02), .available)
    }

    func testEditingHotkey_neverConflictsWithItself() {
        // Even a conflict check that flags everything must stay silent for the
        // hotkey being edited.
        let model = makeModel(
            editingHotkey: commandA(),
            existingAssignmentDescription: { _ in "everything" }
        )
        XCTAssertNil(model.conflictNotice)
    }

    func testEditingHotkey_conflictingButDifferentCandidate_surfacesNotice() throws {
        // Regression: conflictDescription suppressed via conflicts(with:),
        // which also matched the opposite tap mode of the same combo and hid
        // its genuine conflict. Only the exact hotkey being edited is
        // suppressed now.
        let editing = commandA()
        let model = makeModel(
            editingHotkey: editing,
            existingAssignmentDescription: { candidate in
                // Another slot genuinely holds double-tap Command+A.
                candidate.isDoubleTap && candidate.keyCode == 0x00 ? "the Push-to-Talk shortcut" : nil
            }
        )
        // The composition starts as the editing hotkey (single-tap).
        XCTAssertNil(model.conflictNotice)
        // Switching to double-tap: it conflicts with the editing hotkey but
        // is a different hotkey, so its real conflict must surface.
        model.toggleDoubleTap()
        let candidate = try XCTUnwrap(model.composedHotkey)
        XCTAssertTrue(editing.conflicts(with: candidate))
        XCTAssertNotEqual(candidate, editing)
        XCTAssertEqual(model.conflictNotice, "the Push-to-Talk shortcut")
    }

    func testComposedConflict_surfacesNotice() {
        let model = makeModel(existingAssignmentDescription: { candidate in
            candidate.keyCode == 0x00 ? "the Toggle shortcut" : nil
        })
        model.toggleModifier(.keyCode(0x37))
        model.toggleKey(0x00)
        XCTAssertEqual(model.conflictNotice, "the Toggle shortcut")
        // Saving stays possible: the recorder's onRecord path resolves it.
        XCTAssertTrue(model.canSave)
    }

    // MARK: - Same source of truth as the recorder

    func testRecorderParity_conflictsMatchRecorderLogic() {
        // Assignments as the recorder would have stored them.
        let assignments = [commandA()]
        let check: (UnifiedHotkey) -> String? = { candidate in
            assignments.contains(where: { $0.conflicts(with: candidate) }) ? "slot" : nil
        }
        let model = makeModel(existingAssignmentDescription: check)

        // Composing Command+A through clicks must hit the recorder's conflict.
        model.toggleModifier(.keyCode(0x37))
        XCTAssertEqual(model.state(forKey: 0x00), .conflicting(assignment: "slot"))

        // And a non-conflicting key stays available.
        XCTAssertEqual(model.state(forKey: 0x01), .available)
    }

    // MARK: - Layout

    func testAnsiLayout_excludesIsoKey() {
        let rows = VisualShortcutKeyboardModel.keyLayout(for: .ansi)
        XCTAssertFalse(rows.contains(where: { $0.keyCode == 0x0A }))
    }

    func testIsoLayout_placesSectionAboveTabAndGraveBesideShift() throws {
        let keys = VisualShortcutKeyboardModel.keyLayout(for: .iso)
        let section = try XCTUnwrap(keys.first(where: { $0.keyCode == 0x0A }))
        let grave = try XCTUnwrap(keys.first(where: { $0.keyCode == 0x32 }))
        let tab = try XCTUnwrap(keys.first(where: { $0.keyCode == 0x30 }))
        let shift = try XCTUnwrap(keys.first(where: { $0.content == .modifier(.keyCode(0x38)) }))
        XCTAssertEqual(section.x, tab.x)
        XCTAssertEqual(section.y + 1, tab.y)
        XCTAssertEqual(grave.x, shift.x + shift.width)
        XCTAssertEqual(grave.y, shift.y)
    }

    func testPhysicalLayouts_haveUniqueBoundedNonoverlappingHitTargets() {
        for kind in VisualKeyboardLayoutKind.allCases {
            let keys = VisualShortcutKeyboardModel.keyLayout(for: kind)
            XCTAssertEqual(Set(keys.map(\.id)).count, keys.count)
            let bounds = CGRect(x: 0, y: 0, width: VisualShortcutKeyboardModel.keyboardWidth,
                                height: VisualShortcutKeyboardModel.keyboardHeight)
            var hitRegions: [(VisualKey.Content, CGRect)] = []
            for key in keys {
                let frame = CGRect(x: key.x, y: key.y, width: key.width, height: key.height)
                XCTAssertTrue(bounds.contains(frame), "Out-of-bounds key: \(key.content)")
                if key.isTallReturn {
                    hitRegions.append((key.content, CGRect(x: key.x, y: key.y, width: key.width, height: 1)))
                    hitRegions.append((key.content, CGRect(x: key.x + 0.25, y: key.y + 1,
                                                         width: key.width - 0.25, height: 1)))
                } else {
                    hitRegions.append((key.content, frame))
                }
            }
            for first in hitRegions.indices {
                for second in hitRegions.indices where second > first {
                    let overlap = hitRegions[first].1.intersection(hitRegions[second].1)
                    XCTAssertTrue(overlap.isNull || overlap.width < 0.0001 || overlap.height < 0.0001,
                                  "Overlapping keys: \(hitRegions[first].0), \(hitRegions[second].0)")
                }
            }
        }
    }

    func testKeyLabel_usesInjectedResolver() {
        let model = makeModel()
        XCTAssertEqual(model.keyLabel(0x00), "K0")
    }

    func testInputSourceChange_updatesLabelsAndGeometryWithoutChangingShortcut() {
        var source = VisualKeyboardInputSource(layoutKind: .iso, name: "Deutsch", keyLabels: [0x10: "Z"])
        let model = VisualShortcutKeyboardModel(inputSourceProvider: { source })
        model.toggleModifier(.keyCode(0x36))
        model.toggleKey(0x10)
        model.toggleDoubleTap()
        let hotkey = model.composedHotkey
        XCTAssertEqual(model.keyLabel(0x10), "Z")

        source = VisualKeyboardInputSource(layoutKind: .ansi, name: "U.S.", keyLabels: [0x10: "Y"])
        model.refreshInputSource()
        XCTAssertEqual(model.layoutKind, .ansi)
        XCTAssertEqual(model.inputSource.name, "U.S.")
        XCTAssertEqual(model.keyLabel(0x10), "Y")
        XCTAssertEqual(model.composedHotkey, hotkey)

        source = VisualKeyboardInputSource(layoutKind: .jis, name: "日本語", keyLabels: [0x10: "ん"])
        model.refreshInputSource()
        XCTAssertEqual(model.layoutKind, .jis)
        XCTAssertEqual(model.keyLabel(0x10), "ん")
        XCTAssertEqual(model.composedHotkey, hotkey)
    }

    func testSystemKeycaps_resolveGermanAndUSWithoutChangingInputSource() throws {
        func data(for sourceID: String) throws -> CFData {
            let filter = [kTISPropertyInputSourceID as String: sourceID] as CFDictionary
            let sources = TISCreateInputSourceList(filter, true).takeRetainedValue() as! [TISInputSource]
            let source = try XCTUnwrap(sources.first)
            let property = try XCTUnwrap(TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData))
            return unsafeBitCast(property, to: CFData.self)
        }
        let german = try data(for: "com.apple.keylayout.German")
        let us = try data(for: "com.apple.keylayout.US")
        let type = UInt32(LMGetKbdType())
        XCTAssertEqual(HotkeyService.keycapName(for: 0x10, layoutData: german, keyboardType: type), "Z")
        XCTAssertEqual(HotkeyService.keycapName(for: 0x10, layoutData: us, keyboardType: type), "Y")
        XCTAssertEqual(HotkeyService.keycapName(for: 0x1B, layoutData: german, keyboardType: type), "ß")
        XCTAssertEqual(HotkeyService.keycapName(for: 0x35, layoutData: us, keyboardType: type), "⎋")
    }

    func testJisLayout_keepsLanguageKeysAndAllModifiersReachable() throws {
        let keys = VisualShortcutKeyboardModel.keyLayout(for: .jis)
        for code: UInt16 in [0x5D, 0x5E, 0x66, 0x68] {
            XCTAssertTrue(keys.contains(where: { $0.keyCode == code }))
        }
        let space = try XCTUnwrap(keys.first(where: { $0.keyCode == 0x31 }))
        let eisu = try XCTUnwrap(keys.first(where: { $0.keyCode == 0x66 }))
        let kana = try XCTUnwrap(keys.first(where: { $0.keyCode == 0x68 }))
        XCTAssertEqual(eisu.x + eisu.width, space.x)
        XCTAssertEqual(space.x + space.width, kana.x)
        // Right Option and Right Control are provided in More Keys on JIS.
        for code: UInt16 in [0x37, 0x36, 0x38, 0x3C, 0x3A, 0x3B] {
            XCTAssertTrue(keys.contains(where: { $0.content == .modifier(.keyCode(code)) }))
        }
    }

    func testRealKeyName_resolves() {
        // Exercises the production label resolver used by default.
        XCTAssertEqual(HotkeyService.keyName(for: 0x00), "A")
        XCTAssertEqual(HotkeyService.keyName(for: 0x3D), String(localized: "Right Option"))
    }
}
