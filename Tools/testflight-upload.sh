#!/usr/bin/env bash
#
# Archive NOOPiOS (widget extension and watch app included) and upload it to
# TestFlight. The default is Xcode automatic signing. An optional manual mode
# signs the export with a local Apple Distribution certificate and installed
# App Store provisioning profiles. Uses the Apple ID already signed in to
# Xcode, or an App Store Connect API key when one is supplied. The key file
# stays outside the repo.
#
# Settings come from, in order: command-line flags, the environment, a local
# KEY=VALUE file, then the defaults below. The file is
# ${NOOP_TESTFLIGHT_CONFIG:-$HOME/.config/noop/testflight.env}. It is parsed,
# not sourced. A missing default file keeps the previous behaviour. See
# Config/testflight.env.example and docs/TESTFLIGHT.md.
#
# Usage:
#   Tools/testflight-upload.sh [--team TEAM_ID] [--app-group APP_GROUP_ID]
#       [--api-key-path PATH] [--api-key-id KEY_ID] [--api-issuer ISSUER_ID]
#       [--manual-profiles] [--profile-prefix PREFIX]
#       [--dry-run] [--archive-only]
#
# --team overrides the Apple Developer Team ID (default 48XAPJ6DGL).
# --app-group, or APP_GROUP_ID, overrides the App Group for the archive only.
# project.yml sets APP_GROUP_ID at project level, which beats the xcconfig, so
# the override is passed as a build setting.
# --api-key-path, --api-key-id, and --api-issuer (or ASC_KEY_PATH, ASC_KEY_ID,
# and ASC_ISSUER_ID) authenticate xcodebuild. Pass all three, or none to keep
# the Xcode account. When the key ID and issuer are set and the path is
# omitted, the path defaults to
# ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8.
# --manual-profiles, or EXPORT_SIGNING=manual, writes an export options plist
# with manual signing. Each archived bundle ID maps to a profile named
# "<prefix> <bundle id>". The prefix comes from --profile-prefix,
# PROFILE_PREFIX, or the legacy PROFILE_NAME_PREFIX environment variable, and
# defaults to "NOOP AppStore". The API key, when set, still authenticates the
# upload. The archive itself stays automatically signed.
# BUNDLE_ID_PREFIX and TEAM_ID from the environment or the config file are
# passed as archive build settings, so a fresh worktree does not need
# Config/BundleIdSecrets.xcconfig. That file is required only when neither
# source sets the bundle prefix.
# SIGNING_KEYCHAIN and SIGNING_KEYCHAIN_PASSWORD_SERVICE, together, unlock
# that keychain before archiving. The password is read from the login
# keychain and is never printed. The keychain then locks after two hours.
# --dry-run prints the resolved non-secret settings and exits.
# --archive-only archives and skips export and upload.
# The marketing version comes from project.yml. The build number is a
# timestamp (YYYYMMDDHHMM) so each upload is unique without editing project.yml.

set -euo pipefail

usage() {
  echo "usage: Tools/testflight-upload.sh [--team TEAM_ID] [--app-group APP_GROUP_ID] [--api-key-path PATH] [--api-key-id KEY_ID] [--api-issuer ISSUER_ID] [--manual-profiles] [--profile-prefix PREFIX] [--dry-run] [--archive-only]" >&2
}

require_value() {
  local flag="$1"
  local value="${2-}"
  if [[ $# -lt 2 || -z "$value" ]]; then
    echo "error: ${flag} requires a value" >&2
    usage
    exit 2
  fi
}

# Parsed, never sourced. Unknown keys are an error so a typo cannot be skipped.
load_testflight_config() {
  local file="$1"
  local line_no=0 line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_no=$((line_no + 1))
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" != *=* ]]; then
      echo "error: ${file}:${line_no}: expected KEY=VALUE" >&2
      exit 2
    fi
    key="${line%%=*}"
    value="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ ${#value} -ge 2 && "$value" == \"*\" && "$value" == *\" ]]; then
      value="${value:1:$((${#value} - 2))}"
    elif [[ ${#value} -ge 2 && "$value" == \'*\' && "$value" == *\' ]]; then
      value="${value:1:$((${#value} - 2))}"
    fi
    case "$key" in
      TEAM_ID) cfg_TEAM_ID="$value" ;;
      BUNDLE_ID_PREFIX) cfg_BUNDLE_ID_PREFIX="$value" ;;
      APP_GROUP_ID) cfg_APP_GROUP_ID="$value" ;;
      ASC_KEY_ID) cfg_ASC_KEY_ID="$value" ;;
      ASC_ISSUER_ID) cfg_ASC_ISSUER_ID="$value" ;;
      ASC_KEY_PATH) cfg_ASC_KEY_PATH="$value" ;;
      EXPORT_SIGNING) cfg_EXPORT_SIGNING="$value" ;;
      PROFILE_PREFIX) cfg_PROFILE_PREFIX="$value" ;;
      SIGNING_KEYCHAIN) cfg_SIGNING_KEYCHAIN="$value" ;;
      SIGNING_KEYCHAIN_PASSWORD_SERVICE) cfg_SIGNING_KEYCHAIN_PASSWORD_SERVICE="$value" ;;
      *)
        echo "error: ${file}:${line_no}: unknown key ${key}" >&2
        echo "Allowed keys: TEAM_ID, BUNDLE_ID_PREFIX, APP_GROUP_ID, ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH, EXPORT_SIGNING, PROFILE_PREFIX, SIGNING_KEYCHAIN, SIGNING_KEYCHAIN_PASSWORD_SERVICE" >&2
        exit 2
        ;;
    esac
  done < "$file"
}

