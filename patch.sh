#!/usr/bin/env bash
# openclaw-lark-9x-compat: bridge @larksuite/openclaw-lark (<= 2026.8.5) to OpenClaw >= 2026.9.1
#
# What it does:
#   1. Adds a shim file  dist/plugin-sdk.js  re-exporting plugin-sdk/core
#   2. Adds two missing entries to openclaw's package.json "exports":
#        ./plugin-sdk                 -> dist/plugin-sdk.js (shim)
#        ./plugin-sdk/channel-runtime -> dist/plugin-sdk/channel-message.js
#   3. Rewrites two CJS-incompatible `import.meta` usages inside the installed
#      lark plugin (src/core/version.js, src/core/token-store.js)
#
# Idempotent: safe to run multiple times. Creates timestamped backups of every
# file it modifies. Tested with OpenClaw 2026.9.1 + openclaw-lark 2026.7.16.
set -euo pipefail

say()  { printf '\033[1;32m[compat]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[compat]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[compat] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# --- locate the ACTIVE openclaw package root ----------------------------------
# Resolve through the `openclaw` on PATH (wrapper scripts exec <pkg>/dist/...),
# never by globbing node installs — stale node versions may hold old copies.
OPENCLAW_ROOT="${1:-}"
if [[ -z "$OPENCLAW_ROOT" ]]; then
  BIN="$(command -v openclaw || true)"
  if [[ -n "$BIN" ]]; then
    RESOLVED="$(readlink -f "$BIN")"
    if [[ -d "$RESOLVED" ]]; then          # wrapper is a directory? no — guard
      :
    elif [[ -f "$RESOLVED" && "$RESOLVED" == *.js ]]; then
      # PATH entry IS the cli entry (npm shim resolved to dist/index.js)
      OPENCLAW_ROOT="$(dirname "$(dirname "$RESOLVED")")"
    elif grep -q 'lib/node_modules/openclaw' "$RESOLVED" 2>/dev/null; then
      # bash wrapper containing the package path
      RAW="$(grep -o '[^ "]*lib/node_modules/openclaw' "$RESOLVED" | head -1)"
      OPENCLAW_ROOT="${RAW/#\$HOME/$HOME}"
    fi
  fi
  # fallbacks: npm global roots
  if [[ -z "$OPENCLAW_ROOT" ]]; then
    for c in \
      "$(npm root -g 2>/dev/null || true)/openclaw" \
      "$HOME/.npm-global/lib/node_modules/openclaw" \
      /usr/local/lib/node_modules/openclaw /usr/lib/node_modules/openclaw; do
      [[ -n "$c" && -f "$c/package.json" ]] && { OPENCLAW_ROOT="$c"; break; }
    done
  fi
fi
OPENCLAW_ROOT="${OPENCLAW_ROOT%/}"
[[ -n "$OPENCLAW_ROOT" && -f "$OPENCLAW_ROOT/package.json" ]] \
  || die "cannot locate the global openclaw package; pass its path: $0 /path/to/node_modules/openclaw"
say "openclaw root: $OPENCLAW_ROOT"

OC_VER=$(node -p "require('$OPENCLAW_ROOT/package.json').version" 2>/dev/null || echo unknown)
say "openclaw version: $OC_VER"
[[ -d "$OPENCLAW_ROOT/dist/plugin-sdk" ]] || die "$OPENCLAW_ROOT/dist/plugin-sdk not found — is this OpenClaw 2026.9.x?"

BACKUP_SUFFIX=".bak-compat-$(date +%Y%m%d-%H%M%S)"

# --- step 1: shim -------------------------------------------------------------
SHIM="$OPENCLAW_ROOT/dist/plugin-sdk.js"
if [[ -f "$SHIM" ]]; then
  say "shim already exists, skipping: $SHIM"
else
  cat > "$SHIM" <<'EOF'
// Compat shim (openclaw-lark-9x-compat): re-export plugin-sdk core for plugins
// built against the pre-2026.9 bare "openclaw/plugin-sdk" entry point.
// Remove this file and the two package.json exports entries once your plugins
// ship builds targeting OpenClaw >= 2026.9 natively.
export * from "./plugin-sdk/core.js";
EOF
  say "wrote shim: $SHIM"
fi

# --- step 2: package.json exports ---------------------------------------------
PKG="$OPENCLAW_ROOT/package.json"
cp "$PKG" "$PKG$BACKUP_SUFFIX"
node - "$PKG" <<'EOF'
const fs = require('fs');
const p = process.argv[2];
const pkg = JSON.parse(fs.readFileSync(p, 'utf8'));
const e = pkg.exports || {};
let changed = false;
if (!e['./plugin-sdk']) {
  e['./plugin-sdk'] = { types: './dist/plugin-sdk/core.d.ts', default: './dist/plugin-sdk.js' };
  changed = true;
}
if (!e['./plugin-sdk/channel-runtime']) {
  e['./plugin-sdk/channel-runtime'] = { types: './dist/plugin-sdk/channel-message.d.ts', default: './dist/plugin-sdk/channel-message.js' };
  changed = true;
}
if (changed) {
  fs.writeFileSync(p, JSON.stringify(pkg, null, 2) + '\n');
  console.log('[compat] exports patched');
} else {
  console.log('[compat] exports already present, skipping');
}
EOF

