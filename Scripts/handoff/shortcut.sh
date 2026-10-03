#!/bin/zsh
# Trigger: Shortcuts from the shell. The only trigger that returns the value directly.
# One-time setup: in Shortcuts, make a shortcut named "TerrierGPT Handoff" containing the
# single action "Export TerrierGPT Answer as Handoff" (set Contract / Return as you like).
exec shortcuts run "${1:-TerrierGPT Handoff}" --output-path - </dev/null
