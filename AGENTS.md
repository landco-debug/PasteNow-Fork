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
- The stock Enter path and the collection-view multi-selection path are separate. The fix therefore intercepts Enter only when the collection view actually has 2+ selected items and routes that event through the controller's existing multi-item paste action.
- The original vendor application is Hardened Runtime signed, so direct `DYLD_INSERT_LIBRARIES` is blocked. The test fork keeps the vendor executable byte-for-byte as `PasteNow.real`, launches it through a tiny local wrapper, and injects a minimal AppKit runtime patch into the fork copy only.

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
- Commit: `eff928ef1a0056f083b4226967398dcfb4ded9dc`
- Extended the analyzer with Apple-Silicon (`arm64`) instruction-level disassembly.
- Confirmed the relevant PasteNow controller/action surface on the M1 architecture.
- Kept analysis reproducible in GitHub Actions.
- No behavior patch was applied in this commit.

### Commit 04 — `fix: route multi-selection Enter through multi-item paste`
- Adds `patch/PasteNowMultiPasteFix.m`, a very narrow AppKit event patch.
- Plain Return/keypad Enter is intercepted only when PasteNow's collection view currently reports 2+ selected items.
- In that case the patch finds `PasteItemViewController` and invokes its existing `onPasteItemsToFrontmostApp:` action, then consumes the original Enter event so the stock single-item path cannot run afterward.
- Single-selection Enter, modified Return shortcuts, drag-and-drop, and unrelated text/file behavior are left on the stock code path.
- Adds a tiny launcher plus a CI build workflow that produces an M1 testable `PasteNow-Fork.app` without committing the proprietary upstream bundle.
- Test: select 2+ image clips, press Enter, verify every selected image reaches the target in one action; then retest one-image Enter and drag-and-drop.

## Current status
Commit 04 contains the first behavior fix and CI packaging path. The immediate next step is to inspect the GitHub Actions build result and test the produced app on the user's MacBook Air M1 / macOS Sequoia. If the existing multi-item controller action itself proves to have the same defect, the next patch should move one level deeper and construct the selected-item pasteboard payload directly instead of broadening the keyboard interception.
