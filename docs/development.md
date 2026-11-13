# Development

The research source and evidence remain in `C:\Projects\Squeezify`; this tree
contains production-facing source for Squeezebox Radio (`baby`) and Touch (`fab4`).
The Radio uses ARM926EJ-S (ARMv5TEJ); the Touch uses ARM1136 (ARMv6TEJ).
Both use the shared `armv5te-unknown-linux-musleabi` static soft-float runtime.
The ARM926EJ-S instruction baseline supports both CPUs. Linux 2.6 compatibility
wrappers are retained for stock firmware; no hard-float libraries are required.

From PowerShell, with WSL Ubuntu-24.04, Rust and arm-linux-gnueabi-gcc installed:

```powershell
./build/build-native.ps1 -Hardware fab4
./build/package.ps1
```

`-Hardware baby`, `-Hardware fab4`, and `-Hardware all` (default) build the same
compatible runtime. The checkout path is resolved automatically. Native builds
write `build/out/native-targets.json`; staging checks it before packaging.
Host helper binaries are built for local validation and excluded from the ZIP.
The package advertises both targets and can be installed on either model.

Run regression checks with `python -m pytest tests`.
