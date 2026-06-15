#!/usr/bin/env bash
# Build a Jet Console single-OS binary with Burrito.
#
# Burrito requires an EXACT Zig (0.15.2); the system Zig (e.g. Homebrew's) is usually newer, so we
# pin a local copy. Install it ONCE (macOS arm64 shown; Linux x86_64: zig-x86_64-linux-0.15.2.tar.xz):
#   mkdir -p ~/.local/zig
#   curl -sL https://ziglang.org/download/0.15.2/zig-aarch64-macos-0.15.2.tar.xz | tar -xJ -C ~/.local/zig
#   mv ~/.local/zig/zig-*-0.15.2 ~/.local/zig/0.15.2
#
# Prereq: the Jet stdlib must be compiled (cd .. && for f in src/*.jet; do ./jet "$f"; done) and
# `version:` bumped in mix.exs for a new release.
#
# Usage:  ./build_binary.sh [macos|linux|windows]   (default: macos)
# Output: burrito_out/jc_<target>
set -euo pipefail

TARGET="${1:-macos}"
HERE="$(cd "$(dirname "$0")" && pwd)"             # console/
JET_ROOT="${JET_ROOT:-$(cd "$HERE/.." && pwd)}"   # the jet repo
ZIG="${ZIG_0_15_2:-$HOME/.local/zig/0.15.2}"

[ -x "$ZIG/zig" ] || { echo "Zig 0.15.2 not found at $ZIG — see the header to install it."; exit 1; }
export PATH="$ZIG:$PATH"
echo "zig: $(zig version)  (Burrito needs exactly 0.15.2)"

cd "$HERE"

# 1. Refresh the bundled Jet runtime (escript + stdlib beams + gleam/gun deps + agents).
echo "==> bundling priv/jet from $JET_ROOT"
mkdir -p priv/jet/src priv/jet/build priv/jet/console
cp "$JET_ROOT/jet" priv/jet/jet
cp "$JET_ROOT"/src/*.beam priv/jet/src/
rm -rf priv/jet/build/erlang-shipment && cp -R "$JET_ROOT/build/erlang-shipment" priv/jet/build/erlang-shipment
rm -rf priv/jet/console/agents && cp -R "$JET_ROOT/console/agents" priv/jet/console/agents

# 2. Avoid the two stale-payload gotchas: a fresh release dir + a fresh Burrito payload cache for
#    this app (Burrito keys its cache by app+ERTS+version, so a same-version rebuild reuses stale).
echo "==> clearing stale release + burrito cache"
rm -rf _build/prod/rel/jc
rm -rf "$HOME/Library/Application Support/.burrito"/jc_* 2>/dev/null || true

# 3. Build (compile BEFORE assets — Phoenix 1.8 emits colocated CSS during compile).
echo "==> compiling + wrapping the $TARGET binary"
MIX_ENV=prod mix compile
MIX_ENV=prod mix assets.deploy
BURRITO_TARGET="$TARGET" MIX_ENV=prod mix release --overwrite

echo "==> done:"
ls -la "burrito_out/jc_$TARGET"* 2>/dev/null || echo "  (expected burrito_out/jc_$TARGET — check the log above)"
