#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

echo "🏗️ Building Metronome (release)..."
swift build -c release

BUNDLE_DIR="$HOME/Applications/Metronome.app"
rm -rf "$BUNDLE_DIR"

echo "📦 Assembling $BUNDLE_DIR..."
mkdir -p "$BUNDLE_DIR/Contents/MacOS"
mkdir -p "$BUNDLE_DIR/Contents/Resources"

cp .build/release/Metronome "$BUNDLE_DIR/Contents/MacOS/"
cp Resources/Info.plist "$BUNDLE_DIR/Contents/"

# Ad-hoc code sign for local testing
codesign --force --sign - --options runtime "$BUNDLE_DIR" 2>/dev/null || true

echo "✅ Built: $BUNDLE_DIR"
open "$BUNDLE_DIR"
