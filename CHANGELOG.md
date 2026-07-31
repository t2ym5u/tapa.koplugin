# Changelog

All notable changes to this project will be documented in this file.

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
