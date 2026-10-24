import AppKit
import XCTest
@testable import TypeWhisper

/// Fn + 左 Shift 启动翻译会话；只有 Fn 是听写；Shift 单独或右 Shift 什么也不做。
@MainActor
final class TranslationHotkeyTests: XCTestCase {
    private let fnKey: CGKeyCode = 63
    private let leftShift: CGKeyCode = 0x38
    private let rightShift: CGKeyCode = 0x3C
    private let deviceLeftShift: UInt64 = 0x2
    private let deviceRightShift: UInt64 = 0x4

    private var service: HotkeyService!
    private var dictationStarts = 0
    private var translationStarts = 0
    private var upgrades = 0
    private var stops = 0

    override func setUp() {
        super.setUp()
        service = HotkeyService()
        service.suspendMonitoring()
        for slot in HotkeySlotType.allCases { service.setHotkeysForTesting([], for: slot) }
        service.setHotkeyForTesting(UnifiedHotkey(keyCode: 63, modifierFlags: 0, isFn: true), for: .hybrid)
        service.setHotkeyForTesting(HotkeyService.defaultTranslationHotkey, for: .translation)
        service.modifierFlagsStateProvider = { [] }
        dictationStarts = 0; translationStarts = 0; upgrades = 0; stops = 0
        service.onDictationStart = { [unowned self] _ in dictationStarts += 1 }
        service.onTranslationDictationStart = { [unowned self] _ in translationStarts += 1 }
        service.onDictationModeUpgrade = { [unowned self] in upgrades += 1 }
        service.onDictationStop = { [unowned self] in stops += 1 }
    }

    override func tearDown() {
        service.suspendMonitoring()
        service = nil
        super.tearDown()
    }

