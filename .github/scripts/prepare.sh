#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/Bitcoin-ABC/bitcoin-abc"
BRANCH="master"
REPO_DIR="source-repo"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Clone (skip if already exists) ---
if [ ! -d "$REPO_DIR" ]; then
    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$REPO_DIR"
fi

cd "$REPO_DIR"

# --- Node version ---
# web/chronik.e.cash requires Node >=22.0 (engines field in package.json)
# Try to install/activate Node 22 via n or nvm
if command -v n &>/dev/null; then
    export N_PREFIX="${N_PREFIX:-/usr/local}"
    sudo n 22 2>/dev/null || n 22 2>/dev/null || true
    export PATH="/usr/local/bin:$PATH"
elif [ -s "$HOME/.nvm/nvm.sh" ]; then
    # shellcheck source=/dev/null
    source "$HOME/.nvm/nvm.sh"
    nvm install 22 2>/dev/null || true
    nvm use 22 2>/dev/null || true
fi

NODE_MAJOR=$(node --version | sed 's/v//' | cut -d. -f1)
if [ "$NODE_MAJOR" -lt 22 ]; then
    echo "[ERROR] Node $NODE_MAJOR detected, but web/chronik.e.cash requires Node >=22."
    echo "        Install Node 22+ and re-run."
    exit 1
fi
echo "[INFO] Using $(node --version)"

# --- Package manager: pnpm 10 ---
# The monorepo root declares packageManager: pnpm@10.24.0
# pnpm-lock.yaml lives at the repo root, not in the subdirectory
if ! command -v pnpm &>/dev/null; then
    npm install -g pnpm@10
fi
echo "[INFO] Using pnpm $(pnpm --version)"

# --- Install dependencies from repo root ---
# This installs all workspace packages including web/chronik.e.cash deps
# and makes docusaurus available in web/chronik.e.cash/node_modules/.bin/
pnpm install --frozen-lockfile

# --- Fix typedoc version conflict ---
# The monorepo has two typedoc versions:
#   - typedoc@0.22.x (from modules/chronik-client devDeps)
#   - typedoc@0.28.x (from web/chronik.e.cash devDeps, needed by docusaurus-plugin-typedoc)
# pnpm hoists 0.22.x to node_modules/.pnpm/node_modules/typedoc, which the plugin
# incorrectly picks up at runtime. Fix: update the hoisted symlink to 0.28.x.
TYPEDOC_28=$(ls "node_modules/.pnpm/" | grep '^typedoc@0\.28' | head -1)
PNPM_HOISTED="node_modules/.pnpm/node_modules"
if [ -n "$TYPEDOC_28" ] && [ -d "$PNPM_HOISTED" ]; then
    rm -rf "$PNPM_HOISTED/typedoc"
    ln -sf "../$TYPEDOC_28/node_modules/typedoc" "$PNPM_HOISTED/typedoc"
    echo "[INFO] Fixed hoisted typedoc symlink: using $TYPEDOC_28"
fi

# --- Pre-build: build ecashaddrjs workspace package ---
# docusaurus-plugin-typedoc compiles modules/chronik-client which imports ecashaddrjs.
# ecashaddrjs declares types at dist/cashaddr.d.ts but dist/ is not committed.
# We must build ecashaddrjs before write-translations or build will fail.
(cd modules/ecashaddrjs && pnpm build)
echo "[INFO] ecashaddrjs built successfully"

# --- Apply fixes.json if present ---
FIXES_JSON="$SCRIPT_DIR/fixes.json"
if [ -f "$FIXES_JSON" ]; then
    echo "[INFO] Applying content fixes..."
    node -e "
    const fs = require('fs');
    const path = require('path');
    const fixes = JSON.parse(fs.readFileSync('$FIXES_JSON', 'utf8'));
    for (const [file, ops] of Object.entries(fixes.fixes || {})) {
        if (!fs.existsSync(file)) { console.log('  skip (not found):', file); continue; }
        let content = fs.readFileSync(file, 'utf8');
        for (const op of ops) {
            if (op.type === 'replace' && content.includes(op.find)) {
                content = content.split(op.find).join(op.replace || '');
                console.log('  fixed:', file, '-', op.comment || '');
            }
        }
        fs.writeFileSync(file, content);
    }
    for (const [file, cfg] of Object.entries(fixes.newFiles || {})) {
        const c = typeof cfg === 'string' ? cfg : cfg.content;
        fs.mkdirSync(path.dirname(file), {recursive: true});
        fs.writeFileSync(file, c);
        console.log('  created:', file);
    }
    "
fi

echo "[DONE] Repository is ready for docusaurus commands."
