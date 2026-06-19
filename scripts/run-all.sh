#!/usr/bin/env bash
# scripts/run-all.sh — regenerate the Xcode project and run the full
# XCTest suite. Riff.xcodeproj is .gitignored (xcodegen regenerates
# from project.yml), so a stale local project can silently miss
# newly-added source files. We always regen up front to avoid that.
#
# Exit codes:
#   0  all tests passed
#   1  xcodegen failed (e.g. yml syntax)
#   2  build failed
#   3  one or more tests failed
#
# Usage:
#   scripts/run-all.sh              # full suite
#   scripts/run-all.sh -only Foo    # filter to a specific test class / method

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# ── xcodegen ──────────────────────────────────────────────────────────
if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: xcodegen not found. Install with: brew install xcodegen" >&2
    exit 1
fi

echo "▸ Regenerating Riff.xcodeproj from project.yml…"
if ! xcodegen generate --quiet; then
    echo "error: xcodegen generate failed" >&2
    exit 1
fi

# ── Test filter ───────────────────────────────────────────────────────
# Pass `-only ClassName` or `-only ClassName/testMethod` to scope the
# run; the script translates that into xcodebuild's -only-testing flag.
TEST_FILTER_ARGS=()
if [[ "${1:-}" == "-only" && -n "${2:-}" ]]; then
    TEST_FILTER_ARGS=(-only-testing:"RiffTests/$2")
    echo "▸ Filtering to: RiffTests/$2"
fi

# ── xcodebuild test ───────────────────────────────────────────────────
echo "▸ Running tests…"
set -o pipefail
xcodebuild test \
    -project Riff.xcodeproj \
    -scheme Riff \
    -configuration Debug \
    -destination 'platform=macOS' \
    -quiet \
    "${TEST_FILTER_ARGS[@]}" \
    | tee "$REPO_ROOT/.last-test-run.log"
EXIT=$?

# xcodebuild's exit codes are mushy — distinguish "build failed" from
# "tests ran but some failed" by grepping the log. The pretty stub
# isn't perfect but it's stable across Xcode versions.
if [[ $EXIT -ne 0 ]]; then
    if grep -q "TEST FAILED" "$REPO_ROOT/.last-test-run.log"; then
        echo "✗ Tests failed. See .last-test-run.log for details." >&2
        exit 3
    else
        echo "✗ Build failed. See .last-test-run.log for details." >&2
        exit 2
    fi
fi

echo "✓ All tests passed."
exit 0