    private func flagsChanged(_ key: CGKeyCode, down: Bool, flags: CGEventFlags, device: UInt64 = 0) throws {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down))
        event.type = .flagsChanged
        event.flags = CGEventFlags(rawValue: flags.rawValue | device)
        _ = service.processEventForTesting(try XCTUnwrap(NSEvent(cgEvent: event)), source: .monitor)
    }

    private func keyDown(_ key: CGKeyCode, flags: CGEventFlags) throws {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true))
        event.flags = flags
        _ = service.processEventForTesting(try XCTUnwrap(NSEvent(cgEvent: event)), source: .monitor)
    }

    private func keyUp(_ key: CGKeyCode, flags: CGEventFlags) throws {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false))
        event.flags = flags
        _ = service.processEventForTesting(try XCTUnwrap(NSEvent(cgEvent: event)), source: .monitor)
    }

    private func useToggleShortcutAsTheDictationShortcut() {
        service.setHotkeysForTesting([], for: .hybrid)
        service.setHotkeyForTesting(UnifiedHotkey(keyCode: 63, modifierFlags: 0, isFn: true), for: .toggle)
    }

    /// 轻按 Fn + 左 Shift，进入轻按切换的翻译会话。
    private func tapFnAndLeftShift() throws {
        try flagsChanged(fnKey, down: true, flags: .maskSecondaryFn)
        try flagsChanged(leftShift, down: true, flags: [.maskSecondaryFn, .maskShift], device: deviceLeftShift)
        try flagsChanged(leftShift, down: false, flags: .maskSecondaryFn)
        try flagsChanged(fnKey, down: false, flags: [])
    }

    func testFnAloneStartsDictation() throws {
        try flagsChanged(fnKey, down: true, flags: .maskSecondaryFn)
        XCTAssertEqual(dictationStarts, 1)
        XCTAssertEqual(translationStarts, 0)
        XCTAssertEqual(upgrades, 0)
    }

    func testFnThenLeftShiftUpgradesTheSessionToTranslation() throws {
        try flagsChanged(fnKey, down: true, flags: .maskSecondaryFn)
        try flagsChanged(leftShift, down: true, flags: [.maskSecondaryFn, .maskShift], device: deviceLeftShift)
        XCTAssertEqual(dictationStarts, 1)
        XCTAssertEqual(upgrades, 1)
        XCTAssertEqual(stops, 0)
    }

    func testLeftShiftThenFnUpgradesTheSessionToTranslation() throws {
        try flagsChanged(leftShift, down: true, flags: .maskShift, device: deviceLeftShift)
        XCTAssertEqual(dictationStarts + translationStarts, 0, "左 Shift 单独不触发")
        try flagsChanged(fnKey, down: true, flags: [.maskSecondaryFn, .maskShift], device: deviceLeftShift)
        XCTAssertEqual(dictationStarts, 1)
        XCTAssertEqual(upgrades, 1)
    }

    func testTranslationShortcutStartsATranslationSessionWithoutTheDictationShortcut() throws {
        service.setHotkeysForTesting([], for: .hybrid)
        try flagsChanged(fnKey, down: true, flags: .maskSecondaryFn)
        XCTAssertEqual(translationStarts + dictationStarts, 0, "Fn 单独不触发翻译")
        try flagsChanged(leftShift, down: true, flags: [.maskSecondaryFn, .maskShift], device: deviceLeftShift)
        XCTAssertEqual(translationStarts, 1)
        XCTAssertEqual(dictationStarts, 0)
    }

    func testShiftAloneAndRightShiftDoNothing() throws {
        try flagsChanged(leftShift, down: true, flags: .maskShift, device: deviceLeftShift)
        try flagsChanged(leftShift, down: false, flags: [])
        try keyDown(0, flags: .maskShift)
        try flagsChanged(rightShift, down: true, flags: .maskShift, device: deviceRightShift)
        try flagsChanged(rightShift, down: false, flags: [])
        XCTAssertEqual(dictationStarts + translationStarts + upgrades + stops, 0)
    }

    func testFnWithRightShiftIsPlainDictation() throws {
        try flagsChanged(rightShift, down: true, flags: .maskShift, device: deviceRightShift)
        try flagsChanged(fnKey, down: true, flags: [.maskSecondaryFn, .maskShift], device: deviceRightShift)
        XCTAssertEqual(dictationStarts, 1)
        XCTAssertEqual(upgrades, 0)
        XCTAssertEqual(translationStarts, 0)
    }

    func testTapStartsToggleTranslationAndFnStopsIt() throws {
        try flagsChanged(fnKey, down: true, flags: .maskSecondaryFn)
        try flagsChanged(leftShift, down: true, flags: [.maskSecondaryFn, .maskShift], device: deviceLeftShift)
        try flagsChanged(leftShift, down: false, flags: .maskSecondaryFn)
        try flagsChanged(fnKey, down: false, flags: [])
        XCTAssertEqual(service.currentMode, .toggle, "轻按保持录音")
        XCTAssertEqual(stops, 0)
        Thread.sleep(forTimeInterval: 0.15)
        try flagsChanged(fnKey, down: true, flags: .maskSecondaryFn)
        XCTAssertEqual(stops, 1, "再按 Fn 结束")
        try flagsChanged(fnKey, down: false, flags: [])
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(dictationStarts, 1)
    }

    func testHoldToTalkStopsWhenTheCombinationIsReleased() throws {
        try flagsChanged(fnKey, down: true, flags: .maskSecondaryFn)
        try flagsChanged(leftShift, down: true, flags: [.maskSecondaryFn, .maskShift], device: deviceLeftShift)
        service.resetKeyDownTime()
        Thread.sleep(forTimeInterval: 0.4)
        try flagsChanged(leftShift, down: false, flags: .maskSecondaryFn)
        XCTAssertEqual(stops, 0)
        try flagsChanged(fnKey, down: false, flags: [])
        XCTAssertEqual(stops, 1)
    }

    func testLeftShiftAfterTheWindowDoesNotStopOrUpgrade() throws {
        try flagsChanged(fnKey, down: true, flags: .maskSecondaryFn)
        Thread.sleep(forTimeInterval: HotkeyService.translationUpgradeWindow + 0.1)
        try flagsChanged(leftShift, down: true, flags: [.maskSecondaryFn, .maskShift], device: deviceLeftShift)
        XCTAssertEqual(upgrades, 0)
        XCTAssertEqual(stops, 0)
        XCTAssertEqual(dictationStarts, 1)
    }

    func testLateLeftShiftDuringHoldToTalkKeepsTheDictationAndFnReleaseStopsIt() throws {
        try flagsChanged(fnKey, down: true, flags: .maskSecondaryFn)
        Thread.sleep(forTimeInterval: HotkeyService.translationUpgradeWindow + 0.1)
        try flagsChanged(leftShift, down: true, flags: [.maskSecondaryFn, .maskShift], device: deviceLeftShift)
        try flagsChanged(leftShift, down: false, flags: .maskSecondaryFn)
        XCTAssertEqual(stops, 0, "左 Shift 不能停止录音")
        try flagsChanged(fnKey, down: false, flags: [])
        XCTAssertEqual(stops, 1, "Fn 松开按听写结束")
        XCTAssertEqual(upgrades, 0)
        XCTAssertEqual(translationStarts, 0)
        XCTAssertEqual(dictationStarts, 1)
        XCTAssertNil(service.currentMode)
    }

    func testLateLeftShiftDuringTapModeKeepsTheDictationAndFnStopsIt() throws {
        service.setHotkeysForTesting([], for: .hybrid)
        service.setHotkeyForTesting(UnifiedHotkey(keyCode: 63, modifierFlags: 0, isFn: true), for: .toggle)
        try flagsChanged(fnKey, down: true, flags: .maskSecondaryFn)
        try flagsChanged(fnKey, down: false, flags: [])
        XCTAssertEqual(dictationStarts, 1, "Fn 松开后开始听写")
        Thread.sleep(forTimeInterval: HotkeyService.translationUpgradeWindow + 0.1)
        try flagsChanged(fnKey, down: true, flags: .maskSecondaryFn)
        try flagsChanged(leftShift, down: true, flags: [.maskSecondaryFn, .maskShift], device: deviceLeftShift)
        try flagsChanged(leftShift, down: false, flags: .maskSecondaryFn)
        XCTAssertEqual(stops, 0)
        try flagsChanged(fnKey, down: false, flags: [])
        XCTAssertEqual(stops, 1, "Fn 松开结束轻按开始的听写")
        XCTAssertEqual(upgrades, 0)
        XCTAssertEqual(translationStarts, 0)
    }

    func testHoldToTalkTranslationStopsOnceWhenFnIsReleasedBeforeShift() throws {
        try flagsChanged(fnKey, down: true, flags: .maskSecondaryFn)
        try flagsChanged(leftShift, down: true, flags: [.maskSecondaryFn, .maskShift], device: deviceLeftShift)
        service.resetKeyDownTime()
        Thread.sleep(forTimeInterval: 0.4)
        try flagsChanged(fnKey, down: false, flags: .maskShift, device: deviceLeftShift)
        XCTAssertEqual(stops, 0, "组合键两个键都松开后才结束")
        try flagsChanged(leftShift, down: false, flags: [])
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(upgrades, 1)
    }

    func testHoldToTalkTranslationWithABackupOnlyDictationShortcutStopsOnce() throws {
        service.setHotkeysForTesting([UnifiedHotkey(keyCode: 0x60, modifierFlags: 0, isFn: false)], for: .hybrid)
        try flagsChanged(fnKey, down: true, flags: .maskSecondaryFn)
        try flagsChanged(leftShift, down: true, flags: [.maskSecondaryFn, .maskShift], device: deviceLeftShift)
        XCTAssertEqual(translationStarts, 1)
        service.resetKeyDownTime()
        Thread.sleep(forTimeInterval: 0.4)
        try flagsChanged(leftShift, down: false, flags: .maskSecondaryFn)
        XCTAssertEqual(stops, 0, "组合键两个键都松开后才结束")
        try flagsChanged(fnKey, down: false, flags: [])
        XCTAssertEqual(stops, 1)
    }

    func testSessionUpgradedFromPushToTalkKeepsPushToTalkInterruption() throws {
        service.setHotkeysForTesting([], for: .hybrid)
        service.setHotkeyForTesting(UnifiedHotkey(keyCode: 63, modifierFlags: 0, isFn: true), for: .pushToTalk)
        service.discardPushToTalkRecordingOnExtraKeyPress = true
        var interruptions = 0
        service.onPushToTalkInterruption = { interruptions += 1 }
        try flagsChanged(fnKey, down: true, flags: .maskSecondaryFn)
        try flagsChanged(leftShift, down: true, flags: [.maskSecondaryFn, .maskShift], device: deviceLeftShift)
        XCTAssertEqual(upgrades, 1)
        XCTAssertEqual(interruptions, 0, "修饰键按下不算额外按键")
        try keyDown(0, flags: [.maskSecondaryFn, .maskShift])
        XCTAssertEqual(interruptions, 1)
    }

    func testSessionUpgradedFromPushToTalkStopsOnReleaseEvenAfterAQuickPress() throws {
        service.setHotkeysForTesting([], for: .hybrid)
        service.setHotkeyForTesting(UnifiedHotkey(keyCode: 63, modifierFlags: 0, isFn: true), for: .pushToTalk)
        try flagsChanged(fnKey, down: true, flags: .maskSecondaryFn)
        try flagsChanged(leftShift, down: true, flags: [.maskSecondaryFn, .maskShift], device: deviceLeftShift)
        XCTAssertEqual(upgrades, 1)
        try flagsChanged(leftShift, down: false, flags: .maskSecondaryFn)
        XCTAssertEqual(stops, 0, "组合键两个键都松开后才结束")
        try flagsChanged(fnKey, down: false, flags: [])
        XCTAssertEqual(stops, 1, "按住说话松开即结束，快速按放也不进入轻按切换")
        XCTAssertNil(service.currentMode)
    }

    /// 没有会话在进行时，按一次 Fn（按下再松开）会开始新的听写。
    private func assertNoSessionIsActive(file: StaticString = #filePath, line: UInt = #line) throws {
        Thread.sleep(forTimeInterval: 0.15)
        let startsBefore = dictationStarts
        let stopsBefore = stops
        try flagsChanged(fnKey, down: true, flags: .maskSecondaryFn)
        try flagsChanged(fnKey, down: false, flags: [])
        XCTAssertEqual(dictationStarts, startsBefore + 1, "Fn 开始新的听写", file: file, line: line)
        XCTAssertEqual(stops, stopsBefore, file: file, line: line)
    }

    func testSecondFnAndLeftShiftStopsTheToggleTranslationWithoutStartingAnother() throws {
        try tapFnAndLeftShift()
        XCTAssertEqual(service.currentMode, .toggle)
        Thread.sleep(forTimeInterval: 0.15)
        try flagsChanged(fnKey, down: true, flags: .maskSecondaryFn)
        try flagsChanged(leftShift, down: true, flags: [.maskSecondaryFn, .maskShift], device: deviceLeftShift)
        try flagsChanged(leftShift, down: false, flags: .maskSecondaryFn)
        try flagsChanged(fnKey, down: false, flags: [])
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(translationStarts, 0)
        XCTAssertEqual(dictationStarts, 1)
        XCTAssertNil(service.currentMode)
        try assertNoSessionIsActive()
    }

    func testSecondGestureWithLeftShiftBeforeFnStopsTheToggleTranslationWithoutStartingAnother() throws {
        try tapFnAndLeftShift()
        XCTAssertEqual(service.currentMode, .toggle)
        Thread.sleep(forTimeInterval: 0.15)
        try flagsChanged(leftShift, down: true, flags: .maskShift, device: deviceLeftShift)
        try flagsChanged(fnKey, down: true, flags: [.maskSecondaryFn, .maskShift], device: deviceLeftShift)
        try flagsChanged(leftShift, down: false, flags: .maskSecondaryFn)
        try flagsChanged(fnKey, down: false, flags: [])
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(translationStarts, 0)
        XCTAssertEqual(dictationStarts, 1)
        XCTAssertNil(service.currentMode)
        try assertNoSessionIsActive()
    }

    func testFnAndLeftShiftStartAfterAnEarlierFnStopHasBeenReleased() throws {
        try tapFnAndLeftShift()
        Thread.sleep(forTimeInterval: 0.15)
        try flagsChanged(fnKey, down: true, flags: .maskSecondaryFn)
        try flagsChanged(fnKey, down: false, flags: [])
        XCTAssertEqual(stops, 1, "单独的 Fn 结束翻译会话")
        Thread.sleep(forTimeInterval: 0.15)
        try flagsChanged(fnKey, down: true, flags: .maskSecondaryFn)
        try flagsChanged(leftShift, down: true, flags: [.maskSecondaryFn, .maskShift], device: deviceLeftShift)
        XCTAssertEqual(dictationStarts, 2, "新的 Fn 按下开始听写")
        XCTAssertEqual(upgrades, 2, "同一次按下里的左 Shift 升级为翻译")
        XCTAssertEqual(stops, 1)
    }

    func testSecondFnAndLeftShiftWithTheToggleShortcutStopsOnceAndFnReleaseStartsNothing() throws {
        useToggleShortcutAsTheDictationShortcut()
        try tapFnAndLeftShift()
        XCTAssertEqual(translationStarts, 1)
        XCTAssertEqual(service.currentMode, .toggle)
        Thread.sleep(forTimeInterval: 0.15)
        try flagsChanged(fnKey, down: true, flags: .maskSecondaryFn)
        try flagsChanged(leftShift, down: true, flags: [.maskSecondaryFn, .maskShift], device: deviceLeftShift)
        try flagsChanged(leftShift, down: false, flags: .maskSecondaryFn)
        try flagsChanged(fnKey, down: false, flags: [])
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(translationStarts, 1)
        XCTAssertEqual(dictationStarts, 0, "仍按住的 Fn 松开时不开始听写")
        XCTAssertNil(service.currentMode)
        try assertNoSessionIsActive()
    }

    func testTranslationWithoutADictationSessionFollowsTheToggleShortcutWhenHeld() throws {
        useToggleShortcutAsTheDictationShortcut()
        try flagsChanged(fnKey, down: true, flags: .maskSecondaryFn)
        try flagsChanged(leftShift, down: true, flags: [.maskSecondaryFn, .maskShift], device: deviceLeftShift)
        XCTAssertEqual(translationStarts, 1)
        XCTAssertEqual(service.currentMode, .toggle)
        Thread.sleep(forTimeInterval: 0.4)
        try flagsChanged(leftShift, down: false, flags: .maskSecondaryFn)
        try flagsChanged(fnKey, down: false, flags: [])
        XCTAssertEqual(stops, 0, "按住快捷键为不使用时，松开不结束翻译")
        XCTAssertEqual(service.currentMode, .toggle)
        Thread.sleep(forTimeInterval: 0.15)
        try flagsChanged(fnKey, down: true, flags: .maskSecondaryFn)
        try flagsChanged(leftShift, down: true, flags: [.maskSecondaryFn, .maskShift], device: deviceLeftShift)
        XCTAssertEqual(stops, 1, "再按 Fn + 左 Shift 结束")
    }

    func testFnAloneWithTheToggleShortcutKeepsToggleBehavior() throws {
        useToggleShortcutAsTheDictationShortcut()
        try flagsChanged(fnKey, down: true, flags: .maskSecondaryFn)
        Thread.sleep(forTimeInterval: 0.4)
        try flagsChanged(fnKey, down: false, flags: [])
        XCTAssertEqual(dictationStarts, 1)
        XCTAssertEqual(service.currentMode, .toggle)
        XCTAssertEqual(stops, 0)
        Thread.sleep(forTimeInterval: 0.15)
        try flagsChanged(fnKey, down: true, flags: .maskSecondaryFn)
        try flagsChanged(fnKey, down: false, flags: [])
        XCTAssertEqual(stops, 1)
        XCTAssertNil(service.currentMode)
    }

    func testBackupShortcutSessionUpgradedToTranslationStopsOnTheBackupShortcutRelease() throws {
        let backupKey: CGKeyCode = 0x60
        service.setHotkeysForTesting([UnifiedHotkey(keyCode: UInt16(backupKey), modifierFlags: 0, isFn: false)], for: .hybrid)
        try keyDown(backupKey, flags: [])
        XCTAssertEqual(dictationStarts, 1)
        try flagsChanged(fnKey, down: true, flags: .maskSecondaryFn)
        try flagsChanged(leftShift, down: true, flags: [.maskSecondaryFn, .maskShift], device: deviceLeftShift)
        XCTAssertEqual(upgrades, 1)
        Thread.sleep(forTimeInterval: 0.4)
        try keyUp(backupKey, flags: [.maskSecondaryFn, .maskShift])
        XCTAssertEqual(stops, 1, "备用快捷键松开时按住说话结束")
        XCTAssertNil(service.currentMode)
        try flagsChanged(leftShift, down: false, flags: .maskSecondaryFn)
        try flagsChanged(fnKey, down: false, flags: [])
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(translationStarts, 0)
    }

    func testDefaultTranslationShortcutIsFnPlusLeftShiftAndSurvivesClearing() throws {
        let defaults = UserDefaults.standard
        let slot = HotkeySlotType.translation
        defaults.removeObject(forKey: slot.hotkeysDefaultsKey)
        defaults.removeObject(forKey: slot.defaultsKey)
        let fresh = HotkeyService()
        fresh.suspendMonitoring()
        fresh.loadHotkeysForTesting()
        XCTAssertEqual(fresh.hotkeys(for: .translation), [HotkeyService.defaultTranslationHotkey])
        fresh.clearHotkey(for: .translation)
        let reopened = HotkeyService()
        reopened.suspendMonitoring()
        reopened.loadHotkeysForTesting()
        XCTAssertEqual(reopened.hotkeys(for: .translation), [], "清除后的空列表保持为空")
        defaults.removeObject(forKey: slot.hotkeysDefaultsKey)
        defaults.removeObject(forKey: slot.defaultsKey)
    }
}
