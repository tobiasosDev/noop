#!/usr/bin/env bash
#
# Archive NOOPiOS (widget extension and watch app included) and upload it to
# TestFlight with Xcode automatic signing. Uses the Apple ID already signed in
# to Xcode. No App Store Connect API key.
#
# Usage:
#   Tools/testflight-upload.sh [--team TEAM_ID]
#
# --team overrides the Apple Developer Team ID (default 48XAPJ6DGL).
# Requires Config/BundleIdSecrets.xcconfig (gitignored; see
# Config/BundleIdSecrets.example.xcconfig). The marketing version comes from
# project.yml. The build number is a timestamp (YYYYMMDDHHMM) so each upload
# is unique without editing project.yml.

set -euo pipefail

TEAM="48XAPJ6DGL"

usage() {
  echo "usage: Tools/testflight-upload.sh [--team TEAM_ID]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --team)
      if [[ $# -lt 2 || -z "${2}" ]]; then
        echo "error: --team requires a team ID" >&2
        usage
        exit 2
      fi
      TEAM="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ ! "$TEAM" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "error: team ID must be 10 uppercase letters or digits" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ ! -f Config/BundleIdSecrets.xcconfig ]]; then
  echo "error: Config/BundleIdSecrets.xcconfig is missing." >&2
  echo "Copy Config/BundleIdSecrets.example.xcconfig and set BUNDLE_ID_PREFIX and DEVELOPMENT_TEAM." >&2
  exit 1
fi

VERSION="$(sed -n 's/^    MARKETING_VERSION: "\(.*\)"/\1/p' project.yml | head -n 1)"
if [[ -z "$VERSION" ]]; then
  echo "error: MARKETING_VERSION not found in project.yml" >&2
  exit 1
fi

BUILD="$(date +%Y%m%d%H%M)"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/noop-testflight.XXXXXX")"

cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo "Generating Xcode project..."
xcodegen generate

ARCHIVE="$WORKDIR/NOOP.xcarchive"
echo "Archiving NOOPiOS ${VERSION} (${BUILD}) for team ${TEAM}..."
xcodebuild \
  -project Strand.xcodeproj \
  -scheme NOOPiOS \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  archive \
  -archivePath "$ARCHIVE"

APP_DIR="$(find "$ARCHIVE/Products/Applications" -maxdepth 1 -type d -name '*.app' -print -quit)"
if [[ -z "$APP_DIR" ]]; then
  echo "error: archived app not found under $ARCHIVE/Products/Applications" >&2
  exit 1
fi

read_plist() {
  /usr/libexec/PlistBuddy -c "Print $1" "$2"
}

expect_build() {
  local label="$1" plist="$2"
  if [[ ! -f "$plist" ]]; then
    echo "error: missing $label Info.plist at $plist" >&2
    exit 1
  fi
  local version build
  version="$(read_plist :CFBundleShortVersionString "$plist")"
  build="$(read_plist :CFBundleVersion "$plist")"
  if [[ "$version" != "$VERSION" || "$build" != "$BUILD" ]]; then
    echo "error: $label is ${version} (${build}); expected ${VERSION} (${BUILD})" >&2
    exit 1
  fi
}

expect_build "app" "$APP_DIR/Info.plist"
expect_build "widgets" "$APP_DIR/PlugIns/NOOPWidgets.appex/Info.plist"
expect_build "watch" "$APP_DIR/Watch/NOOPWatch.app/Info.plist"
expect_build "watch complications" "$APP_DIR/Watch/NOOPWatch.app/PlugIns/NOOPWatchComplications.appex/Info.plist"

EXPORT_PLIST="$WORKDIR/ExportOptions.plist"
cat > "$EXPORT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>destination</key>
	<string>upload</string>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
	<key>method</key>
	<string>app-store-connect</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>${TEAM}</string>
	<key>uploadSymbols</key>
	<true/>
</dict>
</plist>
EOF

echo "Exporting and uploading ${VERSION} (${BUILD})..."
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  -exportPath "$WORKDIR/export" \
  -allowProvisioningUpdates

BUNDLE_ID="$(read_plist :CFBundleIdentifier "$APP_DIR/Info.plist")"
echo "Uploaded ${BUNDLE_ID} ${VERSION} (${BUILD}) to TestFlight."
