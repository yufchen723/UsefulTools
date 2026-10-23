#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
QA_DIR="$PWD/build/qa"
mkdir -p "$QA_DIR"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
TEST_APP="$TEST_DIR/OrbStyleCheck.app"
mkdir -p "$TEST_APP/Contents/MacOS" "$TEST_APP/Contents/Resources"
cp src/orb.html "$TEST_APP/Contents/Resources/"
python3 - "$TEST_DIR/main.swift" "$TEST_APP/Contents/Info.plist" <<'PY'
import sys,plistlib
from pathlib import Path
s=Path('src/main.swift').read_text();s=s[:s.index('func orbLog(')]
s=s.replace('UserDefaults.standard','UserDefaults(suiteName: "com.claudemonitor.style-check.preferences")!').replace('"ClaudeUsageOrbFrame"','"OrbStyleCheckFrame"')
Path(sys.argv[1]).write_text(s+Path('tests/native-ui.swift').read_text())
Path(sys.argv[2]).write_bytes(plistlib.dumps(dict(CFBundleIdentifier='com.claudemonitor.style-check',CFBundleExecutable='check',CFBundlePackageType='APPL',LSUIElement=True)))
PY
xcrun swiftc -module-cache-path /tmp/orb-module-cache "$TEST_DIR/main.swift" -o "$TEST_APP/Contents/MacOS/check" -framework Cocoa -framework WebKit
codesign --force --deep -s - "$TEST_APP"
"$TEST_APP/Contents/MacOS/check" "$QA_DIR"
