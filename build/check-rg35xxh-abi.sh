#!/usr/bin/env bash
# check-rg35xxh-abi.sh — ABI + kernel gates for rg35xxh native binaries.
#
# Usage: build/check-rg35xxh-abi.sh <binary>...
# Fails when any binary violates the StockOS runtime contract:
#   ELF64 AArch64, dynamic interpreter ld-linux-aarch64, NEEDED allowlist,
#   max GLIBC <= 2.35, no __isoc23, no SysV IPC (kernel returns ENOSYS).
set -euo pipefail
[ $# -ge 1 ] || { echo "Usage: $0 <binary>..." >&2; exit 2; }
fail=0
for bin in "$@"; do
    echo "== $bin"
    kind="$(file -b "$bin")"
    echo "   file: $kind"
    case "$kind" in
        *"ELF 64-bit LSB"*"ARM aarch64"*) ;;
        *) echo "   FAIL: not ELF64 AArch64" >&2; fail=1; continue ;;
    esac
    interp="$(readelf -l "$bin" | grep -o '/lib/ld-linux[^] ]*' | head -1)"
    echo "   interp: $interp"
    [ "$interp" = "/lib/ld-linux-aarch64.so.1" ] || { echo "   FAIL: bad interp" >&2; fail=1; }
    echo "   NEEDED:"
    readelf -d "$bin" | grep NEEDED | sed 's/^/     /'
    bad="$(readelf -d "$bin" | grep NEEDED | grep -o '\[[^]]*\]' | tr -d '[]' \
        | grep -v -x -e 'libc.so.6' -e 'libm.so.6' -e 'libgcc_s.so.1' -e 'ld-linux-aarch64.so.1' || true)"
    if [ -n "$bad" ]; then echo "   FAIL: unexpected NEEDED: $bad" >&2; fail=1; fi
    maxv="$(readelf -V "$bin" | grep -oE 'GLIBC_[0-9.]+' | sort -uV | tail -1)"
    echo "   max GLIBC: ${maxv:-none}"
    case "${maxv:-none}" in
        none|GLIBC_2.3[0-5]) ;;
        *) echo "   FAIL: needs $maxv (StockOS has 2.35)" >&2; fail=1 ;;
    esac
    if objdump -T "$bin" 2>/dev/null | grep -Eq ' shmget| semget| shmat| shmctl| shmdt| semop| semctl| msgget| __isoc23'; then
        echo "   FAIL: forbidden undefined symbol:" >&2
        objdump -T "$bin" | grep -E ' shmget| semget| shmat| shmctl| shmdt| semop| semctl| msgget| __isoc23' | sed 's/^/     /' >&2
        fail=1
    else
        echo "   no SysV IPC / __isoc23 refs"
    fi
done
[ "$fail" -eq 0 ] || { echo "ABI GATES FAILED" >&2; exit 1; }
echo "ABI GATES OK"