expand_tilde() {
  local path="$1"
  if [[ "$path" == "~/"* ]]; then
    printf '%s' "${HOME}/${path:2}"
  else
    printf '%s' "$path"
  fi
}

# Password stays on the pipe. xtrace is off for the whole function so a
# caller running under bash -x cannot echo it. security prompts on /dev/tty
# when the script has a terminal, and ignores a pipe. Python starts the
# unlock with no controlling terminal, so the password is read from stdin.
unlock_signing_keychain() {
  local keychain="$1"
  local service="$2"
  local login_db="${HOME}/Library/Keychains/login.keychain-db"
  local tracing=0 errexit=0
  local py find_status unlock_status

  if [[ ! -f "$keychain" ]]; then
    echo "error: signing keychain not found at ${keychain}" >&2
    exit 1
  fi
  if [[ ! -f "$login_db" ]]; then
    echo "error: login keychain not found at ${login_db}" >&2
    exit 1
  fi
  if ! security find-generic-password -s "$service" "$login_db" >/dev/null 2>&1; then
    echo "error: the login keychain has no generic password for service ${service}." >&2
    echo "The signing keychain stays locked, and codesign fails with errSecInternalComponent." >&2
    exit 1
  fi
  if [[ -x /usr/bin/python3 ]]; then
    py="/usr/bin/python3"
  elif command -v python3 >/dev/null 2>&1; then
    py="$(command -v python3)"
  else
    echo "error: python3 is required to unlock the signing keychain without prompting." >&2
    exit 1
  fi

  case $- in
    *x*) tracing=1 ;;
  esac
  case $- in
    *e*) errexit=1 ;;
  esac
  set +x
  set +e
  security find-generic-password -s "$service" -w "$login_db" 2>/dev/null \
    | "$py" -c '
import sys, subprocess
password = sys.stdin.read()
if password.endswith("\n"):
    password = password[:-1]
result = subprocess.run(
    ["security", "unlock-keychain", sys.argv[1]],
    input=password + "\n",
    text=True,
    capture_output=True,
    start_new_session=True,
)
sys.exit(result.returncode)
' "$keychain" >/dev/null 2>&1
  # One assignment: a second statement would replace PIPESTATUS.
  find_status=${PIPESTATUS[0]} unlock_status=${PIPESTATUS[1]}
  if [[ "$errexit" -eq 1 ]]; then
    set -e
  fi
  if [[ "$tracing" -eq 1 ]]; then
    set -x
  fi

  if [[ "$find_status" -ne 0 || "$unlock_status" -ne 0 ]]; then
    echo "error: could not unlock signing keychain ${keychain}." >&2
    echo "The login-keychain item exists, but unlock failed. codesign would report errSecInternalComponent." >&2
    exit 1
  fi
  if ! security set-keychain-settings -u -t 7200 "$keychain" >/dev/null 2>&1; then
    echo "error: unlocked ${keychain}, but could not set the 2-hour lock timeout." >&2
    exit 1
  fi
}

