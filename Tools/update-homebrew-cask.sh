#!/usr/bin/env bash
#
# update-homebrew-cask.sh <version> [zip] — refresh the Homebrew cask after a macOS release.
# PORTED for the self-hosted forge: download URL + tap repo now point at the forge, and
# the push uses the Forgejo API token instead of the (dead) GitHub PAT.
#
# Users install/update with:
#     brew tap noopapp/noop https://<forge>/NoopApp/homebrew-noop
#     brew install --cask noop   /   brew upgrade --cask noop
#
# Anonymity-safe: commits as NoopApp; token read from ~/.config/noop/forge_token and supplied
# via a transient git credential helper — never on a command line, URL, or in output.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HERE/../deploy.env" ] && source "$HERE/../deploy.env"
DOMAIN="${FORGE_DOMAIN:-${NOOP_DOMAIN:-noop.fans}}"
ORG="${FORGE_ORG:-NoopApp}"; REPO="${FORGE_REPO:-noop}"

VER="${1:?usage: $0 <version e.g. 4.7.0> [zip path]}"
ZIP="${2:-$HOME/Downloads/NOOP-v${VER}-macos.zip}"
TOKEN_FILE="$HOME/.config/noop/forge_token"
[ -f "$ZIP" ]        || { echo "missing release zip: $ZIP" >&2; exit 1; }
[ -f "$TOKEN_FILE" ] || { echo "missing token: $TOKEN_FILE" >&2; exit 1; }

export TOKEN; TOKEN="$(cat "$TOKEN_FILE")"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
TAP_URL="https://$DOMAIN/$ORG/homebrew-noop.git"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
git clone --quiet "$TAP_URL" "$TMP/tap" 2>/dev/null || { mkdir -p "$TMP/tap"; git -C "$TMP/tap" init -q; }

mkdir -p "$TMP/tap/Casks"
cat > "$TMP/tap/Casks/noop.rb" <<EOF
cask "noop" do
  version "${VER}"
  sha256 "${SHA}"

  url "https://${DOMAIN}/${ORG}/${REPO}/releases/download/v#{version}/NOOP-v#{version}-macos.zip"
  name "NOOP"
  desc "Standalone, fully offline companion app for WHOOP straps"
  homepage "https://${DOMAIN}/${ORG}/${REPO}"

  app "NOOP.app"

  caveats "NOOP ships anonymously and is unsigned (no Apple Developer ID), so on first launch macOS Gatekeeper will block it. On macOS 15 Sequoia and later: try to open NOOP once, then go to System Settings > Privacy & Security, scroll down, and click 'Open Anyway' next to NOOP. (On macOS 14 and earlier you can right-click NOOP in /Applications and choose Open.) Update later with: brew upgrade --cask noop."
end
EOF

cd "$TMP/tap"
git -c user.name=NoopApp -c user.email=thenoopapp@gmail.com add Casks/noop.rb
if git rev-parse HEAD >/dev/null 2>&1 && git diff --cached --quiet; then
  echo "Homebrew cask already current for ${VER} — nothing to push."; exit 0
fi
git -c user.name=NoopApp -c user.email=thenoopapp@gmail.com commit --quiet -m "noop ${VER}"
git -c credential.helper='!f() { echo username=NoopApp; echo "password=$TOKEN"; }; f' \
    push --quiet "$TAP_URL" HEAD:main
echo "✓ Homebrew cask updated to ${VER} (sha256 ${SHA:0:12}…)"
