# Background pasteboard access on iOS 27.2

This is the research behind how Clipboard captures the clipboard while it is in the
background, why it has to be done the way it is, and which alternatives were ruled out.

Everything here was derived from the iOS 27.2 runtime on this Mac, the
`Pasteboard.framework` client, and the pasteboard daemon itself.

## The parts involved

| Component | Where it lives | What it does |
|-----------|----------------|--------------|
| `Pasteboard.framework` | `System/Library/PrivateFrameworks/Pasteboard.framework` | The client API. `PBServerConnection` talks to the daemon over XPC. |
| `pasted` | `Pasteboard.framework/Support/pasted` | The daemon. Owns the pasteboards, decides who may read them, and creates the errors. |
| `pbs` / `pasted` service | `com.apple.pasteboard.pasted` | The XPC service the client connects to. |

The daemon is small (about 290 KB) and has no local symbols, but its Objective-C
metadata, string tables and CFString constants are all intact, which is enough to
follow the logic.

## The rule

> **The general pasteboard is readable in the background by a process the system
> launches itself — an app extension — and by nothing else.**

A third-party app that is in the background gets `PBErrorDomain` code 10,
`"Pasteboard com.apple.UIKit.pboard.general is not available at this time."`

### How the daemon decides

`-[PBAuditTokenInfo ...]` is the daemon's per-client record. Decompiled
(`FUN_10000e8f0` in the Ghidra analysis of `pasted`), it is built like this:

```c
lVar8 = SecTaskCreateWithAuditToken(NULL, auditToken);
lVar9 = SecTaskCopyValuesForEntitlements(lVar8, &NSConstantArray, &outError);
if (lVar9 != 0) {
    setAllowedToQueryBundleID(info,            lookup("com.apple.Pasteboard.originating-bundle-id-query"));
    setAllowedAccessInBackground(info,        lookup("com.apple.Pasteboard.background-access"));
    setAllowedToPerformJanitorialTasks(info,   lookup("com.apple.Pasteboard.trigger-janitor"));
    setAllowedToPasteUnchecked(info,          lookup("com.apple.Pasteboard.paste-unchecked"));
    setAllowedToCopyOnPaste(info,             lookup("com.apple.Pasteboard.copy-on-paste"));
    setTrustedToRequestAuthenticationMessages(info, lookup("com.apple.Pasteboard.trusted-authentication-message-request"));
    setAllowedToPreauthorizePaste(info,       lookup("com.apple.Pasteboard.proxy-paste-authorization"));
    setAllowedToReadAppEntityData(info,       lookup("com.apple.Pasteboard.read-app-entity-data"));
    setAllowedToSpecifyOriginator(info,       lookup("com.apple.Pasteboard.specify-originator"));
    bVar3 = lookup("com.apple.Pasteboard.trusted-bundle-layout");
}
hasAppleSignature = [SecTaskCopySigningIdentifier(task, NULL) hasPrefix:@"com.apple."];

bundleRecord = LSBundleRecord.bundleRecordForAuditToken_error(auditToken, &error);
isExtension = [bundleRecord isKindOfClass:LSApplicationExtensionRecord.class];
```

Three things follow:

1. **`allowedAccessInBackground` comes from the client's own code signature.** The
   daemon reads the entitlements of the connecting process with `SecTask`, so the
   entitlement has to be inside the signed Mach-O, not merely in a plist.
2. **Apple-signed clients are trusted**, via the `com.apple.` signing identifier.
3. **`isExtension` comes from Launch Services.** If the client's bundle record is an
   `LSApplicationExtensionRecord`, the client is an app extension. Extensions are
   allowed to read the general pasteboard in the background.

### The access decision

`-[PBPasteAuthority accessToPasteboard:auditTokenInfo:authenticationMessage:sharingToken:dataOwner:]`
consults, in order:

