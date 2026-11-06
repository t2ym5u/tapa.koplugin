# Changelog

All notable changes to this project will be documented in this file.

## [1.6.0] - 2026-11-06

### Changed
- No puzzle needs guessing any more, and the levels are in order. Clues
  used to be picked at random, then added until a branching search found
  a single solution: every level ended up showing 75 to 100% of the
  possible clues, Hard the most, and 3 to 10% of puzzles could only be
  finished by trial and error. Now a logic solver chooses the clues: it
  adds one where it gets stuck, then removes every clue it can do
  without, and a puzzle is kept only if it finishes by deduction alone
  (which also proves its solution unique).
- The levels differ by the reasoning they need. Easy: each clue on its
  own, 2×2 blocks and the wall's next cell are enough, and about 60% of
  the possible clues are shown. Medium: about 40% of the clues, and once
  you need the whole wall (an area the wall cannot reach stays empty, a
  cell every path goes through is shaded). Hard: as few clues, and that
  whole-wall reasoning two or more times (2.2 / 2.5 / 3.1 times on
  average on 6×6 / 8×8 / 10×10; measured over 40 puzzles per size).
- 6×6 and 8×8 shadings are now grown as one region like 10×10 ones:
  quicker, and generation stays under 0.025 s on a desktop at every size
  (about 0.6 s on a Kobo; a progress bar shows meanwhile).
- The same seed gives a different puzzle than in 1.5.2, so the Daily
  Challenge puzzle changes once.

### Fixed
- The puzzle counts as solved as soon as the shading keeps every rule,
  even if it differs from the stored answer (a game saved with an older
  version may have more than one).

## [1.5.2] - 2026-11-04

### Fixed
- A game no longer crashes when an outdated plugin is installed alongside:
  shared modules left behind by an older plugin are replaced by this
  plugin's own copy instead of being used as they are.

## [1.5.1] - 2026-11-04

### Changed
- Uses less memory: the game loads when you open it, not when KOReader
  starts, so it no longer takes memory or startup time while unplayed.

## [1.5.0] - 2026-11-04

### Changed
- Much faster puzzle generation: a 10×10 grid took up to 2 s on a desktop
  (nearly a minute on an e-reader); every size now takes about a
  hundredth of a second. The uniqueness check deduces forced cells from
  every clue's possible patterns, 2×2 blocks and connectivity, and 10×10
  grows its shading as one connected region instead of retrying random
  shadings about a thousand times. 6×6 and 8×8 puzzles are the same as
  before for the same seed; 10×10 ones differ (Daily Challenge included).

## [1.4.3] - 2026-11-03

### Changed
- Picks up game-common 1.11.0: the shared on-screen keyboard (where used)
  gives every key the same letter size, and the no-repeat history helper.

## [1.4.2] - 2026-11-02

### Changed
- Picks up game-common 1.10.0: the shared Tools → Games menu also lists
  the games' new "· multiplayer" entries under Party & quiz.

## [1.4.1] - 2026-11-02

### Changed
- Listed under **Tools → Games**, grouped by category, instead of its own
  entry in the Tools menu (game-common 1.9.1).

## [1.4.0] - 2026-10-30

### Added
- "Daily Challenge" in the menu, right after "New game": today's puzzle at
  your size and difficulty, the same grid for everyone playing it today.
  Needs game-common 1.7.0.

## [1.3.0] - 2026-10-30

### Changed
- Redesigned play screen: the board is larger, filling the room the controls
  leave, with a full-width action bar under the status line and a single
  frame around the board.
- Clues are sized by how many numbers they hold: one uses the full cell
  font, two share a line, three or four go on two lines, so a "1 1 1 1" clue
  stays readable instead of shrinking to a quarter of the cell.
- The status line reads "8×8 · Medium · Shaded: 10/30 · Clues: 6" and wraps
  in landscape instead of being cut off.
- The title-bar menu shows "Size: …", "Difficulty: …" and "Show solution" /
  "Hide solution" (was "Grid: …", "Diff: …" and a bare "Show" / "Hide"), like
  every other game.
- Once the puzzle is solved, the action bar shows "New game" in place of
  Check/Hint, so the next round no longer needs the menu.

### Fixed
- The grid's right and bottom border lines were drawn past the board's edge.
- Using a hint wiped the saved game; it is now kept. When a hint completes
  the puzzle, the status shows the win message.

## [1.2.2] - 2026-10-07

### Fixed
- The Tools menu entry is translated again. `main.lua` took `_` from
  KOReader's `gettext`, which knows nothing of this plugin's strings, so the
  menu label stayed English while the game's own screen, which goes through
  `i18n`, was translated. `_` now comes from `i18n` here too.


## [1.2.1] - 2026-10-01

### Fixed
- Picks up game-common v1.5.0. Play statistics were recorded under a key no
  tool could match: `ReaderUI`/`FileManager:registerModule()` rewrite a plugin
  instance's `name` to `reader<id>` / `filemanager<id>` right after it is
  built, so this game's sessions were split across two rows and neither
  carried its plugin id. Rows written under the old keys are merged back on
  first read. The same release brings the `stopPlugin()` /
  `deletePluginSettings()` hooks KOReader 2026.07 calls when a plugin is
  deleted from the device (PR #15240).

  No change to this plugin's own code -- it inherits all of it from the
  shared library.

## [1.2.0] - 2026-09-30

### Added
- **Hint** button. Two taps, not one: the first says which cell is about to
  give, the second acts on it -- a player who is told where to look usually
  finds the rest themselves, and only pays for the full reveal if they want
  it. A cell that contradicts the solution is always reported before a fresh
  one is revealed, and on a mistake the hint empties the cell rather than
  solving it.

## [1.1.11] - 2026-07-31

### Fixed
- `board_widget.lua` referenced Blitbuffer color constants that don't
  exist (COLOR_GRAY_A), which evaluated to `nil` and crashed the
  color-comparison in `paintTo()` as soon as the corresponding
  highlight was drawn. Now uses the correct constant name(s)
  (COLOR_GRAY).

## [1.1.8] - 2026-07-29

### Fixed
- Generated puzzles had no uniqueness verification at all — measured as
  0 in 10 puzzles actually having a unique solution at every
  size/difficulty combination. Added a uniqueness solver and reworked
  generation to escalate the number of revealed clue cells for a given
  shading before accepting it, guaranteeing a unique solution whenever
  the escalation succeeds within its retry budget.
