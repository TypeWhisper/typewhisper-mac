#!/usr/bin/env python3
"""执行真实听写，并核对 TextEdit 正文与听写回执。"""

import argparse
import json
from pathlib import Path
import subprocess
import sys


def apple_script(source):
    return subprocess.run(
        ["osascript", "-e", source], check=True, capture_output=True, text=True
    ).stdout.removesuffix("\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("audio", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--contains", action="append", default=[])
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    apple_script('tell application "System Events" to tell process "TextEdit"\nset frontmost to true\nkeystroke "n" using command down\nend tell')
    readback = 'tell application "System Events" to tell process "TextEdit" to get value of text area 1 of scroll area 1 of front window'
    before = apple_script(readback)
    result = subprocess.run(
        [str(Path(__file__).with_name("dictum-verify.sh")), "dictate", str(args.audio.resolve())],
        capture_output=True, text=True,
    )
    (args.output / "dictate.log").write_text(result.stdout + result.stderr)
    if result.returncode:
        print(result.stdout + result.stderr, end="")
        return result.returncode
    receipt = json.loads(result.stdout)
    after = apple_script(readback)
    (args.output / "before.txt").write_text(before)
    (args.output / "readback.txt").write_text(after)
    (args.output / "result.json").write_text(json.dumps(receipt, ensure_ascii=False, indent=2))
    transcript = receipt["text"]
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
    }
    output = json.dumps(proof, ensure_ascii=False, indent=2)
    (args.output / "proof.json").write_text(output + "\n")
    print(output)
    passed = proof["matchesOneTranscript"] and proof["transcriptContainsExpected"]
    print("PASS" if passed else "FAIL")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
