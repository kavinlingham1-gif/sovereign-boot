#!/bin/bash
# ══════════════════════════════════════════════════════════════════
# Sovereign ATX — Sovereign Private (On-Prem) Setup v1
# ══════════════════════════════════════════════════════════════════
# For on-prem deployments where hardware lives at customer's facility.
# Run this on EACH Mac Studio at the customer site.
#
# This script sets up:
#   - Homebrew, Tailscale, Ollama
#   - Pulls AI models to local storage
#   - Configures firewall (LAN-only Ollama access)
#   - Joins Sovereign Tailscale network for remote management
#
# Usage:
#   bash setup-sovereign-private.sh <customer-id> <studio-number>
#
# Example (Gabriel's 3 Studios):
#   bash setup-sovereign-private.sh gabriel 1
#   bash setup-sovereign-private.sh gabriel 2
#   bash setup-sovereign-private.sh gabriel 3
#
# Env vars required:
#   TAILSCALE_AUTHKEY  — tskey-auth-...
#
# After all Studios are set up, run provision.sh on each Mini
# with --flip-to-studio pointing to the lead Studio's Tailscale IP.
# ══════════════════════════════════════════════════════════════════

set -o pipefail

STEP=0
TOTAL_STEPS=5
ERRORS=()

ok()  { echo "  ✅ $*"; }
warn(){ echo "  ⚠️  $*"; ERRORS+=("$*"); }
die() { echo ""; echo "❌ FATAL: $*"; exit 1; }
step(){ STEP=$((STEP+1)); echo ""; echo "[$STEP/$TOTAL_STEPS] $*"; }

CUSTOMER_ID="${1:?Usage: bash setup-sovereign-private.sh <customer-id> <studio-number>}"
STUDIO_NUM="${2:?Usage: bash setup-sovereign-private.sh <customer-id> <studio-number>}"
TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY:-}"

HOSTNAME="sovereign-${CUSTOMER_ID}-studio-${STUDIO_NUM}"
EVAN_SSH_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINMkIrNBX0fu2O0IyAqJu3E/ZSgzJInbtS9lvxrN8UBq evan@sovereign"

echo ""
echo "══════════════════════════════════════════════════"
echo " Sovereign Private — On-Prem Studio Setup v1"
echo " Customer : $CUSTOMER_ID"
echo " Studio   : #$STUDIO_NUM"
echo " Hostname : $HOSTNAME"
echo " User     : $USER"
echo "══════════════════════════════════════════════════"
echo ""
echo "Checklist before continuing:"
echo "  ☐ macOS setup wizard complete"
echo "  ☐ Software updates done + rebooted"
echo "  ☐ Remote Login ON (System Settings → Sharing)"
echo "  ☐ Ethernet connected to customer's network"
echo "  ☐ Tailscale auth key ready"
echo ""

[ -z "$TAILSCALE_AUTHKEY" ] && {
  read -r -p "Tailscale Auth Key (tskey-auth-...): " TAILSCALE_AUTHKEY
  [[ "$TAILSCALE_AUTHKEY" == tskey-auth-* ]] || die "Invalid Tailscale key"
}

# ── 1. Homebrew ──────────────────────────────────────────────────
step "Homebrew"
if command -v brew &>/dev/null; then
  ok "Already installed"
else
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
    || die "Homebrew install failed"
  ok "Installed"
fi

if [ -f /opt/homebrew/bin/brew ]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
  grep -q 'brew shellenv' ~/.zprofile 2>/dev/null || \
    echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
fi
brew update --quiet 2>/dev/null || warn "brew update failed (non-fatal)"

# ── 2. Tailscale ─────────────────────────────────────────────────
step "Tailscale"
if brew list --cask tailscale 2>/dev/null | grep -q tailscale; then
  ok "Already installed"
else
  brew install --cask tailscale || die "Tailscale install failed"
  ok "Installed"
fi

open -a Tailscale 2>/dev/null || true
echo "  Waiting for Tailscale daemon..."
for i in $(seq 1 15); do
  sleep 2
  /Applications/Tailscale.app/Contents/MacOS/Tailscale status &>/dev/null && break
done

TAILSCALE_BIN="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
if [ -f "$TAILSCALE_BIN" ]; then
  sudo "$TAILSCALE_BIN" up \
    --authkey="$TAILSCALE_AUTHKEY" \
    --hostname="$HOSTNAME" \
    --accept-routes \
    --timeout=30s \
    && ok "Joined tailnet as $HOSTNAME" \
    || warn "tailscale up failed — run manually"
fi

TS_IP=$("$TAILSCALE_BIN" ip -4 2>/dev/null || echo "unknown")

# ── 3. Ollama ────────────────────────────────────────────────────
step "Ollama"
if command -v ollama &>/dev/null; then
  ok "Already installed"
else
  brew install ollama || die "Ollama install failed"
  ok "Installed"
fi

# Listen on all interfaces (LAN + Tailscale)
grep -q "OLLAMA_HOST" ~/.zprofile 2>/dev/null || \
  echo 'export OLLAMA_HOST="0.0.0.0:11434"' >> ~/.zprofile
