#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_BUILD="$TASK_ROOT/.build/native"
xcrun swiftc -O -target arm64-apple-macosx14.0 -module-cache-path "$TASK_BUILD/module-cache" -I "$TASK_BUILD" -L "$TASK_BUILD" -lPageArchiveCore -Xlinker -rpath -Xlinker @loader_path "$TASK_ROOT"/Tests/PageArchiveCoreTests/*.swift -o "$TASK_BUILD/shiye-tests"
TASK_TEST_ROOT="$(mktemp -d "$TASK_ROOT/.build/checks.XXXXXX")"
"$TASK_BUILD/shiye-tests" "$TASK_TEST_ROOT"
cp "$TASK_TEST_ROOT/test-results.json" "$TASK_ROOT/.build/test-results.json"
