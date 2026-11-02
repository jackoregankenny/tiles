# Tiles

A tiling window manager for macOS that lives in the menu bar. Plain Swift + AppKit, ~210 KB,
no dependencies. It uses only the public Accessibility API, so it needs no SIP changes.

Tiles arranges the windows on each display of the current Space. Layouts: master & stack,
columns, rows, grid, monocle. **Auto-Tile** re-tiles whenever windows open, close, minimise or the
Space changes (it watches the on-screen window list, which needs no per-app observers).
**Restore Original Positions** puts everything back where it was.

## Install

Download `Tiles.zip` from the [latest release](https://github.com/jackoregankenny/tiles/releases/latest),
unzip, move it to `/Applications`, and clear the download flag once (the build is not notarized):

```sh
xattr -dr com.apple.quarantine /Applications/Tiles.app
```

Grant Accessibility from its menu. Tiles keeps itself up to date from GitHub Releases: it checks
every few hours and installs only a download whose SHA-256 matches the release and whose bundle id
and version are right. Turn that off with `"autoUpdate": false` in the config. macOS asks for
Accessibility again after an update, because the builds are ad-hoc signed.

## Hotkeys

All ⌃⌥⌘, so they leave ⌃⌥ free for snapping tools like Rectangle or Hop:

| Keys | Action |
|---|---|
| ⌃⌥⌘T / ⌃⌥⌘⇧T | tile now / toggle auto-tile |
| ⌃⌥⌘ H J K L | focus left, down, up, right |
| ⌃⌥⌘⇧ H J K L | swap with the window in that direction |
| ⌃⌥⌘M | promote focused window to master |
| ⌃⌥⌘= / ⌃⌥⌘- | grow / shrink master |
| ⌃⌥⌘F | float or tile the frontmost app |
| ⌃⌥⌘1–5 | master, columns, rows, grid, monocle |
| ⌃⌥⌘R | restore original positions |

## Config: `~/.config/tiles/config.json`

The menu's **Edit Config…** writes one with the defaults. Your hotkeys are added on top of the
defaults, and `"none"` turns one off:

```json
{ "layout": "master", "gap": 10, "ratio": 0.55, "auto": false, "float": ["FaceTime"],
  "hotkeys": { "ctrl+opt+cmd+space": "tile", "ctrl+opt+cmd+r": "none" } }
```

## Driving it from anything

Actions are a small language shared by hotkeys, the menu and URLs, so launchers and scripts can
drive Tiles: `open tiles://layout/grid`, `tiles://auto/toggle`, `tiles://focus/left`,
`tiles://swap/right`, `tiles://promote`, `tiles://grow`, `tiles://float`, `tiles://restore`.

## Build from source

Needs only the Xcode command line tools.

```sh
./build.sh                 # build/Tiles.app
./build.sh test            # self-test
./build.sh release 0.2.0   # tag and push; GitHub Actions builds, tests and publishes the release
```

Source builds are version `dev` and never update themselves. Debug flags: `--probe` (lists what it
would tile, moves nothing), `--selftest`, `--update-now`.
