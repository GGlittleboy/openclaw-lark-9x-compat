#!/usr/bin/env bash
# Remove everything patch.sh installed (openclaw-side shim + exports entries).
# The lark plugin files are left alone — reinstall the plugin to restore them:
#   openclaw plugins install @larksuite/openclaw-lark@latest --force
set -euo pipefail
say() { printf '\033[1;32m[compat]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[compat] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

OPENCLAW_ROOT="${1:-}"
if [[ -z "$OPENCLAW_ROOT" ]]; then
  BIN="$(command -v openclaw || true)"
  if [[ -n "$BIN" ]]; then
    RESOLVED="$(readlink -f "$BIN")"
    if [[ -f "$RESOLVED" && "$RESOLVED" == *.js ]]; then
      OPENCLAW_ROOT="$(dirname "$(dirname "$RESOLVED")")"
    elif grep -q 'lib/node_modules/openclaw' "$RESOLVED" 2>/dev/null; then
      RAW="$(grep -o '[^ "]*lib/node_modules/openclaw' "$RESOLVED" | head -1)"
      OPENCLAW_ROOT="${RAW/#\$HOME/$HOME}"
    fi
  fi
  if [[ -z "$OPENCLAW_ROOT" ]]; then
    for c in \
      "$(npm root -g 2>/dev/null || true)/openclaw" \
      /usr/local/lib/node_modules/openclaw /usr/lib/node_modules/openclaw; do
      [[ -n "$c" && -f "$c/package.json" ]] && { OPENCLAW_ROOT="$c"; break; }
    done
  fi
fi
OPENCLAW_ROOT="${OPENCLAW_ROOT%/}"
[[ -n "$OPENCLAW_ROOT" && -f "$OPENCLAW_ROOT/package.json" ]] \
  || die "cannot locate the global openclaw package; pass its path as argument"

rm -f "$OPENCLAW_ROOT/dist/plugin-sdk.js" && say "removed shim dist/plugin-sdk.js"

node - "$OPENCLAW_ROOT/package.json" <<'EOF'
const fs = require('fs');
const p = process.argv[2];
const pkg = JSON.parse(fs.readFileSync(p, 'utf8'));
delete (pkg.exports || {})['./plugin-sdk'];
delete (pkg.exports || {})['./plugin-sdk/channel-runtime'];
fs.writeFileSync(p, JSON.stringify(pkg, null, 2) + '\n');
console.log('[compat] exports entries removed');
EOF

say "done. Restart the gateway: openclaw gateway restart"
