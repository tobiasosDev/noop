#!/usr/bin/env bash
#
# Archive NOOPiOS (widget extension and watch app included) and upload it to
# TestFlight. The default is Xcode automatic signing. An optional manual mode
# signs the export with a local Apple Distribution certificate and installed
# App Store provisioning profiles. Uses the Apple ID already signed in to
# Xcode, or an App Store Connect API key when one is supplied. The key file
# stays outside the repo.
#
# Usage:
#   Tools/testflight-upload.sh [--team TEAM_ID] [--app-group APP_GROUP_ID]
#       [--api-key-path PATH] [--api-key-id KEY_ID] [--api-issuer ISSUER_ID]
#       [--manual-profiles] [--profile-prefix PREFIX]
#
# --team overrides the Apple Developer Team ID (default 48XAPJ6DGL).
# --app-group, or the APP_GROUP_ID environment variable, overrides the App
# Group for the archive only. project.yml sets APP_GROUP_ID at project level,
# which beats the xcconfig, so the override is passed as a build setting.
# --api-key-path, --api-key-id, and --api-issuer (or ASC_KEY_PATH, ASC_KEY_ID,
# and ASC_ISSUER_ID) authenticate xcodebuild. Pass all three, or none to keep
# the Xcode account. When the key ID and issuer are set and the path is
# omitted, the path defaults to
# ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8.
# --manual-profiles, or EXPORT_SIGNING=manual, writes an export options plist
# with manual signing. Each archived bundle ID maps to a profile named
# "<prefix> <bundle id>". The prefix comes from --profile-prefix or
# PROFILE_NAME_PREFIX and defaults to "NOOP AppStore". The API key, when set,
# still authenticates the upload. The archive itself stays automatically signed.
# Requires Config/BundleIdSecrets.xcconfig (gitignored; see
# Config/BundleIdSecrets.example.xcconfig). The marketing version comes from
# project.yml. The build number is a timestamp (YYYYMMDDHHMM) so each upload
# is unique without editing project.yml.

set -euo pipefail

TEAM="48XAPJ6DGL"
# Flag wins over the environment when both are set.
APP_GROUP="${APP_GROUP_ID:-}"
ASC_KEY_PATH="${ASC_KEY_PATH:-}"
ASC_KEY_ID="${ASC_KEY_ID:-}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-}"
# Flag wins over the environment when both are set.
MANUAL_PROFILES=0
case "${EXPORT_SIGNING:-automatic}" in
  automatic) ;;
  manual) MANUAL_PROFILES=1 ;;
  *)
    echo "error: EXPORT_SIGNING must be automatic or manual" >&2
    exit 2
    ;;
esac
PROFILE_NAME_PREFIX="${PROFILE_NAME_PREFIX:-NOOP AppStore}"

