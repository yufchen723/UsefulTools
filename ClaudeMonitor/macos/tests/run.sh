#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
python3 - "$TEST_DIR/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('src/main.swift').read_text()
a = source.index('enum CodexUsage')
b = source.index('// MARK: - Chat activity', a)
Path(sys.argv[1]).write_text('import Foundation\nimport Darwin\nfunc orbLog(_ s: String) { print(s) }\n' + source[a:b] + Path('tests/codex-usage.swift').read_text())
PY
xcrun swiftc -module-cache-path "$TEST_DIR/modules" "$TEST_DIR/main.swift" -o "$TEST_DIR/tests"
"$TEST_DIR/tests" "$@"

python3 - "$TEST_DIR/main.swift" <<'PYTHON'
from pathlib import Path
import sys
source = Path('src/main.swift').read_text()
a = source.index('final class CodexDesktopSessions')
b = source.index('// MARK: - App', a)
Path(sys.argv[1]).write_text('import Foundation\nimport SQLite3\n' + source[a:b] + Path('tests/codex-desktop.swift').read_text())
PYTHON
xcrun swiftc -module-cache-path "$TEST_DIR/modules" "$TEST_DIR/main.swift" -o "$TEST_DIR/desktop-tests"
"$TEST_DIR/desktop-tests" "$@"

python3 tests/test_codex_hook.py