cli_team=""
cli_app_group=""
cli_key_path=""
cli_key_id=""
cli_issuer=""
cli_manual=0
cli_profile=""
dry_run=0
archive_only=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --team)
      require_value "$1" "${2-}"
      cli_team="$2"
      shift 2
      ;;
    --app-group)
      require_value "$1" "${2-}"
      cli_app_group="$2"
      shift 2
      ;;
    --api-key-path)
      require_value "$1" "${2-}"
      cli_key_path="$2"
      shift 2
      ;;
    --api-key-id)
      require_value "$1" "${2-}"
      cli_key_id="$2"
      shift 2
      ;;
    --api-issuer)
      require_value "$1" "${2-}"
      cli_issuer="$2"
      shift 2
      ;;
    --manual-profiles)
      cli_manual=1
      shift
      ;;
    --profile-prefix)
      require_value "$1" "${2-}"
      cli_profile="$2"
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --archive-only)
      archive_only=1
      shift
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

if [[ "$dry_run" -eq 1 && "$archive_only" -eq 1 ]]; then
  echo "error: --dry-run and --archive-only cannot be combined" >&2
  exit 2
fi

cfg_TEAM_ID=""
cfg_BUNDLE_ID_PREFIX=""
cfg_APP_GROUP_ID=""
cfg_ASC_KEY_ID=""
cfg_ASC_ISSUER_ID=""
cfg_ASC_KEY_PATH=""
cfg_EXPORT_SIGNING=""
cfg_PROFILE_PREFIX=""
cfg_SIGNING_KEYCHAIN=""
cfg_SIGNING_KEYCHAIN_PASSWORD_SERVICE=""

CONFIG_FILE="${NOOP_TESTFLIGHT_CONFIG:-$HOME/.config/noop/testflight.env}"
if [[ -n "${NOOP_TESTFLIGHT_CONFIG:-}" ]]; then
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "error: NOOP_TESTFLIGHT_CONFIG does not point to a file: ${CONFIG_FILE}" >&2
    exit 1
  fi
fi
if [[ -f "$CONFIG_FILE" ]]; then
  if [[ ! -r "$CONFIG_FILE" ]]; then
    echo "error: cannot read TestFlight config: ${CONFIG_FILE}" >&2
    exit 1
  fi
  load_testflight_config "$CONFIG_FILE"
fi

# Precedence: flag, environment, config file, default.
if [[ -n "$cli_team" ]]; then
  TEAM="$cli_team"
elif [[ -n "${TEAM_ID:-}" ]]; then
  TEAM="$TEAM_ID"
elif [[ -n "$cfg_TEAM_ID" ]]; then
  TEAM="$cfg_TEAM_ID"
else
  TEAM="48XAPJ6DGL"
fi

if [[ -n "${BUNDLE_ID_PREFIX:-}" ]]; then
  BUNDLE_PREFIX="$BUNDLE_ID_PREFIX"
elif [[ -n "$cfg_BUNDLE_ID_PREFIX" ]]; then
  BUNDLE_PREFIX="$cfg_BUNDLE_ID_PREFIX"
else
  BUNDLE_PREFIX=""
fi

if [[ -n "$cli_app_group" ]]; then
  APP_GROUP="$cli_app_group"
elif [[ -n "${APP_GROUP_ID:-}" ]]; then
  APP_GROUP="$APP_GROUP_ID"
elif [[ -n "$cfg_APP_GROUP_ID" ]]; then
  APP_GROUP="$cfg_APP_GROUP_ID"
else
  APP_GROUP=""
fi

if [[ -n "$cli_key_path" ]]; then
  ASC_KEY_PATH="$cli_key_path"
elif [[ -n "${ASC_KEY_PATH:-}" ]]; then
  ASC_KEY_PATH="$ASC_KEY_PATH"
elif [[ -n "$cfg_ASC_KEY_PATH" ]]; then
  ASC_KEY_PATH="$cfg_ASC_KEY_PATH"
else
  ASC_KEY_PATH=""
fi

if [[ -n "$cli_key_id" ]]; then
  ASC_KEY_ID="$cli_key_id"
elif [[ -n "${ASC_KEY_ID:-}" ]]; then
  ASC_KEY_ID="$ASC_KEY_ID"
elif [[ -n "$cfg_ASC_KEY_ID" ]]; then
  ASC_KEY_ID="$cfg_ASC_KEY_ID"
else
  ASC_KEY_ID=""
fi

if [[ -n "$cli_issuer" ]]; then
  ASC_ISSUER_ID="$cli_issuer"
elif [[ -n "${ASC_ISSUER_ID:-}" ]]; then
  ASC_ISSUER_ID="$ASC_ISSUER_ID"
elif [[ -n "$cfg_ASC_ISSUER_ID" ]]; then
  ASC_ISSUER_ID="$cfg_ASC_ISSUER_ID"
