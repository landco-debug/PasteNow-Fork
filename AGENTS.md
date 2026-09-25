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

## Reverse-engineering findings
- Official baseline verified: PasteNow 2.32 build 761, SHA-256 `f894ef1fce545beaeb1fbd9446cd391f5636c2d9a963eeb55a59c60f33cd10f0`.
- The relevant UI controller is Swift class `PasteNow.PasteItemViewController`.
- It exposes concrete ObjC-callable actions including:
  - `onPasteItemsToFrontmostApp:`
  - `onPasteItemsToFrontmostAppAsOriginal:`
  - `onPasteItemsToFrontmostAppAsPlainText:`
  - `paste:`
  - `collectionView:didSelectItemsAtIndexPaths:`
  - `collectionView:pasteboardWriterForItemAtIndexPath:`
- `PasteNow.WindowViewModel` contains closure-backed fields named `pasteOrCopyPasteItems`, `hitEnterButton`, `didSelectOrDeselectItem`, and `quickPreviewSelectedItems`.
- This strongly narrows the bug to the Enter action path choosing a single/current item while the collection view already maintains a multi-selection.

## Commit hand-off log

### Commit 01 — `chore: initialize PasteNow-Fork handoff log`
- Commit: `010842a1bfe95e47fc57429c9e437203baa9e41a`
- Initialized the repository hand-off document.
- Locked the baseline to PasteNow 2.32 build 761.
- Recorded the first target bug and acceptance criteria.
- No application code changed.

### Commit 02 — `build: add 2.32 binary analysis workflow`
- Commit: `02709e319505380bc693bfab0805e0e85f6a8cdf`
- Added a reproducible macOS CI analysis path for official PasteNow 2.32 build 761.
- Workflow downloads build 761 directly from the vendor release endpoint and verifies the known SHA-256.
- Added textual Mach-O, code-signing, entitlement, symbol, Swift-demangle, ObjC metadata and string inventories as a CI artifact.
- No upstream application binary is committed.
- First CI run succeeded and exposed the relevant classes/actions listed above.

### Commit 03 — `analysis: add targeted arm64 disassembly`
- Extends the analyzer with an Apple-Silicon (`arm64`) disassembly.
- Adds focused address-range extracts for `PasteItemViewController` and `WindowViewModel`.
- Purpose: map the Enter action and multi-selection paste path precisely enough for a minimal binary/runtime patch instead of guessing.
- Test/next step: inspect branch/call flow around `paste:`, `onPasteItemsToFrontmostApp:`, selection callbacks, and references to the `hitEnterButton` closure field.

## Current status
The exact classes and action selectors involved are identified. The next analysis run will provide arm64 instruction-level call flow before the patch is applied.
