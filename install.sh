#!/bin/zsh
# Installs ClaudeDrop on this Mac from the installer folder this script sits in.
# Builds from source when the Xcode command line tools are present, otherwise
# installs the prebuilt app. Never touches an existing ~/ClaudeDrop/Inbox.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/ClaudeDrop"

echo "==> Copying ClaudeDrop to $DEST"
mkdir -p "$DEST/Inbox"
if [[ "$HERE" != "$DEST" ]]; then
  rm -rf "$DEST/src" "$DEST/connector"
  cp -R "$HERE/src" "$HERE/connector" "$DEST/"
  cp "$HERE/build.sh" "$HERE/install.sh" "$DEST/"
fi
chmod +x "$DEST/build.sh" "$DEST/install.sh"

pkill -x ClaudeDrop 2>/dev/null || true

if [[ -z "${CLAUDEDROP_FORCE_PREBUILT:-}" ]] && xcode-select -p >/dev/null 2>&1 && xcrun -f swiftc >/dev/null 2>&1; then
  echo "==> Building the app from source"
  "$DEST/build.sh"
elif [[ -d "$HERE/prebuilt/ClaudeDrop.app" ]]; then
  echo "==> No Swift compiler found, installing the prebuilt app"
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/ClaudeDrop.app"
  cp -R "$HERE/prebuilt/ClaudeDrop.app" "$HOME/Applications/ClaudeDrop.app"
  xattr -dr com.apple.quarantine "$HOME/Applications/ClaudeDrop.app" 2>/dev/null || true
  codesign --force --sign - "$HOME/Applications/ClaudeDrop.app"
else
  echo "!! No Swift compiler and no prebuilt app in this folder. Install the command line tools with: xcode-select --install"
  exit 1
fi

echo "==> Registering the connector with the Claude desktop app"
NODE="$(command -v node || true)"
for candidate in /opt/homebrew/bin/node /usr/local/bin/node; do
  [[ -z "$NODE" && -x "$candidate" ]] && NODE="$candidate"
done
CFG_DIR="$HOME/Library/Application Support/Claude"
CONNECTOR_OK=0
if [[ -z "$NODE" ]]; then
  echo "!! Node.js was not found, so the connector was not registered."
  echo "   Install Node (https://nodejs.org or 'brew install node'), then run this script again."
elif [[ ! -d "$CFG_DIR" ]]; then
  echo "!! The Claude desktop app's settings folder was not found, so the connector was not registered."
  echo "   Open the Claude desktop app once, then run this script again."
else
  CFG="$CFG_DIR/claude_desktop_config.json"
  [[ -f "$CFG" ]] && cp "$CFG" "$CFG.bak-before-claudedrop"
  "$NODE" - "$CFG" "$NODE" "$DEST/connector/server.mjs" <<'JS'
const fs = require('fs');
const [cfg, node, server] = process.argv.slice(2);
let config = {};
if (fs.existsSync(cfg)) {
  const raw = fs.readFileSync(cfg, 'utf8').trim();
  if (raw) config = JSON.parse(raw);
}
config.mcpServers = config.mcpServers || {};
config.mcpServers.claudedrop = { command: node, args: [server] };
fs.writeFileSync(cfg + '.tmp', JSON.stringify(config, null, 2));
fs.renameSync(cfg + '.tmp', cfg);
JS
  CONNECTOR_OK=1
fi

if [[ -z "${CLAUDEDROP_NO_LAUNCH:-}" ]]; then
  open "$HOME/Applications/ClaudeDrop.app"
fi

echo
echo "ClaudeDrop is installed. Press Control+Option+D to open the drop panel."
if [[ "$CONNECTOR_OK" == 1 ]]; then
  echo "Quit and reopen the Claude desktop app so it loads the connector."
fi
