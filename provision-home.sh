#!/bin/bash
# ══════════════════════════════════════════════════════════════════
# Sovereign ATX — Home Deployment Provisioner v1
# ══════════════════════════════════════════════════════════════════
# For at-home / at-office deployments using Anthropic Claude API.
# No local inference cluster required. Fully managed via Tailscale.
#
# Env vars required:
#   TAILSCALE_AUTHKEY  — tskey-auth-...
#
# Auth — choose ONE:
#   ANTHROPIC_API_KEY  — sk-ant-api03-... (pay-as-you-go API key)
#   USE_OAUTH=true     — Claude Max/Pro subscription via setup-token
#                        (token pasted interactively at end of provisioning)
#
# Optional:
#   DISCORD_BOT_TOKEN  — if customer has a Discord bot
#   SLACK_APP_TOKEN    — xapp-... (Socket Mode)
#   SLACK_BOT_TOKEN    — xoxb-...
#   SOUL_URL           — URL to download customer SOUL.md
#   SOUL_PATH          — local path to SOUL.md
#   CUSTOMER_SSH_KEY   — customer's own SSH pubkey (for their own access)
#   KAVIN_SSH_KEY      — override default Kavin key
#   CIVIC_TOOLKIT_ID   — from civic.com/dashboard (optional but recommended)
#
# Usage (API key):
#   TAILSCALE_AUTHKEY=tskey-... ANTHROPIC_API_KEY=sk-ant-... \
#     bash provision-home.sh geoff "Geoff"
#
# Usage (Claude Max/Pro OAuth):
#   TAILSCALE_AUTHKEY=tskey-... USE_OAUTH=true \
#     bash provision-home.sh geoff "Geoff"
#   (You'll be prompted to paste a setup-token at the end)
# ══════════════════════════════════════════════════════════════════

set -o pipefail

STEP=0
TOTAL_STEPS=6
ERRORS=()

ok()  { echo "  ✅ $*"; }
warn(){ echo "  ⚠️  $*"; ERRORS+=("$*"); }
die() { echo ""; echo "❌ FATAL: $*"; exit 1; }
step(){ STEP=$((STEP+1)); echo ""; echo "[$STEP/$TOTAL_STEPS] $*"; }

# ── Args + env ──────────────────────────────────────────────────
CUSTOMER_ID="${1:-unknown}"
CUSTOMER_NAME="${2:-Customer}"
TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY:-}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
DISCORD_BOT_TOKEN="${DISCORD_BOT_TOKEN:-}"
SLACK_APP_TOKEN="${SLACK_APP_TOKEN:-}"
SLACK_BOT_TOKEN="${SLACK_BOT_TOKEN:-}"
SOUL_URL="${SOUL_URL:-}"
SOUL_PATH="${SOUL_PATH:-}"
CUSTOMER_SSH_KEY="${CUSTOMER_SSH_KEY:-}"
KAVIN_SSH_KEY="${KAVIN_SSH_KEY:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBWxGpxh3i6Y44mYapCqvJUwZtggS2L6hc+PGx+XS2DR kavin@sovereign}"
CIVIC_TOOLKIT_ID="${CIVIC_TOOLKIT_ID:-}"
EVAN_SSH_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINMkIrNBX0fu2O0IyAqJu3E/ZSgzJInbtS9lvxrN8UBq evan@sovereign"
USE_OAUTH="${USE_OAUTH:-false}"

# Determine auth mode
if [ "$USE_OAUTH" = "true" ]; then
  AUTH_MODE="oauth"
  AUTH_LABEL="Claude Max/Pro subscription (OAuth setup-token)"
elif [ -n "$ANTHROPIC_API_KEY" ]; then
  AUTH_MODE="apikey"
  AUTH_LABEL="Anthropic API key"
else
  die "Set either ANTHROPIC_API_KEY=sk-ant-... or USE_OAUTH=true"
fi

echo ""
echo "══════════════════════════════════════════════════"
echo " Sovereign ATX — Home Provisioner v2"
echo " Customer : $CUSTOMER_NAME ($CUSTOMER_ID)"
echo " User     : $USER"
echo " Auth     : $AUTH_LABEL"
echo "══════════════════════════════════════════════════"

[ -z "$TAILSCALE_AUTHKEY" ] && die "TAILSCALE_AUTHKEY not set."

# ── 1. Xcode Command Line Tools ──────────────────────────────────
step "Xcode Command Line Tools"
if xcode-select -p &>/dev/null; then
  ok "Already installed at $(xcode-select -p)"
else
  echo "  Installing Xcode CLT..."
  xcode-select --install 2>/dev/null || true
  echo "  Waiting (up to 5 minutes)..."
  for i in $(seq 1 60); do
    xcode-select -p &>/dev/null && break; sleep 5
  done
  xcode-select -p &>/dev/null && ok "Installed" || die "Xcode CLT timed out. Run 'xcode-select --install' manually then re-run."
