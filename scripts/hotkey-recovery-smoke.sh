#!/usr/bin/env bash
# Exercise the real HotkeyService watchdog from a locally trusted terminal.
# No keyboard events are injected or consumed; the temporary tap is listen-only.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
smoke_dir="$(mktemp -d "${TMPDIR:-/tmp}/hotkey-recovery-smoke.XXXXXX")"
trap 'rm -rf "$smoke_dir"' EXIT

python3 - "$repo_root" "$smoke_dir/main.swift" <<'PY'
from pathlib import Path
import sys
import re
root = Path(sys.argv[1])
workflow = (root / "TypeWhisper/Models/Workflow.swift").read_text()
start = workflow.index("enum WorkflowHotkeyBehavior:")
end = workflow.index("\nstruct WorkflowTrigger:", start)
# Compile the production service and enum verbatim. Only app-wide logging and
# display-localization dependencies are replaced; no recovery logic is copied.
source = '''import Foundation
import AppKit
import ApplicationServices
enum AppConstants { static let loggerSubsystem = "com.typewhisper.hotkey-recovery-smoke" }
func localizedAppText(_ text: String, de: String) -> String { text }
'''
insertion = (root / "TypeWhisper/Services/TextInsertionService.swift").read_text()
marker = re.search(r"(?:nonisolated )?static let simulatedReturnEventMarker[^\n]+", insertion).group(0)
source += "enum TextInsertionService { " + marker + " }\n"
source += (root / "TypeWhisper/App/UserDefaultsKeys.swift").read_text()
source += workflow[start:end]
source += (root / "TypeWhisper/Services/HotkeyService.swift").read_text()
source += '''
let service = HotkeyService()
let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
    eventsOfInterest: mask,
    callback: { _, _, event, _ in Unmanaged.passUnretained(event) }, userInfo: nil
) else {
    print("FAIL: Terminal needs Accessibility/Input Monitoring permission to create a real event tap")
    exit(1)
}
service.installWatchdogTapForTesting(tap)
CGEvent.tapEnable(tap: tap, enable: false)
precondition(!service.isEventTapEnabledForTesting)
let recovered = DispatchSemaphore(value: 0)
DispatchQueue.global().async { [service] in
    for _ in 0..<100 {
        if service.isEventTapEnabledForTesting {
            recovered.signal()
            return
        }
        Thread.sleep(forTimeInterval: 0.01)
    }
}
// Block the main thread instead of pumping its run loop. Only the actual
// DispatchSourceTimer on the watchdog queue can re-enable this CGEventTap.
let result = recovered.wait(timeout: .now() + 2)
let enabled = service.isEventTapEnabledForTesting
service.suspendMonitoring()
precondition(result == .success && enabled, "Background watchdog failed during main-thread stall")
precondition(!CFMachPortIsValid(tap), "Suspension must invalidate the tap")
print("PASS: real CGEventTap re-enabled by background watchdog while main thread was blocked")
print("PASS: suspension invalidated the real tap")
'''
Path(sys.argv[2]).write_text(source)
PY
swift -swift-version 6 -D DEBUG "$smoke_dir/main.swift"
