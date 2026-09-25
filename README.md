# PasteNow-Fork

A narrow compatibility/behavior fork for **PasteNow 2.32 (build 761)**.

Current target: when multiple image clips are selected, pressing **Enter** should paste the complete selection, matching the multi-item behavior users already get via drag-and-drop.

This repository intentionally does not contain the proprietary upstream app bundle. The CI tooling downloads the official 2.32 build transiently, verifies its known SHA-256, and emits textual reverse-engineering diagnostics used to build a minimal local patch.

See `AGENTS.md` for the exact hand-off state, acceptance criteria, and commit-by-commit history.
