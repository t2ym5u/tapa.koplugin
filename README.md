# Tapa

> **Status: stub — not yet implemented**

## Description

Shade cells to form a single connected wall. Clue numbers in white cells indicate the lengths of consecutive shaded segments around that cell.

## Files to create

- `board.lua` — game logic, puzzle generator, serialize/load
- `board_widget.lua` — grid rendering and tap gestures
- `screen.lua` — full-screen layout (buttons + board)
- `main.lua` — PluginBase entry point

## Notes

Grid-based logic puzzle — use GridWidgetBase from game-common.
