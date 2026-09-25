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
- Do not commit or redistribute the upstream PasteNow application binary; CI may download the official build transiently for analysis/building.\n- Do not ship the old injected-dylib build path: ad-hoc re-signing breaks PasteNow's vendor-bound CloudKit/iCloud identity.

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
- Deeper ARM64 tracing corrected the initial hypothesis: the stock Enter path already gathers the ENTIRE collection-view selection and sends that array through `WindowViewModel.pasteOrCopyPasteItems`.
- The loss occurs later in pasteboard serialization. The general-app path iterates the selected items and invokes a helper that ultimately calls `-[NSPasteboard writeObjects:]` once per item. By contrast, the Finder path builds an array of pasteboard writers and calls `writeObjects:` once with the whole array.
- `onPasteItemsToFrontmostApp:` is therefore NOT the correct repair target for this bug; routing Enter to it can collapse back to a single/current item.
- Commit 06 leaves the stock Enter event untouched and repairs only the per-image pasteboard serialization: once a multi-selection Enter is detected and the first writer is an image, subsequent writers are retained and the general pasteboard is rewritten with the accumulated writer array.
- The vendor app is Hardened Runtime signed. The fork therefore keeps the downloaded 2.32 executable as `PasteNow.real`, removes only its signature in the fork copy, re-signs it ad-hoc without Hardened Runtime, and starts it through a tiny launcher that injects the patch dylib.

## Commit hand-off log

### Commit 01 — `chore: initialize PasteNow-Fork handoff log`
- Commit: `010842a1bfe95e47fc57429c9e437203baa9e41a`
- Initialized the repository hand-off document.
- Locked the baseline to PasteNow 2.32 build 761.
- Recorded the first target bug and acceptance criteria.
- No application code changed.

### Commit 02 — `build: add 2.32 binary analysis workflow`
- Commit: `02709e319505380bc693bfab0805e0e85f6a8cdf`
- Added reproducible macOS CI analysis for official PasteNow 2.32 build 761.
- The workflow verifies the known upstream SHA-256 before analysis.
- No upstream application binary is committed.

### Commit 03 — `analysis: add targeted arm64 disassembly`
- Commit: `eff928ef1a0056f083b4226967398dcfb4ded9dc`
- Added Apple-Silicon instruction-level analysis.
- Confirmed the relevant controller/action surface on the M1 architecture.

### Commit 04 — `fix: route multi-selection Enter through multi-item paste`
- Commit: `4c245dff94a9d879edba3d50b082a364aaf93149`
- Added `patch/PasteNowMultiPasteFix.m`, a narrow AppKit event patch.
- Plain Return/keypad Enter is intercepted only when PasteNow's collection view has 2+ selected items.
- The patch invokes `PasteItemViewController.onPasteItemsToFrontmostApp:` and consumes the original Enter event.
- Single-selection Enter, modified Return shortcuts, and drag-and-drop stay on the stock path.
- Added CI packaging for an M1-testable fork.
- First packaging run failed before artifact creation because `PasteNow.real` was intentionally unsigned after Hardened Runtime removal and the final deep-sign step rejected that nested executable.

### Commit 05 — `build: ad-hoc sign renamed PasteNow executable`
- Fixes the packaging failure from Commit 04.
- After removing the vendor Hardened Runtime signature from the fork copy, `PasteNow.real` is now immediately ad-hoc signed without `--options runtime`.
- This keeps DYLD injection available while satisfying the app bundle's nested-code signing verification.
- Test: CI must complete `codesign --verify --deep --strict`, produce the ZIP artifact, and then the user tests multi-image Enter on the M1 Mac.

## Current status
The behavior patch is implemented. Commit 05 repairs the CI signing/package step. Next step: verify the new workflow run succeeds, download the artifact, and test the exact video scenario on macOS Sequoia.


