#!/usr/bin/env bash
# rg35xxh-toolchain.sh — rootless AArch64 cross toolchain + Jammy sysroot.
#
# Assembles, without root, everything needed to link AArch64 binaries for the
# RG35XX H StockOS runtime (Ubuntu 22.04, glibc 2.35):
#   1. Noble cross-toolchain debs (gcc 13, binutils) via apt download.
#   2. Pinned Jammy arm64 libc debs (glibc 2.35) via ports.ubuntu.com + SHA256.
#   3. Compiler wrappers forcing --sysroot/-B/-isystem at the Jammy tree.
#
# Layout (all under build/out, git-ignored):
#   rg35xxh-toolchain/  extracted cross debs (relocated /usr tree)
#   rg35xxh-sysroot/    extracted Jammy arm64 libc (glibc 2.35 target)
#   rg35xxh-wrap/       aarch64-linux-gnu-{gcc,ar,ld} wrappers
#
# Usage: build/rg35xxh-toolchain.sh [--rebuild] [--check-only]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/build/out"
TC="$OUT/rg35xxh-toolchain"
SR="$OUT/rg35xxh-sysroot"
WRAP="$OUT/rg35xxh-wrap"
REBUILD=0
CHECK_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --rebuild) REBUILD=1 ;;
        --check-only) CHECK_ONLY=1 ;;
        *) echo "Usage: $0 [--rebuild] [--check-only]" >&2; exit 2 ;;
    esac
done

# Pinned Jammy arm64 debs (jammy-updates 2026-11-16; glibc 2.35).
# Columns: pool-path SHA256. Mirrors the reference SqueezeboxGo sysroot pins.
JAMMY_DEBS='
pool/main/g/glibc/libc6_2.35-0ubuntu3.18_arm64.deb 552390697756c005f8eff39b03392b2d8c6e148420c3e237d779fb44e54b5e72
pool/main/g/glibc/libc6-dev_2.35-0ubuntu3.18_arm64.deb debdc254b6dd8a95d91411475683b589e2094bfa7c5038b4fc5408120d3f3eab
pool/main/l/linux/linux-libc-dev_5.15.0-203.213_arm64.deb 4bd45d3028fd1c443d9cfaa61c14682ddcab9ab8a901b6a37b90253463cedfeb
pool/main/g/gcc-12/libgcc-s1_12.3.0-1ubuntu1~22.04.3_arm64.deb 46626e1af6b159061e055f843654ee1f0f1e65fa280331ed47ee76ba1b1f6045
'
PORTS_URL="http://ports.ubuntu.com/ubuntu-ports"

# Noble cross-toolchain debs (host side; resolved via apt metadata at build
# time and recorded with versions+hashes in rg35xxh-toolchain.json).
TOOLCHAIN_DEBS="binutils-aarch64-linux-gnu gcc-aarch64-linux-gnu gcc-13-aarch64-linux-gnu cpp-aarch64-linux-gnu cpp-13-aarch64-linux-gnu libgcc-13-dev-arm64-cross libc6-arm64-cross libc6-dev-arm64-cross libgcc-s1-arm64-cross libstdc++6-arm64-cross"

