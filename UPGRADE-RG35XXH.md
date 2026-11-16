# UPGRADE-RG35XXH.md — Upgrading Spotify Connect on the RG35XX H

## Normal upgrade

Use the same method as installation ([INSTALL-RG35XXH.md](INSTALL-RG35XXH.md)):
install the newer `-rg35xxh.zip` over the old one and restart SqueezeboxGo.

What happens:

- Credentials (`credentials.json`) and settings live outside the applet
  directory (`$SQUEEZEPLAY_HOME/userpath/SpotifyConnect`) and survive.
- Native binaries refresh automatically: every start re-stages the
  install dir into the RAM runtime dir, and boot reaps any stale
  receiver from a previous session.
- New settings keys migrate via `upgradeSettings` (missing `serviceMode`
  derives from the legacy `enabled` flag).

## Failed upgrade recovery

All volatile state (FIFO, pidfiles, status, metadata, log) is RAM-backed
and starts fresh on every boot. If an upgrade misbehaves:

1. Stop the service (menu → Operating Mode → Manual → Stop), or exit
   SqueezeboxGo (the receiver stops with Jive).
2. Reinstall the known-good ZIP.
3. Restart. If pairing state looks wedged, use **Disconnect account**
   (removes credentials only) and pair again.

## Rollback

Reinstall the previous `-rg35xxh.zip`. Downgrades ignore unknown newer
settings keys; credentials remain valid. No other SqueezeboxGo data,
games, or StockOS configuration are touched by install/upgrade/remove.

## Version notes

- The Lua payload is shared across baby/fab4/rg35xxh; only the four
  native binaries differ per target.
- `extensions.xml` always describes every versioned ZIP present in the
  publish directory; publishing a new version = uploading the new ZIP(s)
  plus the regenerated `extensions.xml` + `.sha1`.
