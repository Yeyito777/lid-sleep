#!/bin/bash
set -euo pipefail

case "${1:-}" in
    -h|--help)
        printf 'Usage: ./build.sh\nBuilds and ad-hoc signs build/Lid Sleep.app. Requires macOS and Apple command-line tools.\n'
        exit 0
        ;;
    "")
        if [ "$#" -ne 0 ]; then
            echo "Unexpected arguments. Use --help." >&2
            exit 2
        fi
        ;;
    *)
        echo "Unexpected arguments. Use --help." >&2
        exit 2
        ;;
esac

if [ "$(uname -s)" != "Darwin" ]; then
    echo "Lid Sleep requires macOS." >&2
    exit 1
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app="$root/build/Lid Sleep.app"
mkdir -p "$app/Contents/MacOS"
cp "$root/Info.plist" "$app/Contents/Info.plist"

swiftc -swift-version 5 -O \
    -target "$(uname -m)-apple-macosx13.0" \
    -framework AppKit "$root/LidSleep.swift" \
    -o "$app/Contents/MacOS/LidSleep"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
printf 'Built: %s\n' "$app"