### Commit 06 — `fix: batch image writers on multi-selection Enter`
- Supersedes the behavioral strategy from Commit 04 while keeping its build/injection machinery.
- Static ARM64 tracing proved that stock Enter already sends the full selected-item array downstream.
- Root cause narrowed to the generic-app pasteboard writer: 2.32 calls `NSPasteboard.writeObjects:` separately for each selected item, while the Finder path batches all writers in one call.
- The injected patch now lets the original Enter event continue unchanged.
- On plain Enter with 2+ selected collection items it arms a short-lived pasteboard repair.
- The repair activates only when the first emitted pasteboard writer is an image. The first image is written normally; each later writer causes the general pasteboard to be cleared and rewritten with the retained accumulated writer array, preserving one pasteboard item per image and selection order.
- Single-image Enter is untouched. Non-image multi-selection does not activate batching. Drag-and-drop is untouched because no Enter arm exists for it.
- Build script now links CoreServices only for UTI image conformance detection.
- Test next: CI packaging/signature verification, then exact macOS Sequoia repro: select 2+ images -> Enter -> all images must arrive in the target in one action.

## Current status after Commit 06
The previous single-action reroute is superseded. The patch now targets the confirmed pasteboard-layer fault while preserving PasteNow 2.32's original multi-selection Enter pipeline.

### Commit 07 — `docs: record successful multipaste build`
- Records that Commit 06 is `02c589d35c8c05da40aa883b62c2a554c80706b7`.
- GitHub Actions run `36197414135` completed successfully.
- CI passed the build and final `codesign --verify --deep --strict` packaging checks.
- Produced artifact `PasteNow-Fork-2.32-MultiPaste`.
- The inner distributable ZIP SHA-256 is `fa073b71d1d232dc1fcad4bfa4cd2be3a777ceddc62c9d42d7f51b8a9ead18f2`.
- Post-download verification confirmed:
  - `PasteNow.real` is the official universal 2.32 executable (x86_64 + arm64).
  - The fork launcher is arm64.
  - `PasteNowMultiPasteFix.dylib` is arm64 and contains the new pasteboard-batching implementation, not the superseded `onPasteItemsToFrontmostApp:` reroute.
- Remaining validation is the exact user-level macOS Sequoia interaction: select 2+ image clips, press Enter, confirm all selected images are inserted.

## Current status
A buildable M1 test artifact for the corrected Commit 06 fix is ready. The next hand-off action is user validation of the original video repro; do not redesign the patch unless that test exposes a specific remaining failure.


### Commit 08 — `fix: preserve CloudKit identity with external multipaste helper`
- Real-user validation of the injected build failed before UI testing: PasteNow crashed during startup.
- Crash report showed `PasteNowMultiPasteFix.dylib` was loaded, then the main thread trapped in CloudKit while CloudSyncKit initialized its `CKContainer`.
- The forked executable had been ad-hoc signed and no longer carried the vendor Team ID. PasteNow 2.32 depends on restricted iCloud/CloudKit entitlements tied to the vendor signing identity, so copying entitlement strings cannot make the ad-hoc build valid.
- The in-process injection architecture is therefore retired for shipping. Existing injection source remains only as historical reverse-engineering reference and is no longer built by the main workflow.
- Added `helper/PasteNowMultiPasteHelper.m`, a standalone companion that leaves the original PasteNow.app untouched.
- The helper uses a keyboard event tap scoped specifically to PasteNow's PID, not a system-wide key logger.
- Plain Return/keypad Enter is consumed only when Accessibility reports 2+ selected PasteNow items.
- For that case the helper sends Command-C to PasteNow, waits for the general pasteboard to change, dismisses the PasteNow panel, returns to the previously active non-PasteNow app, and sends Command-V there.
- Single-selection Enter stays entirely on PasteNow's stock path.
- Added a small `PN` menu-bar status item for Accessibility state and quitting.
- Added `tools/build_helper.sh` and replaced the main packaging workflow so CI now builds only the companion helper.
- Important validation checkpoint: confirm stock Command-C copies the complete current multi-selection. If PasteNow collapses Command-C to one item, keep the no-resign architecture and change the external transfer mechanism rather than returning to dylib injection.

## Current status after Commit 08
The startup crash has a confirmed architectural cause: ad-hoc re-signing invalidated PasteNow's CloudKit identity. The safe build now preserves the untouched original PasteNow 2.32 and moves the Enter workaround into a companion helper. Next step is CI compile/package, then user validation on the M1 Mac.