else
  ASC_ISSUER_ID=""
fi

if [[ "$cli_manual" -eq 1 ]]; then
  EXPORT_SIGNING_VALUE="manual"
elif [[ -n "${EXPORT_SIGNING:-}" ]]; then
  EXPORT_SIGNING_VALUE="$EXPORT_SIGNING"
elif [[ -n "$cfg_EXPORT_SIGNING" ]]; then
  EXPORT_SIGNING_VALUE="$cfg_EXPORT_SIGNING"
else
  EXPORT_SIGNING_VALUE="automatic"
fi

if [[ -n "$cli_profile" ]]; then
  PROFILE_NAME_PREFIX="$cli_profile"
elif [[ -n "${PROFILE_PREFIX:-}" ]]; then
  PROFILE_NAME_PREFIX="$PROFILE_PREFIX"
elif [[ -n "${PROFILE_NAME_PREFIX:-}" ]]; then
  PROFILE_NAME_PREFIX="$PROFILE_NAME_PREFIX"
elif [[ -n "$cfg_PROFILE_PREFIX" ]]; then
  PROFILE_NAME_PREFIX="$cfg_PROFILE_PREFIX"
else
  PROFILE_NAME_PREFIX="NOOP AppStore"
fi

if [[ -n "${SIGNING_KEYCHAIN:-}" ]]; then
  SIGNING_KEYCHAIN="$SIGNING_KEYCHAIN"
elif [[ -n "$cfg_SIGNING_KEYCHAIN" ]]; then
  SIGNING_KEYCHAIN="$cfg_SIGNING_KEYCHAIN"
else
  SIGNING_KEYCHAIN=""
fi

if [[ -n "${SIGNING_KEYCHAIN_PASSWORD_SERVICE:-}" ]]; then
  SIGNING_KEYCHAIN_PASSWORD_SERVICE="$SIGNING_KEYCHAIN_PASSWORD_SERVICE"
elif [[ -n "$cfg_SIGNING_KEYCHAIN_PASSWORD_SERVICE" ]]; then
  SIGNING_KEYCHAIN_PASSWORD_SERVICE="$cfg_SIGNING_KEYCHAIN_PASSWORD_SERVICE"
else
  SIGNING_KEYCHAIN_PASSWORD_SERVICE=""
fi

if [[ ! "$TEAM" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "error: team ID must be 10 uppercase letters or digits" >&2
  exit 2
fi

if [[ -n "$BUNDLE_PREFIX" ]]; then
  if [[ "$BUNDLE_PREFIX" == *$'\n'* || "$BUNDLE_PREFIX" == *$'\r'* || "$BUNDLE_PREFIX" == *" "* ]]; then
    echo "error: BUNDLE_ID_PREFIX must be a single token" >&2
    exit 2
  fi
  if [[ ! "$BUNDLE_PREFIX" =~ ^[A-Za-z][A-Za-z0-9]*(\.[A-Za-z][A-Za-z0-9-]*)+$ ]]; then
    echo "error: BUNDLE_ID_PREFIX must be a reverse-DNS prefix such as com.example" >&2
    exit 2
  fi
fi

case "$EXPORT_SIGNING_VALUE" in
  automatic) MANUAL_PROFILES=0 ;;
  manual) MANUAL_PROFILES=1 ;;
  *)
    echo "error: EXPORT_SIGNING must be automatic or manual" >&2
    exit 2
    ;;
esac

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

ASC_KEY_PATH="$(expand_tilde "$ASC_KEY_PATH")"
SIGNING_KEYCHAIN="$(expand_tilde "$SIGNING_KEYCHAIN")"

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
fi

kc_set=0
[[ -n "$SIGNING_KEYCHAIN" ]] && kc_set=$((kc_set + 1))
[[ -n "$SIGNING_KEYCHAIN_PASSWORD_SERVICE" ]] && kc_set=$((kc_set + 1))
if [[ "$kc_set" -eq 1 ]]; then
  echo "error: SIGNING_KEYCHAIN and SIGNING_KEYCHAIN_PASSWORD_SERVICE must be set together." >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

api_key_file="no"
if [[ -n "$ASC_KEY_PATH" && -f "$ASC_KEY_PATH" && -r "$ASC_KEY_PATH" ]]; then
  api_key_file="yes"
fi

