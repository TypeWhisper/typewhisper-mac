#!/usr/bin/env python3
"""执行真实听写，并核对临时文稿正文与听写回执。"""

import argparse
import ctypes
import json
from pathlib import Path
import subprocess
import sys
import time


def apple_script(source):
    return subprocess.run(
        ["osascript", "-e", source], check=True, capture_output=True, text=True
    ).stdout.removesuffix("\n")


def press_fn():
    cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
    cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    cg.CGEventCreateKeyboardEvent.argtypes = [ctypes.c_void_p, ctypes.c_ushort, ctypes.c_bool]
    cg.CGEventCreateKeyboardEvent.restype = ctypes.c_void_p
    cg.CGEventSetType.argtypes = [ctypes.c_void_p, ctypes.c_uint]
    cg.CGEventSetFlags.argtypes = [ctypes.c_void_p, ctypes.c_ulonglong]
    cg.CGEventPost.argtypes = [ctypes.c_uint, ctypes.c_void_p]
    cf.CFRelease.argtypes = [ctypes.c_void_p]
    for down in [True, False]:
        event = cg.CGEventCreateKeyboardEvent(None, 63, down)
        cg.CGEventSetType(event, 12)
        cg.CGEventSetFlags(event, 1 << 23 if down else 0)
        cg.CGEventPost(0, event)
        cf.CFRelease(event)
        time.sleep(0.1)


def exercise(args, output_directory, readback):
    output_directory.mkdir(parents=True, exist_ok=True)
    before = apple_script(readback)
    command = [str(Path(__file__).with_name("dictum-verify.sh")), "dictate", str(args.audio.resolve())]
    if args.hotkey:
        command.append("hotkey")
    elif args.paste_receipt:
        command.append("paste")
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    if args.hotkey:
        time.sleep(1)
        press_fn()
        time.sleep(args.record_seconds)
        press_fn()
    stdout, stderr = process.communicate()
    (output_directory / "dictate.log").write_text(stdout + stderr)
    try:
        receipt = json.loads(stdout)
    except json.JSONDecodeError:
        print(stdout + stderr, end="")
        return process.returncode or 1, None
    after = apple_script(readback)
    (output_directory / "before.txt").write_text(before)
    (output_directory / "readback.txt").write_text(after)
    (output_directory / "result.json").write_text(json.dumps(receipt, ensure_ascii=False, indent=2))
    transcript = receipt.get("text", "")
    proof = {
        "beforeBytes": len(before.encode()),
        "transcriptBytes": len(transcript.encode()),
        "afterBytes": len(after.encode()),
        "matchesOneTranscript": after == before + transcript,
        "matchesTwoTranscripts": after == before + transcript * 2,
        "transcriptContainsExpected": all(part in transcript for part in args.contains),
        "transcript": transcript,
        "target": receipt.get("appBundleIdentifier"),
        "insertion": receipt.get("insertion"),
        "pasteVerification": receipt.get("pasteVerification"),
        "trigger": "hotkey" if args.hotkey else "paste-receipt" if args.paste_receipt else "debug-url",
        "status": receipt["status"],
        "scriptExitCode": process.returncode,
        "engine": receipt.get("engine"),
        "model": receipt.get("model"),
        "usedLiveResult": receipt.get("usedLiveResult"),
    }
    output = json.dumps(proof, ensure_ascii=False, indent=2)
    (output_directory / "proof.json").write_text(output + "\n")
    print(output)
    expected_bundle = {"TextEdit": "com.apple.TextEdit", "Google Chrome": "com.google.Chrome"}[args.app]
    passed = process.returncode == 0 and before == "" and proof["matchesOneTranscript"] and proof["transcriptContainsExpected"] and proof["target"] == expected_bundle and (args.engine is None or proof["engine"] == args.engine)
    print("PASS" if passed else "FAIL")
    return (0 if passed else 1), after


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("audio", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--contains", action="append", default=[])
    parser.add_argument("--engine", help="要求回执中的实际引擎与此值一致")
    parser.add_argument("--app", choices=["TextEdit", "Google Chrome"], default="TextEdit")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--hotkey", action="store_true")
    mode.add_argument("--paste-receipt", action="store_true")
    parser.add_argument("--record-seconds", type=float, default=6.0)
    parser.add_argument("--repeat", type=int, default=1)
    args = parser.parse_args()
    if args.repeat < 1:
        parser.error("repeat 必须大于 0")
    if not str(args.output.resolve()).startswith(("/private/tmp/dictum-", "/tmp/dictum-")):
        parser.error("测试文稿必须放在 /tmp/dictum- 目录下")
    readback = f'''tell application "System Events" to tell process "{args.app}"
set bodyText to value of (value of attribute "AXFocusedUIElement")
if bodyText is missing value then return ""
return bodyText
end tell'''
    for index in range(args.repeat):
        directory = args.output if args.repeat == 1 else args.output / f"run-{index + 1:03}"
        directory.mkdir(parents=True, exist_ok=True)
        target = directory / ("target.txt" if args.app == "TextEdit" else "target.html")
        if target.exists():
            raise RuntimeError(f"测试文稿已经存在：{target}")
        target.write_text("" if args.app == "TextEdit" else '<textarea autofocus style="position:fixed;inset:0;width:100%;height:100%;box-sizing:border-box"></textarea>')
        subprocess.run(["open", "-a", args.app, str(target.resolve())], check=True)
        time.sleep(0.6)
        apple_script(f'tell application "System Events" to tell process "{args.app}" to set frontmost to true\ndelay 0.5')
        if apple_script('tell application "System Events" to get name of first application process whose frontmost is true') != args.app:
            raise RuntimeError("目标应用没有获得前台焦点")
        try:
            status, _ = exercise(args, directory, readback)
        finally:
            if args.app == "Google Chrome":
                url = json.dumps(target.resolve().as_uri())
                apple_script(f'tell application "Google Chrome"\nrepeat with w in windows\nrepeat with t in tabs of w\nif URL of t is {url} then close t\nend repeat\nend repeat\nend tell')
            else:
                apple_script(f'tell application "System Events" to tell process "{args.app}" to set frontmost to true\ndelay 0.5')
                if apple_script('tell application "System Events" to get name of first application process whose frontmost is true') != args.app:
                    raise RuntimeError("目标应用没有获得前台焦点，停止关闭操作")
                document = apple_script('tell application "System Events" to tell process "TextEdit" to get value of attribute "AXDocument" of front window')
                if document != target.resolve().as_uri():
                    raise RuntimeError("目标文稿路径已经变化，停止关闭操作")
                apple_script('tell application "System Events" to tell process "TextEdit" to keystroke "w" using command down')
                time.sleep(0.2)
                apple_script('tell application "System Events" to tell process "TextEdit"\nif exists sheet 1 of front window then\nif exists button "不存储" of sheet 1 of front window then\nclick button "不存储" of sheet 1 of front window\nelse if exists button "Don’t Save" of sheet 1 of front window then\nclick button "Don’t Save" of sheet 1 of front window\nelse\nerror "无法确认关闭测试文稿"\nend if\nend if\nend tell')
            (directory / "closed.json").write_text(json.dumps({"target": str(target), "closedWithoutSaving": True}, ensure_ascii=False))
        if status:
            return status
    return 0


if __name__ == "__main__":
    sys.exit(main())