usage() {
  echo "usage: Tools/testflight-upload.sh [--team TEAM_ID] [--app-group APP_GROUP_ID] [--api-key-path PATH] [--api-key-id KEY_ID] [--api-issuer ISSUER_ID] [--manual-profiles] [--profile-prefix PREFIX]" >&2
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
    --app-group)
      if [[ $# -lt 2 || -z "${2}" ]]; then
        echo "error: --app-group requires an App Group identifier" >&2
        usage
        exit 2
      fi
      APP_GROUP="$2"
      shift 2
      ;;
    --api-key-path)
      if [[ $# -lt 2 || -z "${2}" ]]; then
        echo "error: --api-key-path requires a path to an App Store Connect API key" >&2
        usage
        exit 2
      fi
      ASC_KEY_PATH="$2"
      shift 2
      ;;
    --api-key-id)
      if [[ $# -lt 2 || -z "${2}" ]]; then
        echo "error: --api-key-id requires an App Store Connect API key ID" >&2
        usage
        exit 2
      fi
      ASC_KEY_ID="$2"
      shift 2
      ;;
    --api-issuer)
      if [[ $# -lt 2 || -z "${2}" ]]; then
        echo "error: --api-issuer requires an App Store Connect issuer ID" >&2
        usage
        exit 2
      fi
      ASC_ISSUER_ID="$2"
      shift 2
      ;;
    --manual-profiles)
      MANUAL_PROFILES=1
      shift
      ;;
    --profile-prefix)
      if [[ $# -lt 2 || -z "${2}" ]]; then
        echo "error: --profile-prefix requires a name prefix" >&2
        usage
        exit 2
      fi
      PROFILE_NAME_PREFIX="$2"
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

if [[ "$MANUAL_PROFILES" -eq 1 ]]; then
  if [[ -z "$PROFILE_NAME_PREFIX" || "$PROFILE_NAME_PREFIX" == *$'\n'* || "$PROFILE_NAME_PREFIX" == *$'\r'* ]]; then
    echo "error: profile name prefix must be a single non-empty line" >&2
    exit 2
  fi
fi

if [[ -n "$APP_GROUP" && ! "$APP_GROUP" =~ ^group\.[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then
  echo "error: app group must look like group.com.example.app" >&2
  exit 2
fi

# ID plus issuer, and no path, is enough: the key lives in the standard directory.
if [[ -z "$ASC_KEY_PATH" && -n "$ASC_KEY_ID" && -n "$ASC_ISSUER_ID" ]]; then
  ASC_KEY_PATH="${HOME}/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
fi

asc_set=0
[[ -n "$ASC_KEY_PATH" ]] && asc_set=$((asc_set + 1))
[[ -n "$ASC_KEY_ID" ]] && asc_set=$((asc_set + 1))
[[ -n "$ASC_ISSUER_ID" ]] && asc_set=$((asc_set + 1))
if [[ "$asc_set" -ne 0 && "$asc_set" -ne 3 ]]; then
  echo "error: App Store Connect API key auth needs the key path, key ID, and issuer ID together." >&2
  echo "Pass --api-key-path, --api-key-id, and --api-issuer (or ASC_KEY_PATH, ASC_KEY_ID, and ASC_ISSUER_ID), or omit all three to use the Xcode account." >&2
  exit 2
fi

if [[ -n "$ASC_KEY_ID" ]]; then
  if [[ ! "$ASC_KEY_ID" =~ ^[A-Z0-9]{10}$ ]]; then
    echo "error: API key ID must be 10 uppercase letters or digits" >&2
    exit 2
  fi
  if [[ ! "$ASC_ISSUER_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    echo "error: API issuer ID must be a UUID" >&2
    exit 2
  fi
  # A quoted ~/ path is not expanded by the shell before it reaches the script.
  if [[ "$ASC_KEY_PATH" == "~/"* ]]; then
    ASC_KEY_PATH="${HOME}/${ASC_KEY_PATH:2}"
  fi
  if [[ ! -f "$ASC_KEY_PATH" ]]; then
    echo "error: App Store Connect API key file not found at ${ASC_KEY_PATH}" >&2
    exit 1
  fi
  if [[ ! -r "$ASC_KEY_PATH" ]]; then
    echo "error: App Store Connect API key file is not readable" >&2
    exit 1
  fi
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
# Always at least these two, so the array stays non-empty under set -u (bash 3.2).
ARCHIVE_SETTINGS=(
  DEVELOPMENT_TEAM="$TEAM"
  CURRENT_PROJECT_VERSION="$BUILD"
)
if [[ -n "$APP_GROUP" ]]; then
  ARCHIVE_SETTINGS+=(APP_GROUP_ID="$APP_GROUP")
fi
# Always at least -allowProvisioningUpdates, for the same bash 3.2 reason.
XCODE_AUTH=(-allowProvisioningUpdates)
auth_note=""
if [[ -n "$ASC_KEY_ID" ]]; then
  XCODE_AUTH+=(
    -authenticationKeyPath "$ASC_KEY_PATH"
    -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
  )
  auth_note=", App Store Connect API key"
fi
if [[ -n "$APP_GROUP" ]]; then
  echo "Archiving NOOPiOS ${VERSION} (${BUILD}) for team ${TEAM}, app group ${APP_GROUP}${auth_note}..."
else
  echo "Archiving NOOPiOS ${VERSION} (${BUILD}) for team ${TEAM}${auth_note}..."
fi
xcodebuild \
  -project Strand.xcodeproj \
  -scheme NOOPiOS \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  "${XCODE_AUTH[@]}" \
  "${ARCHIVE_SETTINGS[@]}" \
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

# Taken from the archive so another bundle prefix still maps. Not a team constant.
APP_BUNDLE_ID="$(read_plist :CFBundleIdentifier "$APP_DIR/Info.plist")"
WIDGET_BUNDLE_ID="$(read_plist :CFBundleIdentifier "$APP_DIR/PlugIns/NOOPWidgets.appex/Info.plist")"
WATCH_BUNDLE_ID="$(read_plist :CFBundleIdentifier "$APP_DIR/Watch/NOOPWatch.app/Info.plist")"
COMPLICATION_BUNDLE_ID="$(read_plist :CFBundleIdentifier "$APP_DIR/Watch/NOOPWatch.app/PlugIns/NOOPWatchComplications.appex/Info.plist")"

EXPORT_PLIST="$WORKDIR/ExportOptions.plist"
if [[ "$MANUAL_PROFILES" -eq 1 ]]; then
  for bundle_id in "$APP_BUNDLE_ID" "$WIDGET_BUNDLE_ID" "$WATCH_BUNDLE_ID" "$COMPLICATION_BUNDLE_ID"; do
    if [[ -z "$bundle_id" ]]; then
      echo "error: archived bundle ID is empty" >&2
      exit 1
    fi
  done
  xml_escape() {
    local s=$1
    s=${s//&/&amp;}
    s=${s//</&lt;}
    s=${s//>/&gt;}
    printf '%s' "$s"
  }
  # An extra trailing newline survives command-substitution stripping.
  profile_entry() {
    local bundle=$1
    local name="${PROFILE_NAME_PREFIX} ${bundle}"
    printf '\t\t<key>%s</key>\n\t\t<string>%s</string>\n\n' "$(xml_escape "$bundle")" "$(xml_escape "$name")"
  }
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
	<key>provisioningProfiles</key>
	<dict>
$(profile_entry "$APP_BUNDLE_ID")$(profile_entry "$WIDGET_BUNDLE_ID")$(profile_entry "$WATCH_BUNDLE_ID")$(profile_entry "$COMPLICATION_BUNDLE_ID")	</dict>
	<key>signingCertificate</key>
	<string>Apple Distribution</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>teamID</key>
	<string>${TEAM}</string>
	<key>uploadSymbols</key>
	<true/>
</dict>
</plist>
EOF
  plutil -lint "$EXPORT_PLIST" >/dev/null
  echo "Exporting and uploading ${VERSION} (${BUILD}) with manual profiles:"
  echo "  ${PROFILE_NAME_PREFIX} ${APP_BUNDLE_ID}"
  echo "  ${PROFILE_NAME_PREFIX} ${WIDGET_BUNDLE_ID}"
  echo "  ${PROFILE_NAME_PREFIX} ${WATCH_BUNDLE_ID}"
  echo "  ${PROFILE_NAME_PREFIX} ${COMPLICATION_BUNDLE_ID}"
else
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
fi

# Manual export uses profiles already on disk. Skip -allowProvisioningUpdates
# there so xcodebuild does not try cloud signing. The API key still uploads.
EXPORT_AUTH=()
if [[ "$MANUAL_PROFILES" -eq 0 ]]; then
  EXPORT_AUTH+=(-allowProvisioningUpdates)
fi
if [[ -n "$ASC_KEY_ID" ]]; then
  EXPORT_AUTH+=(
    -authenticationKeyPath "$ASC_KEY_PATH"
    -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
  )
fi
if [[ ${#EXPORT_AUTH[@]} -eq 0 ]]; then
  xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$EXPORT_PLIST" \
    -exportPath "$WORKDIR/export"
else
  xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$EXPORT_PLIST" \
    -exportPath "$WORKDIR/export" \
    "${EXPORT_AUTH[@]}"
fi

BUNDLE_ID="$(read_plist :CFBundleIdentifier "$APP_DIR/Info.plist")"
echo "Uploaded ${BUNDLE_ID} ${VERSION} (${BUILD}) to TestFlight."