export OLLAMA_HOST="0.0.0.0:11434"

brew services start ollama 2>/dev/null || true
sleep 5

if ! curl -sf http://localhost:11434/api/tags > /dev/null 2>&1; then
  warn "Ollama not responding — starting manually"
  ollama serve &>/tmp/ollama.log &
  sleep 5
fi

# ── 4. Pull Models ───────────────────────────────────────────────
step "Pulling AI Models"
echo "  Pulling in priority order (smallest first for fastest availability):"
echo ""

echo "  [1/3] qwen2.5-coder:32b (~20GB)..."
ollama pull qwen2.5-coder:32b \
  && ok "qwen2.5-coder:32b ready" \
  || warn "qwen2.5-coder:32b failed — retry: ollama pull qwen2.5-coder:32b"

echo ""
echo "  [2/3] qwen2.5:72b (~40GB)..."
ollama pull qwen2.5:72b \
  && ok "qwen2.5:72b ready" \
  || warn "qwen2.5:72b failed — retry: ollama pull qwen2.5:72b"

echo ""
echo "  [3/3] minimax-text:229b (~130GB — this takes a while)..."
ollama pull minimax-text:229b \
  && ok "minimax-text:229b ready" \
  || warn "minimax-text:229b failed — retry: ollama pull minimax-text:229b"

echo ""
echo "  Models loaded:"
ollama list 2>/dev/null || true

# ── 5. SSH + Firewall ────────────────────────────────────────────
step "SSH access + Firewall"
mkdir -p ~/.ssh && chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys

grep -qF "$EVAN_SSH_KEY" ~/.ssh/authorized_keys 2>/dev/null || \
  echo "$EVAN_SSH_KEY" >> ~/.ssh/authorized_keys
ok "Evan's SSH key added"

sudo systemsetup -setremotelogin on 2>/dev/null && ok "Remote Login enabled" || \
  warn "Enable Remote Login in System Settings → Sharing"

sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on 2>/dev/null || true
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setstealthmode on 2>/dev/null || true

# On-prem firewall: allow LAN + Tailscale, block everything else
cat > /tmp/sovereign-private-pf.conf << 'PFEOF'
set skip on lo0
table <tailscale> { 100.64.0.0/10 }
table <lan> { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 }
block in all
pass out all keep state
# SSH from Tailscale only (remote management)
pass in on utun+ proto tcp from <tailscale> to any port 22 keep state
pass in on en0 proto tcp from <tailscale> to any port 22 keep state
# Ollama API from LAN + Tailscale (customer Minis on local network)
pass in proto tcp from <lan> to any port 11434 keep state
pass in on utun+ proto tcp from <tailscale> to any port 11434 keep state
# Screen sharing from Tailscale only
pass in on utun+ proto tcp from <tailscale> to any port 5900 keep state
# ICMP + WireGuard
pass in proto icmp from <tailscale>
pass in proto udp to any port 41641
PFEOF

sudo cp /tmp/sovereign-private-pf.conf /etc/pf.anchors/sovereign 2>/dev/null || warn "Could not write pf anchor"
if ! grep -q "sovereign" /etc/pf.conf 2>/dev/null; then
  printf '\nanchor "sovereign"\nload anchor "sovereign" from "/etc/pf.anchors/sovereign"\n' | \
    sudo tee -a /etc/pf.conf > /dev/null 2>/dev/null || true
fi
sudo pfctl -f /etc/pf.conf 2>/dev/null || true
sudo pfctl -e 2>/dev/null || true
ok "Firewall: Ollama from LAN+Tailscale, SSH from Tailscale only"

# Restart Ollama with 0.0.0.0 binding
brew services restart ollama 2>/dev/null || true

# ── Summary ──────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════"
if [ ${#ERRORS[@]} -eq 0 ]; then
  echo "✅ Studio #$STUDIO_NUM ($HOSTNAME) setup complete"
else
  echo "⚠️  Studio #$STUDIO_NUM setup with ${#ERRORS[@]} warning(s)"
fi
echo "══════════════════════════════════════════════════"
echo ""
echo "  Tailscale hostname : $HOSTNAME"
echo "  Tailscale IP       : $TS_IP"
echo "  Ollama API         : http://$TS_IP:11434"
echo "  SSH                : ssh $USER@$TS_IP"
echo ""
echo "  Models:"
ollama list 2>/dev/null | tail -n +2 | awk '{print "    •", $1}' || true
echo ""

if [ ${#ERRORS[@]} -gt 0 ]; then
  echo "  Warnings:"
  for e in "${ERRORS[@]}"; do echo "    • $e"; done
  echo ""
fi

echo "  ┌────────────────────────────────────────────────┐"
echo "  │ Next: set up customer Minis to point here     │"
echo "  │                                                │"
echo "  │ On each Mini run:                              │"
echo "  │  bash provision.sh --flip-to-studio $TS_IP     │"
echo "  │                                                │"
echo "  │ For multi-Studio load balancing:               │"
echo "  │  Configure reverse proxy or round-robin DNS    │"
echo "  │  across all Studio Tailscale IPs               │"
echo "  └────────────────────────────────────────────────┘"
echo ""
