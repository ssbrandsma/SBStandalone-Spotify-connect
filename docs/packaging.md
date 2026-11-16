# Packaging

`build/package.ps1` reads `VERSION`, creates the matching
`dist/SpotifyConnect-<version>.zip`, and generates Applet Installer repository
metadata in `dist/extensions.xml`. The XML contains the release URL and SHA-1
of the ZIP; `dist/extensions.xml.sha1` contains the SHA-1 of the XML itself.
The archive contains only the applet Lua, strings, artwork, event hook, and
four ARM runtime executables. Credentials, research evidence, test binaries,
PC artifacts, and source checkouts are excluded.

Run `./build/build-native.ps1 -Hardware fab4` (or `baby` / `all`) before
`./build/package.ps1`. Staging validates the native hardware manifest.

The repository advertises the same package for the Squeezebox Radio (`baby`)
and Squeezebox Touch (`fab4`) targets. The applet detects the firmware machine
identifier and uses the matching default Spotify device name. Custom names
are preserved.

## RG35XX H (`rg35xxh`)

The RG35XX H needs its own AArch64 package; the ARMv5 baby/fab4 binaries
cannot run on it. Build and package it separately (no WSL needed — the
toolchain script is rootless):

```bash
./build/build-native-rg35xxh.sh
```

then from PowerShell:

```powershell
./build/package.ps1 -Hardware rg35xxh
```

This produces `dist/SpotifyConnect-<version>-rg35xxh.zip` and regenerates
`dist/extensions.xml` from every versioned ZIP present in `dist/`: with both
artifacts built, the XML carries `baby` + `fab4` (shared ZIP) and `rg35xxh`
entries. Publish all three files (`extensions.xml` + both ZIPs) in the
server's `sbspotifyconnect` web directory.

On the device, SqueezeboxGo queries `target:rg35xxh` and installs the
AArch64 package through the standard Jive Applet Installer. The Lua payload
is identical across targets; only the four native binaries differ. See
`BUILD-RG35XXH.md` for the native build and `INSTALL-RG35XXH.md` for the
device-side flow.

By default, package URLs point to
`http://49.12.198.91/sbspotifyconnect`. Publish both `extensions.xml` and the
versioned ZIP in the server's `sbspotifyconnect` web directory so the stock
Radio can download them without TLS. Pass `-BaseUrl` when publishing through a
different static web directory.

Add `http://49.12.198.91/sbspotifyconnect/extensions.xml` to LMS under **Additional
Repositories**. The two public files for version 0.7.0 are:

```text
http://49.12.198.91/sbspotifyconnect/extensions.xml
http://49.12.198.91/sbspotifyconnect/SpotifyConnect-0.7.0.zip
```

Applet-owned executables install under
`/usr/share/jive/applets/SpotifyConnect/`. The applet applies `chmod 755`
idempotently to its own files; it never writes `/usr/bin`, `/usr/local/bin`, or
`/etc/init.d`.
