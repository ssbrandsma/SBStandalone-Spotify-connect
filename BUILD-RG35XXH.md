# BUILD-RG35XXH.md — AArch64 receiver build for the RG35XX H

Target runtime: StockOS Ubuntu 22.04 ARM64, glibc 2.35, Linux 4.9.170,
Cortex-A53. Baby/fab4 builds are unchanged; see `docs/development.md`.

## Prerequisites

- Debian/Ubuntu host with apt metadata (or an `ubuntu:24.04` container).
- Rust 1.85+ with the `aarch64-unknown-linux-gnu` target
  (`rustup target add aarch64-unknown-linux-gnu`). Validated with 1.98.1.
- `curl`, `dpkg-deb`, `readelf`, `objdump`, `file`, `nm`, `sha256sum`.
- Optional: `qemu-aarch64` for userspace smoke tests, python3 + `pytest`/`lupa`
  for the host suite (`uv venv && uv pip install pytest lupa`).

No root access is required at any step.

## Build

```bash
./build/build-native-rg35xxh.sh
```

This assembles a rootless cross toolchain + Jammy sysroot (first run only,
cached under `build/out/`), compiles the same Rust sources and librespot
feature set as baby/fab4 for `aarch64-unknown-linux-gnu`, runs the ABI
gates, and writes manifests. Force a toolchain rebuild with
`./build/rg35xxh-toolchain.sh --rebuild`.

Outputs (all git-ignored):

| Path | Contents |
|---|---|
| `build/out/rg35xxh/` | `librespot`, `ogg-http-bridge`, `spotify-supervisor`, `spotify-metadata` |
| `build/out/native-targets-rg35xxh.json` | `{"hardware":["rg35xxh"], ...}` staging manifest |
| `build/out/rg35xxh-build.json` | rustc/cargo versions, features, per-binary SHA256 + size |
| `build/out/rg35xxh-toolchain.json` | cross-deb versions + hashes, sysroot suite |
| `build/out/rg35xxh-{toolchain,sysroot,wrap}/` | cached toolchain, Jammy libc, compiler wrappers |

## Pins

- Rust: `--locked` against committed `native/librespot/Cargo.lock`
  (tokio 1.48.0, ring 0.17.14, …); `RUSTFLAGS -C target-cpu=cortex-a53`.
- Librespot features (identical to baby/fab4):
  `rustls-tls-webpki-roots,with-libmdns,passthrough-decoder,streaming-only`.
- glibc ceiling: Jammy arm64 libc debs, SHA256-pinned in
  `build/rg35xxh-toolchain.sh` (libc6/libc6-dev 2.35-0ubuntu3.18,
  linux-libc-dev 5.15.0-203.213, libgcc-s1 12.3.0-1ubuntu1~22.04.3).
- Host cross debs (noble, gcc 13 + binutils 2.42) are resolved via apt at
  build time and recorded with versions + hashes in
  `rg35xxh-toolchain.json`. Only the Jammy sysroot sets the glibc floor.

Deliberately absent vs baby/fab4: musl/static, `-no-pie`,
`linux26-compat` shims, `--wrap` link flags (all Linux-2.6/ARMv5-only).

## Gates (`build/check-rg35xxh-abi.sh`)

Every binary must satisfy: ELF64 AArch64; interpreter
`/lib/ld-linux-aarch64.so.1`; NEEDED ⊆
{`libc.so.6`, `libm.so.6`, `libgcc_s.so.1`, `ld-linux-aarch64.so.1`}; max
`GLIBC ≤ 2.35`; no `__isoc23`; no SysV IPC (`shmget`/`semget`/… — the
vendor kernel returns ENOSYS). Measured maxima: GLIBC_2.34, GCC_4.2.0.

Kernel audit: no `io-uring` in `Cargo.lock` (tokio is epoll-only);
`statx`/`getrandom` are weak imports with libc/ENOSYS fallbacks.

## Reproducibility

`SOURCE_DATE_EPOCH` defaults to the git HEAD commit time (override by
exporting it). Two clean builds with the same epoch produce byte-identical
binaries (verified: all four SHA256 match across a clean rebuild).
The librespot `--version` string embeds the applet short hash + build ID.

## QEMU verification

```bash
SR=build/out/rg35xxh-sysroot BIN=build/out/rg35xxh
qemu-aarch64 -L $SR $BIN/librespot --version
qemu-aarch64 -L $SR $BIN/librespot --disable-discovery --name test  # exit 1, no creds
python3 tests/native_bridge_drain.py <qemu bridge wrapper>          # PASS
```

Covered by `tests/test_build_rg35xxh.py` (skips with NOT RUN when the
sysroot, qemu, or binaries are absent).

## Troubleshooting

- `aarch64-unknown-linux-gnu not installed`: `rustup target add
  aarch64-unknown-linux-gnu`.
- `need apt-get`: build inside `ubuntu:24.04` (`docker run -v $PWD:/w`).
- SHA mismatch on a Jammy deb: re-run (transient mirror issue) or check
  `ports.ubuntu.com` availability; pins are immutable for this suite.
- `qemu: libgcc_s.so.1: No such file`: rebuild the toolchain
  (`--rebuild`) so the sysroot picks up the libgcc-s1 pin.
