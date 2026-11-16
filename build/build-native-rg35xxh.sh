#!/usr/bin/env bash
# build-native-rg35xxh.sh — AArch64 native runtime for the RG35XX H.
#
# Same Rust sources and librespot feature set as baby/fab4 (D1), retargeted:
#   aarch64-unknown-linux-gnu, glibc <= 2.35 (Jammy sysroot), Cortex-A53,
#   no musl/static, no linux26-compat shims.
# Outputs (git-ignored, alongside — never clobbering — the baby/fab4 tree):
#   build/out/rg35xxh/                    the 4 native binaries
#   build/out/native-targets-rg35xxh.json target manifest
#   build/out/rg35xxh-build.json          provenance (toolchain, versions, hashes)
set -euo pipefail
if [ -f "$HOME/.cargo/env" ]; then source "$HOME/.cargo/env"; fi
command -v cargo >/dev/null || { echo "ERROR: need cargo (rustup, 1.85+)" >&2; exit 1; }
command -v rustc >/dev/null || { echo "ERROR: need rustc" >&2; exit 1; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/build/out"
BIN="$OUT/rg35xxh"
WRAP="$OUT/rg35xxh-wrap"
TARGET=aarch64-unknown-linux-gnu

bash "$ROOT/build/rg35xxh-toolchain.sh"
rustc --print target-list 2>/dev/null | grep -qx "$TARGET" || { echo "ERROR: rust target $TARGET missing (rustup target add $TARGET)" >&2; exit 1; }
rustup target list --installed 2>/dev/null | grep -qx "$TARGET" || { echo "ERROR: rust target $TARGET not installed" >&2; exit 1; }

mkdir -p "$BIN"
export CARGO_TARGET_DIR="$OUT/rg35xxh-cargo-target"
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER="$WRAP/aarch64-linux-gnu-gcc"
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_RUSTFLAGS="-C target-cpu=cortex-a53"
export CC_aarch64_unknown_linux_gnu="$WRAP/aarch64-linux-gnu-gcc"
export AR_aarch64_unknown_linux_gnu="$WRAP/aarch64-linux-gnu-ar"
export CARGO_PROFILE_RELEASE_OPT_LEVEL=z
export CARGO_PROFILE_RELEASE_LTO=thin
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1
export CARGO_PROFILE_RELEASE_STRIP=symbols
if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
    SOURCE_DATE_EPOCH="$(git -C "$ROOT" log -1 --format=%ct 2>/dev/null || date +%s)"
    export SOURCE_DATE_EPOCH
fi
echo "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH"

echo "== helpers (bridge/supervisor/metadata) =="
for helper in bridge/bridge.rs:ogg-http-bridge supervisor/main.rs:spotify-supervisor metadata/main.rs:spotify-metadata; do
    src="${helper%%:*}"; exe="${helper##*:}"
    rustc --edition 2021 --target "$TARGET" -C linker="$WRAP/aarch64-linux-gnu-gcc" \
        -C target-cpu=cortex-a53 -C opt-level=z -C strip=symbols \
        "$ROOT/native/$src" -o "$BIN/$exe"
done

echo "== librespot (locked, passthrough+streaming-only) =="
cd "$ROOT/native/librespot"
cargo rustc --locked --release --bin librespot --target "$TARGET" \
    --no-default-features --features rustls-tls-webpki-roots,with-libmdns,passthrough-decoder,streaming-only
cp "$CARGO_TARGET_DIR/$TARGET/release/librespot" "$BIN/librespot"
cd "$ROOT"

echo "== ABI gates =="
bash "$ROOT/build/check-rg35xxh-abi.sh" "$BIN/librespot" "$BIN/ogg-http-bridge" \
    "$BIN/spotify-supervisor" "$BIN/spotify-metadata"

echo "== manifests =="
printf '{"hardware":["rg35xxh"],"target":"%s","cpu":"cortex-a53","libc":"gnu-2.35"}\n' "$TARGET" \
    > "$OUT/native-targets-rg35xxh.json"
{
    echo "{"
    echo "  \"target\": \"$TARGET\","
    echo "  \"cpu\": \"cortex-a53\","
    echo "  \"rustc\": \"$(rustc --version)\","
    echo "  \"cargo\": \"$(cargo --version)\","
    echo "  \"librespotFeatures\": \"rustls-tls-webpki-roots,with-libmdns,passthrough-decoder,streaming-only\","
    echo "  \"sourceDateEpoch\": \"${SOURCE_DATE_EPOCH:-unset}\","
    echo "  \"binaries\": {"
    first=1
    for exe in librespot ogg-http-bridge spotify-supervisor spotify-metadata; do
        sha="$(sha256sum "$BIN/$exe" | cut -d' ' -f1)"
        size="$(stat -c%s "$BIN/$exe")"
        [ "$first" -eq 1 ] || echo ","
        first=0
        printf '    "%s": {"sha256": "%s", "bytes": %s}' "$exe" "$sha" "$size"
    done
    echo ""
    echo "  }"
    echo "}"
} > "$OUT/rg35xxh-build.json"
echo "binaries: $BIN"
cat "$OUT/native-targets-rg35xxh.json"