# --- step 3: lark plugin import.meta fixes ------------------------------------
FOUND=0
for LARK in "$HOME"/.openclaw/npm/projects/*openclaw-lark*/node_modules/@larksuite/openclaw-lark; do
  [[ -d "$LARK/src/core" ]] || continue
  FOUND=1
  say "patching lark plugin: $LARK"

  V="$LARK/src/core/version.js"
  if grep -qF 'fileURLToPath)(import.meta.url)' "$V"; then
    cp "$V" "$V$BACKUP_SUFFIX"
    node - "$V" <<'EOF'
const fs = require('fs');
const p = process.argv[2];
const old = `        const __filename = (0, node_url_1.fileURLToPath)(import.meta.url);
        const __dirname = (0, node_path_1.dirname)(__filename);
        const packageJsonPath = (0, node_path_1.join)(__dirname, '..', '..', 'package.json');`;
const neu = `        const packageJsonPath = (0, node_path_1.join)(__dirname, '..', '..', 'package.json');`;
const s = fs.readFileSync(p, 'utf8');
if (!s.includes(old)) { console.error('[compat] ERROR: version.js pattern not found'); process.exit(1); }
fs.writeFileSync(p, s.replace(old, neu));
console.log('[compat] version.js patched (CJS __dirname)');
EOF
  else
    say "version.js already patched"
  fi

  T="$LARK/src/core/token-store.js"
  if grep -qF "? __filename : import.meta.url)" "$T"; then
    cp "$T" "$T$BACKUP_SUFFIX"
    node - "$T" <<'EOF'
const fs = require('fs');
const p = process.argv[2];
const old = "const _require = (0, node_module_1.createRequire)(typeof __filename !== 'undefined' ? __filename : import.meta.url);";
const neu = "const _require = (0, node_module_1.createRequire)(__filename);";
const s = fs.readFileSync(p, 'utf8');
if (!s.includes(old)) { console.error('[compat] ERROR: token-store.js pattern not found'); process.exit(1); }
fs.writeFileSync(p, s.replace(old, neu));
console.log('[compat] token-store.js patched (CJS __filename)');
EOF
  else
    say "token-store.js already patched"
  fi
done

# --- step 4: runtime API rename (loadConfig -> current in 2026.9) -------------
for LARK in "$HOME"/.openclaw/npm/projects/*openclaw-lark*/node_modules/@larksuite/openclaw-lark; do
  [[ -f "$LARK/index.js" ]] || continue
  IDX="$LARK/index.js"
  if grep -qF 'openclaw-lark-9x-compat: 2026.9 renamed' "$IDX"; then
    say "index.js runtime alias already present"
    continue
  fi
  cp "$IDX" "$IDX$BACKUP_SUFFIX"
  node - "$IDX" <<'NODEEOF'
const fs = require('fs');
const p = process.argv[2];
const old = "        lark_client_1.LarkClient.setRuntime(api.runtime);";
const neu = `        // openclaw-lark-9x-compat: 2026.9 renamed runtime.config.loadConfig() -> runtime.config.current()
        const __rt = api.runtime;
        try {
            if (__rt && __rt.config && typeof __rt.config.loadConfig !== 'function' && typeof __rt.config.current === 'function') {
                __rt.config.loadConfig = () => __rt.config.current();
            }
        }
        catch { /* host object not extensible; handled at call sites */ }
        lark_client_1.LarkClient.setRuntime(__rt);`;
const s = fs.readFileSync(p, 'utf8');
if (!s.includes(old)) { console.error('[compat] ERROR: index.js setRuntime call site not found'); process.exit(1); }
fs.writeFileSync(p, s.replace(old, neu));
console.log('[compat] index.js patched (loadConfig -> current alias)');
NODEEOF
  for pair in     "/src/channel/monitor.js|return lark_client_1.LarkClient.runtime.config.loadConfig();|const __c = lark_client_1.LarkClient.runtime.config; return (typeof __c.loadConfig === 'function' ? __c.loadConfig() : __c.current());"     "/src/core/lark-client.js|const live = LarkClient.runtime.config.loadConfig();|const __c = LarkClient.runtime.config; const live = (typeof __c.loadConfig === 'function' ? __c.loadConfig() : __c.current());"; do
    F="$LARK${pair%%|*}"; rest="${pair#*|}"; OLD="${rest%%|*}"; NEW="${rest#*|}"
    if grep -qF "$OLD" "$F" 2>/dev/null; then
      cp "$F" "$F$BACKUP_SUFFIX"
      OLD="$OLD" NEW="$NEW" node - "$F" <<'NODEEOF'
const fs = require('fs');
const p = process.argv[2];
const s = fs.readFileSync(p, 'utf8');
if (!s.includes(process.env.OLD)) { console.error('[compat] ERROR: pattern not found in ' + p); process.exit(1); }
fs.writeFileSync(p, s.replace(process.env.OLD, process.env.NEW));
console.log('[compat] patched call site: ' + p);
NODEEOF
    else
      say "call site already patched: $F"
    fi
  done
done

[[ "$FOUND" == 1 ]] || warn "no installed @larksuite/openclaw-lark found under ~/.openclaw/npm/projects — skipped step 3 (openclaw-side shim is already in place)"

say "done. Restart the gateway to apply:  openclaw gateway restart"
say "verify with:                        openclaw plugins doctor"