fi

# ── 2. Homebrew ──────────────────────────────────────────────────
step "Homebrew"
if command -v brew &>/dev/null; then
  ok "Already installed"
else
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
    || die "Homebrew install failed"
  ok "Installed"
fi
[ -f /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"
grep -q 'brew shellenv' ~/.zprofile 2>/dev/null || \
  echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
brew update --quiet 2>/dev/null || warn "brew update failed (non-fatal)"

# ── 3. Tailscale ─────────────────────────────────────────────────
step "Tailscale"
if brew list --cask tailscale 2>/dev/null | grep -q tailscale; then
  ok "Already installed"
else
  brew install --cask tailscale || die "Tailscale install failed"
  ok "Installed"
fi

open -a Tailscale 2>/dev/null || true
echo "  Waiting for Tailscale daemon (up to 30s)..."
for i in $(seq 1 15); do sleep 2; /Applications/Tailscale.app/Contents/MacOS/Tailscale status &>/dev/null && break; done

TAILSCALE_BIN="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
if [ -f "$TAILSCALE_BIN" ]; then
  sudo "$TAILSCALE_BIN" up \
    --authkey="$TAILSCALE_AUTHKEY" \
    --hostname="sovereign-${CUSTOMER_ID}" \
    --accept-routes \
    --timeout=30s \
    && ok "Joined tailnet as sovereign-${CUSTOMER_ID}" \
    || warn "tailscale up failed — run manually"
else
  warn "Tailscale binary not found — run tailscale up manually"
fi

# ── 4. Node.js + OpenClaw ────────────────────────────────────────
step "Node.js + OpenClaw"
command -v node &>/dev/null || brew install node || die "Node.js install failed"
ok "Node $(node --version)"

if ! command -v openclaw &>/dev/null; then
  npm install -g openclaw || sudo npm install -g openclaw || die "OpenClaw install failed"
fi
ok "OpenClaw $(openclaw --version 2>/dev/null || echo 'installed')"

# ── 5. Configure OpenClaw + LaunchAgent ──────────────────────────
step "Configuring OpenClaw"
mkdir -p ~/.openclaw/workspace

# API key / auth setup
if [ "$AUTH_MODE" = "apikey" ]; then
  grep -q "ANTHROPIC_API_KEY" ~/.zprofile 2>/dev/null && \
    sed -i '' "s|export ANTHROPIC_API_KEY=.*|export ANTHROPIC_API_KEY=\"${ANTHROPIC_API_KEY}\"|" ~/.zprofile || \
    echo "export ANTHROPIC_API_KEY=\"${ANTHROPIC_API_KEY}\"" >> ~/.zprofile
  export ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"
  ok "API key saved to ~/.zprofile"
else
  ok "OAuth mode — setup-token will be pasted at the end of provisioning"
fi

# zsh completions fix
grep -q 'compinit' ~/.zshrc 2>/dev/null || \
  echo 'autoload -Uz compinit && compinit' >> ~/.zshrc

# Build openclaw.json
DISC_TOKEN="$DISCORD_BOT_TOKEN"
SLACK_APP="$SLACK_APP_TOKEN"
SLACK_BOT="$SLACK_BOT_TOKEN"
CUR_USER="$USER"

python3 - <<PYEOF
import json, os

config = {
  "agents": {
    "defaults": {
      "model": {
        "primary": "anthropic/claude-sonnet-4-6"
      },
      "workspace": "/Users/${CUR_USER}/.openclaw/workspace",
      "contextPruning": {"mode": "cache-ttl", "ttl": "1h"},
      "compaction": {"mode": "safeguard"},
      "heartbeat": {"every": "30m"}
    }
  },
  "commands": {"native": "auto", "nativeSkills": "auto", "restart": True},
  "gateway": {"mode": "local"}
}

channels = {}

if "${DISC_TOKEN}".strip():
    channels["discord"] = {
        "enabled": True,
        "token": "${DISC_TOKEN}",
        "requireMention": True,
        "dmPolicy": "allow"
    }
    print("  Discord channel configured")

if "${SLACK_APP}".strip() and "${SLACK_BOT}".strip():
    channels["slack"] = {
        "enabled": True,
        "mode": "socket",
        "appToken": "${SLACK_APP}",
        "botToken": "${SLACK_BOT}"
    }
    print("  Slack channel configured")

if channels:
    config["channels"] = channels

path = f"/Users/${CUR_USER}/.openclaw/openclaw.json"
with open(path, "w") as f:
    json.dump(config, f, indent=2)
os.chmod(path, 0o600)
print("  Config written")
PYEOF

# ── 5.5. Civic Nexus (AI Security Layer) ────────────────────────
echo ""
echo "[5.5/6] Civic Nexus — AI Security Layer"
if [ -n "$CIVIC_TOOLKIT_ID" ]; then
  # Install Civic skill from ClawHub
  if command -v clawhub &>/dev/null; then
    clawhub install civictechuser/openclaw-civic-skill --yes 2>/dev/null \
      && ok "Civic skill installed" \
      || warn "Civic skill install failed — install manually: clawhub install civictechuser/openclaw-civic-skill"
  else
    warn "clawhub not found — install Civic skill manually after setup"
  fi

  # Add Civic toolkit ID to openclaw.json
  python3 - <<PYEOF
import json, os
path = f"/Users/${CUR_USER}/.openclaw/openclaw.json"
with open(path) as f:
    config = json.load(f)
config.setdefault("skills", {})["civic"] = {
    "enabled": True,
    "toolkitId": "${CIVIC_TOOLKIT_ID}"
}
with open(path, "w") as f:
    json.dump(config, f, indent=2)
os.chmod(path, 0o600)
print("  Civic Nexus configured in openclaw.json")
PYEOF
  ok "Civic Nexus configured (toolkit: ${CIVIC_TOOLKIT_ID})"
  echo "  ⚠️  IMPORTANT: Authorize Civic from a DIFFERENT machine — never from this Mini"
  echo "  ⚠️  Go to civic.com/dashboard on your personal Mac to complete authorization"
else
  echo "  ℹ️  Civic Nexus not configured — add CIVIC_TOOLKIT_ID later via openclaw config"
fi

# SOUL.md
if [ -n "$SOUL_PATH" ] && [ -f "$SOUL_PATH" ]; then
  cp "$SOUL_PATH" ~/.openclaw/workspace/SOUL.md && ok "SOUL.md installed"
elif [ -n "$SOUL_URL" ]; then
  curl -sf "$SOUL_URL" -o ~/.openclaw/workspace/SOUL.md && ok "SOUL.md downloaded" || warn "SOUL.md download failed"
fi

# Install LaunchAgent
openclaw gateway install 2>/dev/null && ok "LaunchAgent installed" || warn "LaunchAgent install failed"

# Bake keys into plist + set KeepAlive
PLIST=~/Library/LaunchAgents/ai.openclaw.gateway.plist
if [ -f "$PLIST" ]; then
  /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables dict" "$PLIST" 2>/dev/null || true
  if [ "$AUTH_MODE" = "apikey" ]; then
    /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:ANTHROPIC_API_KEY string ${ANTHROPIC_API_KEY}" "$PLIST" 2>/dev/null || \
      /usr/libexec/PlistBuddy -c "Set :EnvironmentVariables:ANTHROPIC_API_KEY ${ANTHROPIC_API_KEY}" "$PLIST"
    ok "API key baked into LaunchAgent plist"
  fi
  if [ -n "$SLACK_APP_TOKEN" ]; then
    /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:SLACK_APP_TOKEN string ${SLACK_APP_TOKEN}" "$PLIST" 2>/dev/null || \
      /usr/libexec/PlistBuddy -c "Set :EnvironmentVariables:SLACK_APP_TOKEN ${SLACK_APP_TOKEN}" "$PLIST"
    /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:SLACK_BOT_TOKEN string ${SLACK_BOT_TOKEN}" "$PLIST" 2>/dev/null || \
      /usr/libexec/PlistBuddy -c "Set :EnvironmentVariables:SLACK_BOT_TOKEN ${SLACK_BOT_TOKEN}" "$PLIST"
  fi
  /usr/libexec/PlistBuddy -c "Set :KeepAlive true" "$PLIST" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :KeepAlive bool true" "$PLIST" 2>/dev/null || true
  if [ "$AUTH_MODE" = "apikey" ]; then ok "Keys baked into LaunchAgent + KeepAlive=true"; else ok "KeepAlive=true set in LaunchAgent"; fi
else
  warn "LaunchAgent plist not found"
fi

# Start gateway
launchctl stop ai.openclaw.gateway 2>/dev/null || true; sleep 2
launchctl start ai.openclaw.gateway 2>/dev/null || true; sleep 3
launchctl list | grep -q "ai.openclaw.gateway" && \
  ok "Gateway running — survives reboots and crashes" || \
  warn "Gateway not running — check ~/.openclaw/logs/gateway.err.log"

# ── 6. SSH keys + Firewall ───────────────────────────────────────
step "SSH access + Firewall"
mkdir -p ~/.ssh && chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys

grep -qF "$EVAN_SSH_KEY" ~/.ssh/authorized_keys 2>/dev/null || echo "$EVAN_SSH_KEY" >> ~/.ssh/authorized_keys
ok "Evan SSH key added"

grep -qF "$KAVIN_SSH_KEY" ~/.ssh/authorized_keys 2>/dev/null || echo "$KAVIN_SSH_KEY" >> ~/.ssh/authorized_keys
ok "Kavin SSH key added"

if [ -n "$CUSTOMER_SSH_KEY" ]; then
  grep -qF "$CUSTOMER_SSH_KEY" ~/.ssh/authorized_keys 2>/dev/null || echo "$CUSTOMER_SSH_KEY" >> ~/.ssh/authorized_keys
  ok "Customer SSH key added"
fi

sudo systemsetup -setremotelogin on 2>/dev/null && ok "Remote Login enabled" || \
  warn "Enable Remote Login: System Settings → Sharing → Remote Login"
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate off 2>/dev/null && ok "Application Firewall disabled (pf handles security)" || true

# pf firewall — home deployment (no Ollama port needed)
cat > /tmp/sovereign-pf-home.conf << 'PFEOF'
set skip on lo0
table <tailscale> { 100.64.0.0/10 }
block in all
pass out all keep state
pass in on utun+ proto tcp from <tailscale> to any port 22 keep state
pass in on en0 proto tcp from <tailscale> to any port 22 keep state
pass in on utun+ proto tcp from <tailscale> to any port 5900 keep state
pass in proto icmp from <tailscale>
pass in proto udp to any port 41641
PFEOF

sudo cp /tmp/sovereign-pf-home.conf /etc/pf.anchors/sovereign 2>/dev/null || warn "Could not write pf anchor"
if ! grep -q "sovereign" /etc/pf.conf 2>/dev/null; then
  printf '\nanchor "sovereign"\nload anchor "sovereign" from "/etc/pf.anchors/sovereign"\n' | \
    sudo tee -a /etc/pf.conf > /dev/null 2>/dev/null || true
fi
sudo pfctl -f /etc/pf.conf 2>/dev/null || true
sudo pfctl -e 2>/dev/null || true
ok "Firewall: SSH/VNC restricted to Tailscale only"

# ── Summary ──────────────────────────────────────────────────────
TS_IP=$("$TAILSCALE_BIN" ip -4 2>/dev/null || echo "pending")

echo ""
echo "  Tailscale hostname : sovereign-${CUSTOMER_ID}"
echo "  Tailscale IP       : ${TS_IP}"
echo "  Auth               : $AUTH_LABEL"
echo "  OpenClaw           : running via LaunchAgent"
echo "  Auto-restart       : KeepAlive=true"
echo "  SSH                : ssh ${USER}@${TS_IP}"
echo "  Civic Nexus        : ${CIVIC_TOOLKIT_ID:-not configured}"
echo ""

if [ ${#ERRORS[@]} -gt 0 ]; then
  echo "  ⚠️  Items needing attention:"
  for e in "${ERRORS[@]}"; do echo "    • $e"; done
  echo ""
fi

# ── OAuth setup-token (if USE_OAUTH=true) ────────────────────────
if [ "$AUTH_MODE" = "oauth" ]; then
  echo ""
  echo "══════════════════════════════════════════════════"
  echo " ⚡ FINAL STEP: Paste your Claude setup-token"
  echo "══════════════════════════════════════════════════"
  echo ""
  echo "  Have your setup-token ready from your personal Mac."
  echo "  (Generated by running: claude setup-token)"
  echo ""
  openclaw models auth paste-token --provider anthropic
  echo ""
  if openclaw models status --check 2>/dev/null; then
    ok "Claude subscription auth verified ✓"
    OAUTH_OK=true
  else
    warn "Auth check failed — re-run after setup: openclaw models auth paste-token --provider anthropic"
    OAUTH_OK=false
  fi
  echo ""
fi

echo "══════════════════════════════════════════════════"
if [ ${#ERRORS[@]} -eq 0 ]; then
  echo "✅ $CUSTOMER_NAME is fully provisioned"
else
  echo "⚠️  $CUSTOMER_NAME provisioned — ${#ERRORS[@]} item(s) need attention"
fi
echo "══════════════════════════════════════════════════"
echo ""
echo "  ┌─────────────────────────────────────────────┐"
echo "  │ Done. Close this terminal.                  │"
echo "  │ The AI agent keeps running automatically.   │"
echo "  │                                             │"
echo "  │ To check remotely:                          │"
echo "  │   ssh ${USER}@${TS_IP}                      │"
echo "  │   openclaw status                           │"
if [ "$AUTH_MODE" = "oauth" ]; then
echo "  │                                             │"
echo "  │ Token renews in ~1 year. Kavin will remind  │"
echo "  │ you when it's time.                         │"
fi
echo "  └─────────────────────────────────────────────┘"
echo ""
