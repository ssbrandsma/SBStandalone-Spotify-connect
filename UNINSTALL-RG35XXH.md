# UNINSTALL-RG35XXH.md — Removing Spotify Connect from the RG35XX H

## Clean removal

1. In the Spotify Connect menu: Operating Mode → **Disabled**
   (stops the receiver and prevents restart), or Stop in Manual mode.
2. Remove the applet via the Applet Installer, or manually:
   `rm -rf $SQUEEZEPLAY_HOME/userpath/applets/SpotifyConnect`.
3. Exit and relaunch SqueezeboxGo (or reboot) so Jive drops the menu entry.

## Credential cleanup (explicit)

Spotify credentials are deliberately kept outside the applet directory so
upgrades preserve them; removal does NOT delete them. To erase them:

```bash
rm -rf $SQUEEZEPLAY_HOME/userpath/SpotifyConnect
```

or use the in-app **Disconnect account** before removing (deletes
`credentials.json` + cached volume, keeps the directory).

## Verification

After removal, all of these must hold:

- `pgrep -af spotify-connect-runtime` prints nothing (no orphans).
- `/dev/spotify-connect-runtime` does not exist (RAM staging cleaned).
- No `SpotifyConnect` entry in `$SQUEEZEPLAY_HOME/userpath/applets/`.
- StockOS gaming frontend, Wi-Fi, and audio behave as before.

Removal never touches games, saves, SqueezeboxGo itself, or StockOS
system configuration.
