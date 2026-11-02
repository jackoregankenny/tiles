#!/bin/sh
# Builds build/Tiles.app. No dependencies beyond the Xcode command line tools.
#   ./build.sh                 build
#   ./build.sh test            build and run the self-test
#   ./build.sh dist 0.3.0      release build, zipped with a checksum, in dist/
#   ./build.sh release 0.3.0   tag v0.3.0 and push; GitHub Actions builds and publishes the release
#
# Plain builds are version "dev" and never update themselves.
set -e
cd "$(dirname "$0")"

build() {
  APP=build/Tiles.app
  BIN=$APP/Contents/MacOS/Tiles
  mkdir -p "$APP/Contents/MacOS"
  cp Info.plist "$APP/Contents/Info.plist"
  if [ -n "$VERSION" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" \
      "$APP/Contents/Info.plist"
  fi
  swiftc -swift-version 5 -Osize -wmo -target arm64-apple-macos13 -module-name Tiles \
    -Xlinker -dead_strip -o "$BIN" Sources/*.swift
  strip -x "$BIN"
  codesign --force --sign - "$APP" >/dev/null 2>&1
  printf 'Tiles %7s bytes\n' "$(stat -f %z "$BIN")"
}

case "$1" in
  test)
    build
    build/Tiles.app/Contents/MacOS/Tiles --selftest | tail -1 ;;
  dist)
    [ -n "$2" ] || { echo "usage: ./build.sh dist <version>"; exit 1; }
    VERSION=$2
    command rm -rf build dist
    build
    mkdir -p dist
    ditto -c -k --keepParent build/Tiles.app dist/Tiles.zip
    shasum -a 256 dist/Tiles.zip | cut -d' ' -f1 > dist/Tiles.zip.sha256
    ls -l dist ;;
  release)
    [ -n "$2" ] || { echo "usage: ./build.sh release <version>"; exit 1; }
    [ -z "$(git status --porcelain)" ] || { echo "commit your changes first"; exit 1; }
    git tag "v$2" && git push origin "v$2"
    echo "Tagged v$2; GitHub Actions is building the release." ;;
  "") build ;;
  *) echo "unknown command: $1"; exit 1 ;;
esac
