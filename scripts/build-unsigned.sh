#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUNDLE_ID="${1:-com.bkjbkjbkj.muyu}"
if [[ ! "$BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
  echo "Invalid bundle identifier" >&2
  exit 2
fi
mkdir -p build
xcodebuild -project Muyu.xcodeproj -scheme Muyu \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' \
  build 2>&1 | tee build/xcodebuild.log

APP_PATH='build/DerivedData/Build/Products/Release-iphoneos/Muyu.app'
test -d "$APP_PATH"
test -f "$APP_PATH/Muyu"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist"

# Use a temporary directory so repeated local runs cannot package stale files.
PACKAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/muyu-package.XXXXXX")"
trap 'rm -rf "$PACKAGE_DIR"' EXIT
mkdir "$PACKAGE_DIR/Payload"
ditto "$APP_PATH" "$PACKAGE_DIR/Payload/Muyu.app"
OUTPUT_PATH="$PWD/build/Muyu-unsigned.ipa"
rm -f "$OUTPUT_PATH"
(cd "$PACKAGE_DIR" && /usr/bin/zip -qry "$OUTPUT_PATH" Payload)
/usr/bin/unzip -t "$OUTPUT_PATH"
(cd build && shasum -a 256 Muyu-unsigned.ipa > SHA256SUMS.txt)
echo "Created build/Muyu-unsigned.ipa. Sign it with your own certificate before installation."
