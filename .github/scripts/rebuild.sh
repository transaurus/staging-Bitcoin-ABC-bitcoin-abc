#!/usr/bin/env bash
set -euo pipefail

# Rebuild script for Bitcoin-ABC/bitcoin-abc (web/chronik.e.cash)
#
# This is a monorepo: docusaurus-plugin-typedoc references ../../modules/chronik-client/
# which is outside the docusaurus directory. The staging repo only contains the
# docusaurus files (originally from web/chronik.e.cash), so the modules/ directory
# is not present. We clone the source repo into a temp workspace, copy translated
# content in, install deps, build there, and copy the output back.

ORIG_DIR="$(pwd)"
TEMP_REPO="/tmp/bitcoin-abc-rebuild-$$"

# --- Node version ---
# web/chronik.e.cash requires Node >=22.0
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
    exit 1
fi
echo "[INFO] Using $(node --version)"

# --- Package manager: pnpm 10 ---
if ! command -v pnpm &>/dev/null; then
    npm install -g pnpm@10
fi
echo "[INFO] Using pnpm $(pnpm --version)"

# --- Clone source repo for monorepo workspace deps ---
echo "[INFO] Cloning source repo for workspace context..."
git clone --depth 1 --branch master https://github.com/Bitcoin-ABC/bitcoin-abc "$TEMP_REPO"

# --- Copy translated i18n content from staging into the docusaurus directory ---
if [ -d "$ORIG_DIR/i18n" ]; then
    echo "[INFO] Copying translated i18n content..."
    cp -r "$ORIG_DIR/i18n" "$TEMP_REPO/web/chronik.e.cash/i18n"
fi

# --- Install dependencies from repo root ---
cd "$TEMP_REPO"
pnpm install --frozen-lockfile

# --- Fix typedoc version conflict ---
# Same fix as prepare.sh: pnpm hoists typedoc@0.22.x over 0.28.x
TYPEDOC_28=$(ls "node_modules/.pnpm/" | grep '^typedoc@0\.28' | head -1)
PNPM_HOISTED="node_modules/.pnpm/node_modules"
if [ -n "$TYPEDOC_28" ] && [ -d "$PNPM_HOISTED" ]; then
    rm -rf "$PNPM_HOISTED/typedoc"
    ln -sf "../$TYPEDOC_28/node_modules/typedoc" "$PNPM_HOISTED/typedoc"
    echo "[INFO] Fixed hoisted typedoc symlink: using $TYPEDOC_28"
fi

# --- Pre-build: build ecashaddrjs ---
(cd modules/ecashaddrjs && pnpm build)
echo "[INFO] ecashaddrjs built successfully"

# --- Create .abclatestversion stub ---
echo -n "0.0.0" > web/chronik.e.cash/.abclatestversion

# --- Build from docusaurus root ---
cd "$TEMP_REPO/web/chronik.e.cash"
pnpm build

# --- Copy build output back to staging dir ---
cp -r build "$ORIG_DIR/build"

# --- Cleanup ---
rm -rf "$TEMP_REPO"

echo "[DONE] Build complete."
