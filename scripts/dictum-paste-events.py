#!/usr/bin/env python3
"""在指定时长内被动记录 Cmd+V 事件来源。需要 PyObjC Quartz。"""

import argparse
import json
import time

import Quartz


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--seconds", type=float, default=60)
args = parser.parse_args()
sequence = 0


def receive(proxy, event_type, event, context):
    global sequence
    if event_type in (Quartz.kCGEventTapDisabledByTimeout, Quartz.kCGEventTapDisabledByUserInput):
        Quartz.CGEventTapEnable(tap, True)
        return event
    if Quartz.CGEventGetIntegerValueField(event, Quartz.kCGKeyboardEventKeycode) != 9:
        return event
    if not Quartz.CGEventGetFlags(event) & Quartz.kCGEventFlagMaskCommand:
        return event
    if event_type == Quartz.kCGEventKeyDown:
        sequence += 1
    marker = Quartz.CGEventGetIntegerValueField(event, Quartz.kCGEventSourceUserData)
    print(json.dumps({
        "time": time.time(),
        "eventTimestamp": Quartz.CGEventGetTimestamp(event),
        "type": event_type,
        "sourcePID": Quartz.CGEventGetIntegerValueField(event, Quartz.kCGEventSourceUnixProcessID),
        "targetPID": Quartz.CGEventGetIntegerValueField(event, Quartz.kCGEventTargetUnixProcessID),
        "marker": marker,
        "sequence": sequence,
        "codePath": "TextInsertionService.simulatePaste" if marker == 0x5457434C49504244 else "external",
        "autorepeat": Quartz.CGEventGetIntegerValueField(event, Quartz.kCGKeyboardEventAutorepeat),
    }), flush=True)
    return event


tap = Quartz.CGEventTapCreate(
    Quartz.kCGSessionEventTap, Quartz.kCGTailAppendEventTap,
    Quartz.kCGEventTapOptionListenOnly,
    (1 << Quartz.kCGEventKeyDown) | (1 << Quartz.kCGEventKeyUp), receive, None,
)
if tap is None:
    raise RuntimeError("无法创建被动事件监听器，请检查现有的输入监控权限。")
source = Quartz.CFMachPortCreateRunLoopSource(None, tap, 0)
Quartz.CFRunLoopAddSource(Quartz.CFRunLoopGetCurrent(), source, Quartz.kCFRunLoopCommonModes)
Quartz.CGEventTapEnable(tap, True)
print("READY", flush=True)
deadline = time.monotonic() + args.seconds
while time.monotonic() < deadline:
    Quartz.CFRunLoopRunInMode(Quartz.kCFRunLoopDefaultMode, 0.25, False)
Quartz.CGEventTapEnable(tap, False)