if [ "$CHECK_ONLY" -eq 0 ] && { [ "$REBUILD" -eq 1 ] || [ ! -f "$WRAP/.ok" ]; }; then
    command -v apt-get >/dev/null || { echo "ERROR: need apt-get (Debian/Ubuntu host)" >&2; exit 1; }
    for t in curl dpkg-deb sha256sum; do
        command -v "$t" >/dev/null || { echo "ERROR: need $t" >&2; exit 1; }
    done
    rm -rf "$TC" "$SR" "$WRAP"
    mkdir -p "$TC/.debs" "$SR/.debs" "$WRAP"

    echo "== cross toolchain debs =="
    ( cd "$TC/.debs" && apt-get download $TOOLCHAIN_DEBS )
    for deb in "$TC"/.debs/*.deb; do dpkg-deb -x "$deb" "$TC"; done

    echo "== Jammy sysroot debs =="
    echo "$JAMMY_DEBS" | grep -v '^$' | while read -r pool sha; do
        deb="$SR/.debs/$(basename "$pool")"
        echo "fetch: $pool"
        curl -sS --fail --max-time 180 -o "$deb" "$PORTS_URL/$pool"
        have="$(sha256sum "$deb" | cut -d' ' -f1)"
        [ "$have" = "$sha" ] || { echo "ERROR: sha mismatch for $(basename "$pool")" >&2; exit 1; }
        dpkg-deb -x "$deb" "$SR"
    done
    # Absolute symlinks (/lib/...) must resolve INSIDE the sysroot.
    find "$SR" -type l | while IFS= read -r l; do
        t="$(readlink "$l")"
        case "$t" in /*) ln -sfn "$SR$t" "$l" ;; esac
    done
    # GROUP paths in the libc linker script need '=' so ld re-roots them.
    sed -i 's|GROUP ( /lib|GROUP ( =/lib|; s| /usr/lib| =/usr/lib|g; s| ( /lib| ( =/lib|g' \
        "$SR/usr/lib/aarch64-linux-gnu/libc.so"
    [ -f "$SR/usr/lib/aarch64-linux-gnu/crt1.o" ] || { echo "ERROR: crt1.o missing" >&2; exit 1; }

    echo "== wrappers =="
    HOSTLIB="$TC/usr/lib/x86_64-linux-gnu"
    cat > "$WRAP/aarch64-linux-gnu-gcc" <<EOF
#!/bin/sh
export LD_LIBRARY_PATH="$HOSTLIB\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec $TC/usr/bin/aarch64-linux-gnu-gcc --sysroot=$SR -B$SR/usr/lib/aarch64-linux-gnu -isystem $SR/usr/include/aarch64-linux-gnu -isystem $SR/usr/include "\$@"
EOF
    cat > "$WRAP/aarch64-linux-gnu-ar" <<EOF
#!/bin/sh
export LD_LIBRARY_PATH="$HOSTLIB\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec $TC/usr/bin/aarch64-linux-gnu-ar "\$@"
EOF
    cat > "$WRAP/aarch64-linux-gnu-ld" <<EOF
#!/bin/sh
export LD_LIBRARY_PATH="$HOSTLIB\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec $TC/usr/bin/aarch64-linux-gnu-ld --sysroot=$SR "\$@"
EOF
    chmod +x "$WRAP"/aarch64-linux-gnu-*

    {
        echo "{"
        echo "  \"host\": \"$(lsb_release -ds 2>/dev/null || grep PRETTY_NAME /etc/os-release | cut -d= -f2)\","
        echo "  \"toolchainDebs\": {"
        first=1
        for deb in "$TC"/.debs/*.deb; do
            name="$(dpkg-deb -f "$deb" Package)"; ver="$(dpkg-deb -f "$deb" Version)"
            sha="$(sha256sum "$deb" | cut -d' ' -f1)"
            [ "$first" -eq 1 ] || echo ","
            first=0
            printf '    "%s": {"version": "%s", "sha256": "%s"}' "$name" "$ver" "$sha"
        done
        echo ""
        echo "  },"
        echo "  \"sysrootSuite\": \"jammy-updates (glibc 2.35)\""
        echo "}"
    } > "$OUT/rg35xxh-toolchain.json"
    touch "$WRAP/.ok"
    echo "toolchain: $TC"
    echo "sysroot:   $SR"
    echo "wrappers:  $WRAP"
fi

echo "== check: glibc ceiling probe =="
cc="$WRAP/aarch64-linux-gnu-gcc"
[ -x "$cc" ] || { echo "ERROR: $cc missing" >&2; exit 1; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/probe.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
int main(void) {
    char b[64];
    long v = strtol("42", 0, 10);
    if (sscanf("7", "%63s", b) != 1) { return 1; }
    snprintf(b, sizeof b, "%ld", v);
    printf("%s\n", b);
    return 0;
}
EOF
"$cc" -march=armv8-a -o "$tmp/probe" "$tmp/probe.c"
if nm "$tmp/probe" 2>/dev/null | grep -q '__isoc23'; then
    echo "CHECK FAIL: __isoc23 refs present (wrong headers win)" >&2
    exit 1
fi
maxv="$(readelf -V "$tmp/probe" | grep -oE 'GLIBC_[0-9.]+' | sort -uV | tail -1)"
echo "probe max GLIBC: $maxv (want <= GLIBC_2.35)"
case "$maxv" in
    GLIBC_2.3[0-5]) echo "CHECK OK" ;;
    *) echo "CHECK FAIL: too new" >&2; exit 1 ;;
esac
