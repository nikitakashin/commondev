#!/bin/bash
set -euo pipefail

macos_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$macos_dir/Fixtures/FailingCalculator"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/commondev-demo.XXXXXX")"
trap 'rm -rf "$temporary_dir"' EXIT

swift build --package-path "$macos_dir"
binary_dir="$(swift build --package-path "$macos_dir" --show-bin-path)"
cli="$binary_dir/commondev-cli"

cp -R "$fixture" "$temporary_dir/denied"
if printf 'yes\nno\n' | "$cli" "$temporary_dir/denied" > "$temporary_dir/denied.log" 2>&1; then
    echo "The denied edit unexpectedly succeeded."
    cat "$temporary_dir/denied.log"
    exit 1
fi
cmp "$fixture/Sources/Calculator/Calculator.swift" "$temporary_dir/denied/Sources/Calculator/Calculator.swift"
if ! grep -q 'Proposed edit to' "$temporary_dir/denied.log"; then
    echo "The denied run did not reach the proposed edit."
    cat "$temporary_dir/denied.log"
    exit 1
fi
if ! grep -q 'XCTAssertEqual failed' "$temporary_dir/denied.log"; then
    echo "The initial test failed for an unexpected reason."
    cat "$temporary_dir/denied.log"
    exit 1
fi

cp -R "$fixture" "$temporary_dir/approved"
if ! printf 'yes\nyes\nyes\n' | "$cli" "$temporary_dir/approved" > "$temporary_dir/approved.log" 2>&1; then
    echo "The approved run failed."
    cat "$temporary_dir/approved.log"
    exit 1
fi
if ! grep -q 'return a + b' "$temporary_dir/approved/Sources/Calculator/Calculator.swift"; then
    echo "The approved edit was not applied."
    cat "$temporary_dir/approved.log"
    exit 1
fi
if ! grep -q 'XCTAssertEqual failed' "$temporary_dir/approved.log" || ! grep -q 'test-after' "$temporary_dir/approved.log"; then
    echo "The approved run did not demonstrate both test attempts."
    cat "$temporary_dir/approved.log"
    exit 1
fi
swift test --package-path "$temporary_dir/approved"
echo "Verified denied and approved edits."
