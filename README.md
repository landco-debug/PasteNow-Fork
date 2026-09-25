# PasteNow-Fork

Target: **PasteNow 2.32 (build 761)** on macOS Sequoia / Apple Silicon.

The requested behavior: when 2+ image clips are selected, pressing **Enter** should transfer the complete selection. Single-item Enter and drag-and-drop must stay unchanged.

## Current architecture

The original PasteNow application is **not modified or re-signed**.

The first prototype injected a dylib into PasteNow. Real-user crash diagnostics showed that ad-hoc re-signing removes the vendor identity required by PasteNow's restricted CloudKit/iCloud entitlements, causing a startup trap inside CloudKit.

The current build is therefore a small companion app, **PasteNow MultiPaste Helper**, which:
- watches Return/Enter only for the PasteNow process;
- acts only when PasteNow exposes 2+ selected items through Accessibility;
- leaves one-item Enter on the stock PasteNow path;
- sends Copy to PasteNow, returns to the previously active target app, then sends Paste;
- leaves PasteNow's bundle, signature, settings, history, database, iCloud and CloudKit identity untouched.

The helper requires Accessibility permission for the targeted event interception and selection inspection.

See `AGENTS.md` for the exact hand-off state and commit history.
