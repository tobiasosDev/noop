#!/usr/bin/env bash
# Refresh the release-time-stamped community stats shown by the in-app donation nudge.
# PORTED for the self-hosted forge: total asset downloads now come from the Forgejo API
# instead of api.github.com. The on-chain donor counts (BTC/ETH explorers) are unchanged.
#
# The app is fully offline by design — it never fetches these itself. Run this before each
# release; it rewrites the constants in BOTH platforms' DonationStats so they stay in lockstep:
#   Strand/Screens/DonationNudgeCard.swift                  (Swift: macOS + iOS)
#   android/app/src/main/java/com/noop/ui/DonationNudge.kt  (Kotlin)
#
# Downloads floored to nearest 500 ("5,000+"). Donors = incoming BTC outputs + incoming ETH txs.
# Usage: update-donation-stats.sh   (needs curl + python3 + jq; forge token optional but recommended)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HERE/../deploy.env" ] && source "$HERE/../deploy.env"
DOMAIN="${FORGE_DOMAIN:-${NOOP_DOMAIN:-noop.fans}}"
ORG="${FORGE_ORG:-NoopApp}"; REPO="${FORGE_REPO:-noop}"
# operate on the Strand checkout (where the source files live)
cd "${STRAND_DIR:-$HOME/Documents/Strand}"

BTC="bc1qn2gkl7wslwpws06mvazjn2uu689zlkv7kg3kf5"
ETH="0xd64D508b531c4b1297Ca4023C774e0E97aA67B7F"

AUTH=()
[ -f "$HOME/.config/noop/forge_token" ] && AUTH=(-H "Authorization: token $(cat "$HOME/.config/noop/forge_token")")

# Forgejo paginates releases; sum download_count across every asset of every release.
downloads=$(for page in 1 2 3 4 5; do
  curl -fsS "${AUTH[@]}" "https://$DOMAIN/api/v1/repos/$ORG/$REPO/releases?limit=50&page=$page"
done | jq -s 'add | map(.assets[]?.download_count) | add // 0')
downloads="${downloads:-0}"

btc_donors=$(curl -fsS "https://mempool.space/api/address/$BTC" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['chain_stats']['funded_txo_count'])" 2>/dev/null || echo 0)

eth_donors=$(curl -fsS "https://eth.blockscout.com/api/v2/addresses/$ETH/transactions?filter=to" \
  | python3 -c "import json,sys
try: print(len(json.load(sys.stdin).get('items',[])))
except Exception: print(0)" 2>/dev/null || echo 0)

floored=$(( downloads / 500 * 500 ))
donors=$(( btc_donors + eth_donors ))
echo "downloads=$downloads (floored $floored), donors: btc=$btc_donors eth=$eth_donors total=$donors"

python3 - "$floored" "$donors" <<'EOF'
import re, sys
floored, donors = sys.argv[1], sys.argv[2]
for p, dl_pat, dn_pat, dl_fmt, dn_fmt in [
    ('Strand/Screens/DonationNudgeCard.swift',
     r'static let downloads = [\d_]+', r'static let donors = \d+',
     'static let downloads = {:_}', 'static let donors = {}'),
    ('android/app/src/main/java/com/noop/ui/DonationNudge.kt',
     r'const val DOWNLOADS = [\d_]+', r'const val DONORS = \d+',
     'const val DOWNLOADS = {:_}', 'const val DONORS = {}'),
]:
    s = open(p).read()
    s = re.sub(dl_pat, dl_fmt.format(int(floored)), s)
    s = re.sub(dn_pat, dn_fmt.format(int(donors)), s)
    open(p, 'w').write(s)
print('✓ DonationStats updated on both platforms')
EOF
