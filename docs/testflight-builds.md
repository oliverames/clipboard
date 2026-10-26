# TestFlight builds

Clipboard ships to TestFlight for internal testers only: the Internal Testers group, with no external group, beta review, or App Store release.

Before archiving, run `python3 scripts/configure-diagnostics.py` so the build carries the Sentry DSN, and afterwards `python3 scripts/configure-diagnostics.py --verify-app <archive>/Products/Applications/Clipboard.app`. An archive made without it has crash reporting off.

| Build | Date | Commit | Contents |
|-------|------|--------|----------|
| 1.2 (18) | 2026-10-25 | 9f32254 | Liquid Glass icon; redesigned history list and grid, detail, Copy As, Settings, onboarding, map, keyboard, and widget; fix for the crash when opening a clipping; capture ledger and Settings > Diagnostics (off by default in release builds); change-count de-duplication and reload coalescing; place names stored on the clipping (Core Data Model 2, lightweight migration). |
| 1.2 (17) | 2026-10-25 | 9b80ff9 | Background capture through the Clipboard widget; cached link previews; clipboard contents no longer logged. |