```
isPasteExemptForPasteboard:auditTokenInfo:
    → not the general pasteboard, or the client may paste unchecked
isPasteManageableForPasteboard:auditTokenInfo:dataOwner:
    → Managed Configuration: who may paste into whom
isPasteNativeForPasteboard:auditTokenInfo:
isPasteTimelyForPasteboard:currentTimestamp:
isPasteAuthenticForAuthenticationMessage:auditTokenInfo:currentTimestamp:
isPasteFromEmbeddedDisplayDuringMirroringForAuthenticationMessage:
isPasteAuthorizedForAuditTokenInfo:pasteboard:currentTimestamp:
    → TCC, the "Paste from Other Apps" setting
pasteLegibleForPasteboard:authenticationMessage:auditTokenInfo:
```

The first three produce an *exempt* decision, which short-circuits everything else.

`isPasteExemptForPasteboard:` is worth reading closely:

```c
if (![pasteboard isGeneralPasteboard]) return 1;      // not the general pasteboard
if ([client isAllowedToPasteUnchecked])   return 2;      // com.apple.Pasteboard.paste-unchecked
return 3;                                                // not exempt
```

So for the general pasteboard, a client is exempt only with
`com.apple.Pasteboard.paste-unchecked` — another private entitlement.

`isPasteManageableForPasteboard:` is where `MCProfileConnection` comes in, which is
the Managed Configuration (MDM) connection. It maps a bundle identifier to a data
owner, and decides whether pasting between a managed app and an unmanaged app is
allowed. It governs *pasting into* other apps, not reading from the pasteboard.

### The error

The daemon imports `_PBPasteboardNotAvailableError` from `Pasteboard.framework` and
calls it to build the error the client sees:

```c
PBPasteboardNotAvailableError(name) → PBErrorDomain, code 10,
    "Pasteboard %@ is not available at this time."
```

