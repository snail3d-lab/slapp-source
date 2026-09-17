#!/bin/bash
# slapp home-base installer — one command turns a Mac into the fleet's home.
# Installs the bridge (phone door) and slappd (session pilot) as LaunchAgents.
# Requires: macOS, node >= 20, python3, Tailscale signed in.
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
BRIDGE_SRC="$HOME/.monocle/bridge"
SLAPPD="$HERE/slappd.mjs"
NODE="$(which node)"
PY="$(which python3)"
UID_N="$(id -u)"

echo "── slapp home base ──────────────────────────────"

# 0. preflight
for tool in "$NODE" "$PY"; do
  [ -x "$tool" ] || { echo "missing $tool — install it first"; exit 1; }
done
TS="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
if [ -x "$TS" ]; then
  IP="$($TS ip -4 2>/dev/null | head -1)"
  [ -n "$IP" ] && echo "tailscale up: $IP" || echo "warning: tailscale installed but not up — sign in"
else
  echo "note: Tailscale not found — install it so your phone can reach this Mac anywhere"
fi

# 1. bridge in place
mkdir -p "$BRIDGE_SRC"
if [ -d "$HERE/bridge/monocle_bridge" ]; then
  rsync -a --delete --exclude __pycache__ "$HERE/bridge/monocle_bridge/" "$BRIDGE_SRC/monocle_bridge/"
fi
cd "$BRIDGE_SRC"
[ -d venv ] || "$PY" -m venv venv
./venv/bin/pip -q install aiohttp || true
find "$BRIDGE_SRC/monocle_bridge" -name "*.pyc" -delete 2>/dev/null || true

# 2. slappd deps
cd "$HERE"
[ -d node_modules ] || npm install --silent

# 3. LaunchAgents
PL_BRIDGE=~/Library/LaunchAgents/com.snail3d.bridge.plist
PL_SLAPPD=~/Library/LaunchAgents/com.snail3d.slappd.plist
cat > "$PL_BRIDGE" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.snail3d.bridge</string>
  <key>ProgramArguments</key><array>
    <string>$BRIDGE_SRC/venv/bin/python</string>
    <string>-m</string><string>monocle_bridge.bridge</string>
  </array>
  <key>WorkingDirectory</key><string>$BRIDGE_SRC</string>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/bridge.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/bridge.log</string>
</dict></plist>
PLIST
cat > "$PL_SLAPPD" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.snail3d.slappd</string>
  <key>ProgramArguments</key><array>
    <string>$NODE</string><string>$SLAPPD</string>
  </array>
  <key>WorkingDirectory</key><string>$HERE</string>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/slappd.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/slappd.log</string>
</dict></plist>
PLIST

launchctl bootout "gui/$UID_N/com.snail3d.bridge" 2>/dev/null || true
launchctl bootout "gui/$UID_N/com.snail3d.slappd" 2>/dev/null || true
launchctl bootstrap "gui/$UID_N" "$PL_BRIDGE"
launchctl bootstrap "gui/$UID_N" "$PL_SLAPPD"

sleep 3
echo "── health ──"
curl -s -m 4 http://127.0.0.1:8651/health | head -c 120; echo
curl -s -m 4 http://127.0.0.1:8123/api/health | head -c 120; echo
echo "done. pair your phone from the app: settings → pair (window opens automatically for 90s after each boot)."
