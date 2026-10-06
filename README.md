# Paper

A [Pap.er](https://paper.meiyuan.in/)-style wallpaper app for [Omarchy](https://omarchy.org), living in the Omarchy shell bar.

- Browse [Wallhaven](https://wallhaven.cc) wallpapers: **Discover** (Top / Hot / Latest / Random), **Search**, and your **Downloaded** library.
- **Per-monitor wallpapers.** The bar icon appears on every monitor's bar; clicking it targets that monitor. A mini map of your monitor layout in the popup lets you switch the target.
- **Landscape / portrait aware.** "Fit screen" filters results to the target monitor's orientation and native resolution, so rotated monitors get tall wallpapers.
- **Auto-change** every 30m / 1h / 3h / day, picking randomly from your downloads or online, always matching each screen's orientation.

## Install

```bash
omarchy plugin add https://github.com/PengXuanyao/omarchy-paper.git --enable --yes
omarchy-restart-shell
```

Paper ships its own background renderer (a per-monitor version of `omarchy.background`). Enabling Paper disables the built-in renderer; disabling or removing Paper restores it.

## Usage

| Action | Effect |
|---|---|
| Click bar icon | Open Paper targeting that monitor |
| Right-click bar icon | Reset that monitor to the theme background |
| Click thumbnail | Download (if needed) and set on the target monitor |
| Shift+click thumbnail | Set on all monitors |
| Middle-click thumbnail | Open the Wallhaven page |
| `1` / `2` / `3` | Discover / Search / Downloaded |

A global background change (theme switch, `omarchy-theme-bg-next`) clears per-monitor wallpapers.

### IPC

```bash
omarchy-shell xuanyao.paper openOn HDMI-A-1    # open the popup on a monitor
omarchy-shell xuanyao.paper random HDMI-A-1    # random online wallpaper fitting that monitor
omarchy-shell xuanyao.paper next               # auto-change all monitors now
omarchy-shell paper-background setFor HDMI-A-1 /path/to/image.jpg
omarchy-shell paper-background clearAll
```

## Settings

Plugin settings (`shell.json` entry): `downloadDir` (default `~/Pictures/Wallpapers/Paper`), `categories` (Wallhaven general/anime/people bits, default `100`), `topRange` (default `1M`).

State files:

- `~/.local/state/omarchy/current/backgrounds.json`: per-monitor wallpapers
- `~/.local/state/omarchy/settings/paper.json`: auto-change interval and source

## Requirements

`curl`, ImageMagick (`magick`), and an Omarchy version with the Quickshell-based `omarchy-shell`.

## License

MIT