For reference, the other codes in the same domain are 11
(`PBPasteboardNameNotAvailableError`) and 13 (`PBNotAuthorizedError`, "Operation not
authorized."). Code 13 is what an unsigned build gets, and it is the TCC denial.

## What was ruled out

### The `com.apple.Pasteboard.background-access` entitlement

This is the entitlement the daemon checks, and it cannot be had:

- Xcode refuses to build it:
  `Entitlements com.apple.Pasteboard.background-access and com.apple.Pasteboard.specify-originator not found and could not be included in profile.`
- Re-signing the app by hand, bypassing Xcode, is rejected by the phone:
  `0xe8008015 (A valid provisioning profile for this executable was not found.)` /
  `ApplicationVerificationFailed`.

The entitlement has to be in the provisioning profile, and Apple does not issue
`com.apple.Pasteboard.*` to third-party apps.

### A configuration profile

The daemon's entire preference surface is four keys, all of which were decoded from
the binary:

| Key | Purpose |
|-----|---------|
| `UseContinuity` | Universal Clipboard |
| `PlaySoundOnPaste` | Paste sound |
| `AnnounceAllPastes` | Paste announcements |
| `CopyAlienExpiryPeriod` | How long a copy survives |

None of them controls background access, and preferences are the only thing a
configuration profile can set that the daemon reads. The one MDM-shaped thing the
daemon does use, `MCProfileConnection`, is about which app may paste into which.

### A silent audio session

The well-known trick is to keep an audio session alive so the app is treated as
active. It does not work on iOS 27.2, because the gate is on the server, not in
UIKit. Measured on the device, with the session confirmed running:

```
Audio active=true changeCount=0 types=[]
```

`UIPasteboard.general` still returned an empty pasteboard, and the private read
still returned code 10.

### Claiming to own the pasteboard's data

`-[PBServerConnection localGeneralPasteboardWithAuthenticationBlock:dataOwnerBlock:completionBlock:]`
takes a `dataOwnerBlock`, and the daemon has `originatorDataOwner`,
`dataOwnerForBundleID:requestedDataOwner:` and
`isAllowedToSpecifyOriginator` (itself gated on
`com.apple.Pasteboard.specify-originator`). Passing a data owner block that claims
our bundle identifier made no difference: the same code 10 error.

## What does work

The rule above leaves one opening: a process the *system* launches may read the
general pasteboard in the background. Two kinds of app extension qualify, and the
difference matters.

### The widget extension

`ClipboardReader` is a WidgetKit extension. When the app notices the pasteboard
changed, it calls `WidgetCenter.shared.reloadTimelines(ofKind:)`, and the system
starts the widget's process to produce a timeline. That process is an app extension,
so the pasteboard daemon serves it the general pasteboard.

No notification is involved, nothing appears on screen, and the user never has to
interact. The widget's timeline provider reads the pasteboard and writes the
clipping to the shared App Group store; the widget itself shows how many clippings
are in the history, so it is useful to leave on a home screen.

The system throttles how often it will start a widget, so the app asks again until
the store shows the copy was saved:

```swift
WidgetCenter.shared.reloadTimelines(ofKind: "ClipboardReader")
```

repeating every 45 seconds, up to four times, checked against the store with
`DatabaseManager.hasItemSaved(after:)`.

### The notification service extension

`ClipboardReader` was first converted from a notification *content* extension, which
the user had to pull down to trigger, into a notification *service* extension. The
system launches a service extension by itself, with no interaction, the moment a
notification is delivered, and the extension can read the pasteboard.

That works, and it is the reason the original design was replaced at all, but it has
two drawbacks:

- **Notifications are a shared, budgeted resource.** A clipboard manager that posts
  one notification per copy will eventually be throttled by the system, and the
  copies stop being captured. In testing the extension stopped being launched
  entirely after a long session of posting.
- **A notification still has to be delivered**, even if it's passive and removed
  again a moment later.

The widget has neither problem, which is why it is the mechanism the app uses now.
The notification path is kept in the git history.

### What the app does

The app never reads the pasteboard in the background itself. It only has to notice
that the pasteboard changed, which it can do with the private
`+[PBServerConnection beginListeningToPasteboardChangeNotifications]`, and then ask
the widget to do the reading.

While the app is in the foreground it reads the pasteboard itself, through
`PBServerConnection`, which returns the original type identifiers rather than the
flattened ones `UIPasteboard` hands back.

## Known limits

- **The system throttles how often it starts a widget.** Asking for a timeline is a
  request, not a command: WidgetKit may serve it immediately, coalesce it, or drop
  it. In testing, a copy made in the background was sometimes captured within a
  minute and sometimes not at all, even with the app asking nine times over three
  minutes. Adding the widget to a home screen makes WidgetKit far more willing to
  run it, because the system then has something to render.
- **The pasteboard only holds one item.** If a second copy arrives before the widget
  reads the first, the first is gone for good. The widget always reads whatever is
  current, so the newest copy is the one that survives.
- **Opening the app is the fast path.** While the app is in the foreground it reads
  the pasteboard itself, so bringing it forward captures the current clipboard
  immediately, without waiting for the system to start anything.

## Reproducing the analysis

The daemon is a plain file in the runtime, and the analysis needs nothing but the
runtime and a decompiler:

```bash
# The daemon
RUNTIME="/private/var/run/com.apple.security.cryptexd/mnt/com.apple.iPhoneOS.SimulatorRuntime-v24.2.91014.0.X5HPQq/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 27.2.simruntime/Contents/Resources/RuntimeRoot"
cp "$RUNTIME/System/Library/PrivateFrameworks/Pasteboard.framework/Support/pasted" .

# Decompile one function
export GHIDRA_INSTALL_DIR=/opt/homebrew/Cellar/ghidra/12.1.4/libexec
export JAVA_HOME=/opt/homebrew/Cellar/openjdk/27/libexec/openjdk.jdk/Contents/Home
npx -y rea-agents@6.7.0 function pasted 0x10000e8f0 --provider ghidra
```

The addresses used above are for the iOS 27.2 simulator runtime
(`24B91014` / `24B114`); they will differ slightly between builds, but the
Objective-C selectors, the entitlement names and the CFString constants are the
things to look for.