if [[ "$dry_run" -eq 1 ]]; then
  if [[ -n "$BUNDLE_PREFIX" ]]; then
    echo "bundle prefix: ${BUNDLE_PREFIX}"
  elif [[ -f Config/BundleIdSecrets.xcconfig ]]; then
    echo "bundle prefix: (Config/BundleIdSecrets.xcconfig)"
  else
    echo "bundle prefix: (not set)"
  fi
  echo "team: ${TEAM}"
  if [[ -n "$APP_GROUP" ]]; then
    echo "app group: ${APP_GROUP}"
  else
    echo "app group: (project default)"
  fi
  if [[ "$MANUAL_PROFILES" -eq 1 ]]; then
    echo "signing: manual"
  else
    echo "signing: automatic"
  fi
  echo "profile prefix: ${PROFILE_NAME_PREFIX}"
  if [[ -n "$ASC_KEY_ID" ]]; then
    echo "api key id: ${ASC_KEY_ID}"
  else
    echo "api key id: (none)"
  fi
  if [[ -n "$ASC_ISSUER_ID" ]]; then
    echo "api issuer: ${ASC_ISSUER_ID}"
  else
    echo "api issuer: (none)"
  fi
  echo "api key file: ${api_key_file}"
  if [[ -n "$SIGNING_KEYCHAIN" ]]; then
    echo "signing keychain: ${SIGNING_KEYCHAIN}"
  else
    echo "signing keychain: (none)"
  fi
  if [[ -z "$BUNDLE_PREFIX" && ! -f Config/BundleIdSecrets.xcconfig ]]; then
    echo "error: BUNDLE_ID_PREFIX is not set in the environment or ${CONFIG_FILE}, and Config/BundleIdSecrets.xcconfig is missing." >&2
    echo "Set BUNDLE_ID_PREFIX and TEAM_ID in the TestFlight config, or copy Config/BundleIdSecrets.example.xcconfig to Config/BundleIdSecrets.xcconfig." >&2
    exit 1
  fi
  exit 0
fi

if [[ -z "$BUNDLE_PREFIX" && ! -f Config/BundleIdSecrets.xcconfig ]]; then
  echo "error: BUNDLE_ID_PREFIX is not set in the environment or ${CONFIG_FILE}, and Config/BundleIdSecrets.xcconfig is missing." >&2
  echo "Set BUNDLE_ID_PREFIX and TEAM_ID in the TestFlight config, or copy Config/BundleIdSecrets.example.xcconfig to Config/BundleIdSecrets.xcconfig." >&2
  exit 1
fi

if [[ -n "$ASC_KEY_ID" ]]; then
  if [[ ! -f "$ASC_KEY_PATH" ]]; then
    echo "error: App Store Connect API key file not found at ${ASC_KEY_PATH}" >&2
    exit 1
  fi
  if [[ ! -r "$ASC_KEY_PATH" ]]; then
    echo "error: App Store Connect API key file is not readable" >&2
    exit 1
  fi
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

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen is not installed or not on PATH." >&2
  echo "Install it with: brew install xcodegen" >&2
  echo "The script generates Strand.xcodeproj before archiving. That project is not committed." >&2
  exit 1
fi

echo "Generating Xcode project..."
if ! xcodegen generate; then
  echo "error: xcodegen generate failed." >&2
  exit 1
fi

if [[ -n "$SIGNING_KEYCHAIN" ]]; then
  echo "Unlocking signing keychain..."
  unlock_signing_keychain "$SIGNING_KEYCHAIN" "$SIGNING_KEYCHAIN_PASSWORD_SERVICE"
fi

ARCHIVE="$WORKDIR/NOOP.xcarchive"
# Always at least these two, so the array stays non-empty under set -u (bash 3.2).
ARCHIVE_SETTINGS=(
  DEVELOPMENT_TEAM="$TEAM"
  CURRENT_PROJECT_VERSION="$BUILD"
)
if [[ -n "$BUNDLE_PREFIX" ]]; then
  ARCHIVE_SETTINGS+=(BUNDLE_ID_PREFIX="$BUNDLE_PREFIX")
fi
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
detail=""
if [[ -n "$BUNDLE_PREFIX" ]]; then
  detail+=", bundle prefix ${BUNDLE_PREFIX}"
fi
if [[ -n "$APP_GROUP" ]]; then
  detail+=", app group ${APP_GROUP}"
fi
echo "Archiving NOOPiOS ${VERSION} (${BUILD}) for team ${TEAM}${detail}${auth_note}..."
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

if [[ "$archive_only" -eq 1 ]]; then
  echo "Archive only: skipped export and upload for ${VERSION} (${BUILD})."
  exit 0
fi

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
