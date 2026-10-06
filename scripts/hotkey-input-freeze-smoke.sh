#!/usr/bin/env bash
# Check that the real HotkeyService event tap keeps system input flowing while
# its main thread stalls. Needs a locally trusted terminal. For about eight
# seconds it posts F18 presses and repeatedly blocks the main thread for 1.5 s;
# typing during that time may lag by up to the tap's decision timeout.
#   scripts/hotkey-input-freeze-smoke.sh [path/to/HotkeyService.swift]
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
service_source="${1:-$repo_root/TypeWhisper/Services/HotkeyService.swift}"
smoke_dir="$(mktemp -d "${TMPDIR:-/tmp}/hotkey-input-freeze-smoke.XXXXXX")"
trap 'rm -rf "$smoke_dir"' EXIT

python3 - "$repo_root" "$service_source" "$smoke_dir/main.swift" <<'PY'
from pathlib import Path
import sys
import re
root = Path(sys.argv[1])
workflow = (root / "TypeWhisper/Models/Workflow.swift").read_text()
start = workflow.index("enum WorkflowHotkeyBehavior:")
end = workflow.index("\nstruct WorkflowTrigger:", start)
# Compile the production service verbatim, as hotkey-recovery-smoke.sh does.
source = '''import Foundation
import AppKit
import ApplicationServices
enum AppConstants { static let loggerSubsystem = "com.typewhisper.hotkey-input-freeze-smoke" }
func localizedAppText(_ text: String, de: String) -> String { text }
'''
insertion = (root / "TypeWhisper/Services/TextInsertionService.swift").read_text()
markers = re.findall(r"(?:nonisolated )?static let simulated\w+EventMarker[^\n]+", insertion)
source += "enum TextInsertionService { " + "\n".join(markers) + " }\n"
source += (root / "TypeWhisper/App/UserDefaultsKeys.swift").read_text()
source += workflow[start:end]
source += Path(sys.argv[2]).read_text()
source += '''
setvbuf(stdout, nil, _IONBF, 0)
alarm(30) // never leave a stalled filter tap behind
nonisolated(unsafe) let duration: TimeInterval = 8
nonisolated(unsafe) let probeTag: Int64 = 0x5A << 56

guard CGPreflightPostEventAccess(), AXIsProcessTrusted() else {
    print("FAIL: Terminal needs Accessibility permission to create and post to a real event tap")
    exit(1)
}

@Sendable nonisolated func uptimeMicros() -> Int64 { Int64(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000) }

final class Latencies: @unchecked Sendable {
    let lock = NSLock()
    var values: [Double] = []
}
nonisolated(unsafe) let latencies = Latencies()

// A listen-only tail tap on its own thread sees each probe event once the session's
// filter taps, including the service's head-inserted tap, have let it through.
let probeReady = DispatchSemaphore(value: 0)
let probeThread = Thread {
    let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
        eventsOfInterest: mask,
        callback: { _, _, event, info in
            let tag = event.getIntegerValueField(.eventSourceUserData)
            guard tag >> 56 == 0x5A, let info else { return Unmanaged.passUnretained(event) }
            let latencies = Unmanaged<Latencies>.fromOpaque(info).takeUnretainedValue()
            let sent = tag & 0x00FF_FFFF_FFFF_FFFF
            latencies.lock.withLock { latencies.values.append(Double(uptimeMicros() - sent) / 1000) }
            return Unmanaged.passUnretained(event)
        },
        userInfo: Unmanaged.passUnretained(latencies).toOpaque()
    ) else {
        print("FAIL: could not create the probe tap")
        exit(1)
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    probeReady.signal()
    CFRunLoopRun()
}
probeThread.qualityOfService = .userInteractive
probeThread.start()
probeReady.wait()

NSApplication.shared.setActivationPolicy(.prohibited)
let service = HotkeyService()
// Right Option push-to-talk, the shortcut from the original freeze report.
service.setHotkeyForTesting(UnifiedHotkey(keyCode: 61, modifierFlags: 0, isFn: false), for: .pushToTalk)
service.resumeMonitoring()
precondition(service.isEventTapEnabledForTesting, "The service did not install its event tap")

// Stall the main thread for 1.5 s with short responsive gaps in between.
Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in usleep(1_500_000) }

nonisolated(unsafe) let posted = DispatchSemaphore(value: 0)
final class Counter: @unchecked Sendable { var value = 0 }
nonisolated(unsafe) let sentCount = Counter()
DispatchQueue.global(qos: .userInitiated).async {
    let deadline = Date().addingTimeInterval(duration)
    while Date() < deadline {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 79 /* F18 */, keyDown: down)!
            event.setIntegerValueField(.eventSourceUserData, value: probeTag | uptimeMicros())
            event.post(tap: .cghidEventTap)
            sentCount.value += 1
        }
        usleep(100_000)
    }
    Thread.sleep(forTimeInterval: 2)
    posted.signal()
}
while posted.wait(timeout: .now()) == .timedOut {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}
service.suspendMonitoring()

let values = latencies.lock.withLock { latencies.values.sorted() }
let maxLatency = values.last ?? .infinity
print(String(format: "received %d/%d probe events, p50 %.1f ms, max %.1f ms",
             values.count, sentCount.value, values.isEmpty ? -1 : values[values.count / 2], maxLatency))
guard values.count == sentCount.value, maxLatency < 500 else {
    print("FAIL: a stalled main thread held back system input")
    exit(1)
}
print("PASS: input kept flowing while the HotkeyService main thread stalled")
'''
Path(sys.argv[3]).write_text(source)
PY
swiftc -swift-version 6 -D DEBUG -O "$smoke_dir/main.swift" -o "$smoke_dir/smoke"
"$smoke_dir/smoke"
