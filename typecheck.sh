#!/bin/bash
# Type-checks the whole package without building it.
#   ./typecheck.sh
#
# `swift build` needs SwiftUI's macro plugin, which ships only inside a full
# Xcode — the Command Line Tools don't carry it, so a build dies on the first
# @State it sees. The macOS 26 SDK predates @State becoming a macro, so
# type-checking against that SDK covers the entire tree and catches every
# signature, label and type error a real build would. It emits no binary;
# ./build.sh still needs Xcode for that.
set -euo pipefail

cd "$(dirname "$0")"

SDK="${TYPECHECK_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk}"
if [ ! -d "$SDK" ]; then
  echo "error: no SDK at $SDK" >&2
  echo "       set TYPECHECK_SDK to a macOS 26 or earlier SDK" >&2
  exit 1
fi

echo "==> Type-checking against $(basename "$SDK")..."
xcrun swiftc -typecheck \
  -swift-version 6 \
  -sdk "$SDK" \
  -target arm64-apple-macos14.0 \
  $(find Sources/BlackGlass -name "*.swift")

echo "==> Clean."
