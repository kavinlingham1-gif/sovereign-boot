#!/bin/bash
# ══════════════════════════════════════════════════════════════════
# Sovereign ATX — Boot Script v4
# Run: bash boot.sh <customer-id> "<Name>"
# Mini mode (no Anthropic key): GH_PAT=... TS_KEY=... bash boot.sh <id> "<Name>"
# Reset keys: bash boot.sh --reset
# ══════════════════════════════════════════════════════════════════

set -e

KEYFILE="$HOME/.sovereign-keys"
GH_REPO="kavinlingham1-gif/sovereign-cluster"

# ── Reset flag ───────────────────────────────────────────────────
if [ "$1" = "--reset" ]; then
  rm -f "$KEYFILE"
  echo "✅ Keys cleared. Run boot.sh again to re-enter."
  exit 0
fi

CUSTOMER_ID="${1:?Usage: bash boot.sh <customer-id> \"<Name>\"}"
CUSTOMER_NAME="${2:-Customer}"

echo ""
echo "══════════════════════════════════════════════════"
echo " Sovereign ATX — Provisioning $CUSTOMER_NAME"
echo "══════════════════════════════════════════════════"
echo ""

# ── Pre-flight: must be admin ────────────────────────────────────
if ! groups "$USER" | grep -qw admin; then
  echo "❌ ERROR: $USER is not an admin."
  echo ""
  echo "Fix: System Settings → Users & Groups → $USER → check 'Administrator'"
  echo "Then log out and back in, and re-run this script."
  exit 1
fi
echo "✅ Admin check passed"

# ── If keys passed as env vars, skip prompts ─────────────────────
if [ -n "$GH_PAT" ] && [ -n "$TS_KEY" ]; then
  echo "✅ Keys loaded from environment"
  ANT_KEY="${ANT_KEY:-}"
else
  # ── Load or collect keys ───────────────────────────────────────
  load_keys() {
    source "$KEYFILE"
    if [ -z "$GH_PAT" ] || [ -z "$TS_KEY" ]; then
      echo "⚠️  Saved keys are incomplete. Re-entering..."
      rm -f "$KEYFILE"
      return 1
    fi
    return 0
  }

  if [ -f "$KEYFILE" ] && load_keys; then
    echo "✅ Keys loaded from $KEYFILE"
    echo "   (Run: bash boot.sh --reset  to change keys)"
  else
    echo ""
    echo "Enter your keys (paste each one, hit Enter):"
    echo ""

    while true; do
      read -r -p "GitHub PAT (ghp_...): " GH_PAT
      [[ "$GH_PAT" == ghp_* ]] && break
      echo "   ❌ Should start with ghp_ — try again"
    done

    while true; do
      read -r -p "Tailscale Auth Key (tskey-auth-...): " TS_KEY
      [[ "$TS_KEY" == tskey-auth-* ]] && break
      echo "   ❌ Should start with tskey-auth- — try again"
    done

    read -r -p "Anthropic API Key (sk-ant-... or Enter to skip): " ANT_KEY

    mkdir -p "$(dirname "$KEYFILE")"
    printf 'GH_PAT="%s"\nTS_KEY="%s"\nANT_KEY="%s"\n' "$GH_PAT" "$TS_KEY" "$ANT_KEY" > "$KEYFILE"
    chmod 600 "$KEYFILE"
    echo ""
    echo "✅ Keys saved to $KEYFILE"
  fi
fi

echo ""
echo "Fetching provisioner..."

# Download provision.sh from private repo
PROVISION_TMP=$(mktemp /tmp/sovereign-provision.XXXXXX.sh)
HTTP_CODE=$(curl -fsSL \
  -H "Authorization: token $GH_PAT" \
  -o "$PROVISION_TMP" \
  -w "%{http_code}" \
  "https://raw.githubusercontent.com/$GH_REPO/main/provision.sh")

if [ "$HTTP_CODE" != "200" ]; then
  echo "❌ Failed to fetch provision.sh (HTTP $HTTP_CODE)"
  echo "   Check your GitHub PAT has 'repo' scope."
  rm -f "$PROVISION_TMP"
  exit 1
fi

echo "✅ Provisioner downloaded"
echo ""

# Run it
TAILSCALE_AUTHKEY="$TS_KEY" \
ANTHROPIC_API_KEY="$ANT_KEY" \
  bash "$PROVISION_TMP" "$CUSTOMER_ID" "$CUSTOMER_NAME"

rm -f "$PROVISION_TMP"
