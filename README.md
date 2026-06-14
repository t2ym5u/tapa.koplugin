# tapa.koplugin

A Tapa puzzle plugin for [KOReader](https://github.com/koreader/koreader).

## Screenshot

*(Screenshot to be added.)*

## Rules

Shade cells black to form a single connected group. Numbered clue cells (never shaded) describe the consecutive shaded runs in their 8 surrounding cells. The shaded region must be fully connected. No 2×2 block may be entirely shaded.

## Features

- **Multiple grid sizes**
- **Three difficulty levels** — Easy, Medium, Hard
- **Clue highlighting** — tap a clue cell to see its affected region
- **Check** — validates connectivity and number constraints
- **Auto-save** — puzzle state saved and restored on next launch

## Installation

1. Download `tapa.koplugin.zip` from the [latest release](../../releases/latest).
2. Extract into the `plugins/` folder of your KOReader data directory.
3. Restart KOReader.
4. Open the menu → **Tools** → **Tapa**.

## Controls

| Action | How |
|--------|-----|
| Shade a cell | Tap it |
| Unshade a cell | Tap it again |
| Check progress | Tap **Check** |
| New puzzle | Tap **New** |
| Show rules | Tap **Rules** |

## License

GPL-3.0 — see [LICENSE](LICENSE).
