# TestFlight builds

Clipboard ships to TestFlight for internal testers only: the Internal Testers group, with no external group, beta review, or App Store release.

Before archiving, run `python3 scripts/configure-diagnostics.py` so the build carries the Sentry DSN, and afterwards `python3 scripts/configure-diagnostics.py --verify-app <archive>/Products/Applications/Clipboard.app`. An archive made without it has crash reporting off.

| Build | Date | Commit | Contents |
|-------|------|--------|----------|
| 1.2 (19) | 2026-10-26 | 4f18c2d | Sentry crash and error reporting with privacy filtering and a Share Crash Reports setting; removed saved-clipping coordinate log output. |
| 1.2 (18) | 2026-10-25 | 9f32254 | Liquid Glass icon; redesigned history list and grid, detail, Copy As, Settings, onboarding, map, keyboard, and widget; fix for the crash when opening a clipping; capture ledger and Settings > Diagnostics (off by default in release builds); change-count de-duplication and reload coalescing; place names stored on the clipping (Core Data Model 2, lightweight migration). |
| 1.2 (17) | 2026-10-25 | 9b80ff9 | Background capture through the Clipboard widget; cached link previews; clipboard contents no longer logged. |

## Build 19 delivery

Build 19 was archived October 26 from clean, pushed main `4f18c2db2804002fb293b82f70d2de5fc0e0834d`. The archive and exported app passed Sentry DSN verification. The exported app, widget and keyboard extension all report 1.2 (19), share the intended App Group, and pass strict signature, active-team and distribution-profile checks. Xcode-managed profiles required automatic export; the export explicitly sets internal testing only. Apple validation and upload succeeded (delivery `47a29223-1d55-43e6-b781-f10180bcc1a5`). IPA SHA-256: `e6329748699d204f09a7afc579dda88746a8a421bee3a0252e311a0b79634770`.

Five available app, extension and shared-framework symbol files were uploaded and verified in Sentry. The symbol helper reports no matching Sentry framework dSYM. Oliver's group membership is still `INVITED`; account acceptance, installation and real-report symbolication are unverified. No tests were run because the release route requires none.

App Store Connect confirms build 19 is `VALID`, `IN_BETA_TESTING` in Internal Testers, and `NOT_APPLICABLE` externally. Export compliance matches build 18 (`usesNonExemptEncryption=false`). Exact English testing notes were saved and read back. The app has no other beta group, and no beta review was submitted.
