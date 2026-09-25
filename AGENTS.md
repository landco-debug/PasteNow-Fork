# AGENTS.md

## Project
PasteNow-Fork — targeted fixes for PasteNow 2.32 (build 761) on macOS Sequoia / Apple Silicon.

## Ground rules
- Base version is fixed at PasteNow 2.32 build 761.
- Do not replace the project with a newer upstream version.
- Work in small, reviewable commits.
- Every project commit must have a matching hand-off subsection in this file describing what changed, why, and what to test.
- Preserve existing PasteNow behavior unless a change is explicitly requested.
- Primary target machine: MacBook Air M1, macOS Sequoia.
- Do not touch unrelated repositories.
- Do not commit or redistribute the upstream PasteNow application binary; CI may download the official build transiently for analysis/building.

## User-reported bug
When multiple image clips are selected in PasteNow and Enter is pressed, only one image is pasted into the active target. Drag-and-drop of the same multi-selection usually transfers all selected images. Desired behavior: Enter should paste the entire current multi-selection, while single-item Enter behavior remains unchanged.

## Acceptance criteria
1. Select 2+ image clips in PasteNow.
2. Put focus in a target that accepts image paste (initial repro: ChatGPT attachment/input area).
3. Press Enter once.
4. All selected images are transferred in one action.
5. Selecting one image and pressing Enter behaves exactly as in stock 2.32.
6. Drag-and-drop behavior is unchanged.
7. Text/file clip behavior is not regressed.

## Commit hand-off log

### Commit 01 — `chore: initialize PasteNow-Fork handoff log`
- Commit: `010842a1bfe95e47fc57429c9e437203baa9e41a`
- Initialized the repository hand-off document.
- Locked the baseline to PasteNow 2.32 build 761.
- Recorded the first target bug and acceptance criteria.
- No application code changed.

### Commit 02 — `build: add 2.32 binary analysis workflow`
- Adds a reproducible macOS CI analysis path for official PasteNow 2.32 build 761.
- The workflow downloads build 761 directly from the vendor release endpoint and verifies SHA-256 `f894ef1fce545beaeb1fbd9446cd391f5636c2d9a963eeb55a59c60f33cd10f0`.
- Adds textual Mach-O, code-signing, entitlement, symbol, Swift-demangle, ObjC metadata and string inventories as a CI artifact.
- Does not commit the upstream application binary.
- Purpose: locate the Enter/single-paste path and compare it with the multi-selection drag path before applying a minimal patch.
- Test/next step: inspect the generated artifact for selection/paste/action method names and call sites.

## Current status
Binary-analysis workflow is in place. No behavior patch has been applied yet.
