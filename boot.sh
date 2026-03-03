#!/bin/bash
# Sovereign ATX — One-Line Bootstrap
# Usage: curl -fsSL sovboot.sh | bash -s <customer-id> "<name>"
set -e
echo "══════════════════════════════════════"
echo " Sovereign ATX — Quick Provisioner"
echo "══════════════════════════════════════"

# Pull keys from ~/.sovereign-keys (created once)
KEYFILE="$HOME/.sovereign-keys"
if [ ! -f "$KEYFILE" ]; then
  echo ""
  echo "First time? Let's save your keys (one-time setup)."
  echo ""
  read -p "GitHub PAT (ghp_...): " GH_PAT
  read -p "Tailscale Auth Key (tskey-auth-...): " TS_KEY
  read -p "Anthropic API Key (sk-ant-...): " ANT_KEY
  mkdir -p "$(dirname "$KEYFILE")"
  cat > "$KEYFILE" << EOF
GH_PAT="$GH_PAT"
TS_KEY="$TS_KEY"
ANT_KEY="$ANT_KEY"
EOF
  chmod 600 "$KEYFILE"
  echo "✅ Keys saved to $KEYFILE"
fi

source "$KEYFILE"

curl -fsSL -H "Authorization: token $GH_PAT" \
  https://raw.githubusercontent.com/kavinlingham1-gif/sovereign-cluster/main/provision.sh \
  | TAILSCALE_AUTHKEY="$TS_KEY" \
    ANTHROPIC_API_KEY="$ANT_KEY" \
    bash -s "$@"
