# omawall

A folder-backed wallpaper service for [Omarchy](https://omarchy.org) Quattro.

Point it at a directory of images and every display gets its own random
wallpaper, with an optional auto-shuffle timer and a bar widget to drive it.
With no folder configured it behaves exactly like Omarchy's built-in
background service, so you can install it and decide later.

![omawall](preview.png)

## What it does

- **Per-display wallpapers** — each monitor is dealt its own random pick from
  the pool instead of mirroring one image across all of them.
- **Auto-shuffle** — reshuffle every _n_ seconds, or leave it at `0` and
  shuffle by hand.
- **Recursive scanning** — optionally include images nested below the chosen
  folder. Picks up `.jpg`, `.jpeg`, `.png`, `.gif`, `.bmp` and `.webp`.
- **Theme switches still work** — `omarchy theme set` keeps applying its color
  payload and recoloring the bar. Only the choice of image is taken over.
- **Bar widget** — a wallpaper icon that opens a settings panel: browse for a
  folder, toggle the options, shuffle, rescan, and see which image landed on
  which display. Middle-click the icon to shuffle without opening the panel.

## Install

```bash
omarchy plugin add https://github.com/matjam/omawall.git --enable
```

That clones the repo into `~/.config/omarchy/plugins/matjam.omawall/`,
validates it, and offers to place the bar widget. Answer the placement prompt
with `right` (or wherever you want the icon).

Enabling omawall disables Omarchy's built-in `omarchy.background` service —
the two would otherwise fight over the same wallpaper. Disabling omawall
restores it.

To update later:

```bash
omarchy plugin update matjam.omawall
```

## Uninstall

```bash
omarchy plugin remove matjam.omawall
```

This disables the plugin, restores `omarchy.background`, and deletes
`~/.config/omarchy/plugins/matjam.omawall/`. Nothing is left behind outside
that directory; all settings live in your `~/.config/omarchy/shell.json`
entry for the widget and are removed with it.

## Usage

Click the wallpaper icon in the bar to open the settings panel.

| Setting | Default | Meaning |
| --- | --- | --- |
| Wallpaper folder | _(empty)_ | Directory to draw images from. Empty means "use the current theme's backgrounds". |
| Search subfolders | on | Scan recursively below the folder. |
| Different image per display | on | Deal each monitor its own pick rather than mirroring one image. |
| Auto-shuffle every | `0` | Seconds between automatic reshuffles. `0` disables it. |

Keyboard shortcuts while the panel is open:

| Key | Action |
| --- | --- |
| `s` | Shuffle now |
| `r` | Rescan the folder |
| `b` | Browse for a folder |

### From the command line

```bash
omarchy-shell background shuffle   # reshuffle every display now
omarchy-shell background rescan    # re-read the folder
omarchy-shell background status    # JSON: pool size and current pick per screen
```

Handy as a Hyprland bind:

```
bind = SUPER SHIFT, W, exec, omarchy-shell -q background shuffle
```

## Requirements

- Omarchy Quattro (the Quickshell-based `omarchy-shell`).
- `zenity` — used only by the panel's **Browse…** button. Without it you can
  still type or paste a path into the folder field. Omarchy ships it by
  default.

No other external dependencies, no network access, and nothing is written
outside your Omarchy shell config.

## Credits

Derived from Omarchy's built-in `omarchy.background` plugin
([basecamp/omarchy](https://github.com/basecamp/omarchy), MIT) and extended
with folder mode, per-display picks, auto-shuffle, and the settings panel.

## License

MIT — see [LICENSE](LICENSE).
