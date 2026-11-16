# INSTALL-RG35XXH.md — Installing Spotify Connect on the RG35XX H

## Requirements

- Anbernic RG35XX H with SqueezeboxGo installed (StockOS App Center).
- Wi-Fi connectivity.
- A Spotify Premium account (Spotify requires Premium for Spotify Connect;
  this is Spotify's policy, not an app limitation).
- The release files: `SpotifyConnect-<version>-rg35xxh.zip`,
  `extensions.xml`, `extensions.xml.sha1`.

Do NOT install the baby/fab4 ZIP on this device: those contain ARMv5
binaries that cannot execute on AArch64.

## Method A — Native Applet Installer (recommended)

SqueezeboxGo's installer asks `target:rg35xxh` (see
`rg35xxh-identity.patch` in the SqueezeboxGo project). It queries
SqueezeCenters, so the repository must be hosted by an LMS:

1. Add the repository URL to LMS under **Additional Repositories**:
   `http://<repo-host>/sbspotifyconnect/extensions.xml`.
   (Once the Standalone Base device-LMS ships, this is the on-device
   server and no external machine is involved at all. Until then, any
   reachable LMS — including a temporary one — works purely as install
   transport; it is never used for music playback.)
2. On the device: Settings → Advanced → Applet Installer → Spotify Connect.
3. Install and restart SqueezeboxGo when prompted.

Verify: the install lands in
`$SQUEEZEPLAY_HOME/userpath/applets/SpotifyConnect` (see SqueezeboxGo
`launch.sh` for the concrete path on your install).

## Method B — Manual install (no LMS of any kind)

1. `ssh rg35xxh`.
2. Copy `SpotifyConnect-<version>-rg35xxh.zip` to the device and unzip it
   into `$SQUEEZEPLAY_HOME/userpath/applets/SpotifyConnect` (flat layout:
   `librespot` etc. at that directory's root, no enclosing folder).
3. Restart SqueezeboxGo.

Executable bits do not need to survive the transfer: the applet applies
`chmod 755` to its own files at startup and stages the runtime into RAM
with correct permissions.

## First run

1. Open the Spotify Connect menu in Jive.
2. Choose **Connect account** and approve via the QR code / device link.
3. In the Spotify app (phone/tablet/computer), select **SqueezeboxGo**
   (plus a `-XX` MAC suffix on first pairing) as the output device.
4. Press play. Audio routes through the stock SqueezePlay engine to the
   speakers/headphones; Jive volume, Standalone Radio handover, and Now
   Playing behave as on Radio/Touch.

Logs for the current session live in RAM at
`/dev/spotify-connect-runtime/engine.log` (cleared on every stop).
Credentials persist in `$SQUEEZEPLAY_HOME/userpath/SpotifyConnect/`.

## Troubleshooting

- Installer shows no Spotify entry: the LMS hosting the repo has no
  `rg35xxh` entry (check `extensions.xml`), or the device fell back to
  `baby` (never install that result on this hardware).
- `Required runtime files are unavailable`: the applet directory lacks
  the native binaries (reinstall the `-rg35xxh.zip`, not the shared ZIP).
- Device never appears in Spotify: check Wi-Fi, Premium status, and
  `status.json` in the runtime dir (`pairing` → approve the link).
