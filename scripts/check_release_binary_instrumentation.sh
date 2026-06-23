#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <binary-path> | --self-test" >&2
}

contains_llvm_instrumentation() {
  grep -E '(^|[[:space:]])__llvm_(prf|cov)[[:alnum:]_]*([[:space:]]|$)' >/dev/null
}

self_test() {
  local clean_output instrumented_output
  clean_output=$'Load command 0\n      cmd LC_SEGMENT_64\n  sectname __text\n   segname __TEXT\n  sectname __swift5_types\n   segname __TEXT'
  instrumented_output=$'Load command 1\n      cmd LC_SEGMENT_64\n  sectname __llvm_prf_cnts\n   segname __DATA\n  sectname __llvm_covmap\n   segname __LLVM'

  if printf '%s\n' "$clean_output" | contains_llvm_instrumentation; then
    echo "self-test failed: clean fixture was flagged as instrumented" >&2
    return 1
  fi

  if ! printf '%s\n' "$instrumented_output" | contains_llvm_instrumentation; then
    echo "self-test failed: instrumented fixture was not flagged" >&2
    return 1
  fi

  echo "release binary instrumentation self-test passed"
}

if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

if [[ "$1" == "--self-test" ]]; then
  self_test
  exit 0
fi

binary_path="$1"
if [[ ! -f "$binary_path" ]]; then
  echo "error: binary not found: $binary_path" >&2
  exit 2
fi

if ! otool_output="$(otool -l "$binary_path" 2>&1)"; then
  echo "error: failed to inspect binary with otool: $binary_path" >&2
  printf '%s\n' "$otool_output" >&2
  exit 2
fi

if printf '%s\n' "$otool_output" | contains_llvm_instrumentation; then
  echo "error: release binary contains LLVM coverage/profile instrumentation: $binary_path" >&2
  printf '%s\n' "$otool_output" | grep -E '(^|[[:space:]])__llvm_(prf|cov)[[:alnum:]_]*([[:space:]]|$)' >&2
  exit 1
fi

echo "release binary instrumentation check passed: $binary_path"
