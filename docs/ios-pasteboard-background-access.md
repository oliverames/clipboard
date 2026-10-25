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

> **The general pasteboard is readable in the background by a process carrying
> `com.apple.Pasteboard.background-access`, by an Apple-signed process, or by a
> process the system launches itself as an app extension — and by nothing else.**

The daemon grants background access on `background-access` **or** the extension bit
(`isExtension`), not on a single entitlement. The entitlement is the first-party
path and is unusable by a third-party app (see "What was ruled out"); the extension
bit is the path this app actually uses.

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

Oliver asked specifically whether a first-party Apple entitlement could be carried
on a build signed with his own developer certificate (team `84M4ZF255G`) with
Developer Mode on. It cannot, and the reason is in AppleMobileFileIntegrity (AMFI),
decompiled from the iOS 27.2 device runtime (`AppleMobileFileIntegrity`, build
`24B115`, arm64e):

- AMFI carries the entitlement-classification tables as data symbols. The
  `_unrestrictedEntitlements` list — the entitlements any signed code may carry
  without an Apple-issued profile — was decoded in full. **No `com.apple.Pasteboard.*`
  entitlement is in it, or in any other AMFI classification list.** The string
  `pasteboard` does not appear anywhere in the AMFI binary. Every pasteboard
  entitlement is therefore a plain *restricted* entitlement by exclusion.
- A restricted entitlement must be provisioned by a best-matching profile. AMFI's
  own error strings are the enforcement: `"The file is adhoc signed but contains
  restricted entitlements"` and `"The best matching profile does not match the
  entitlements of this file"`. Ad-hoc or self-signing the entitlement in is rejected
  — which is exactly the `0xe8008015` / `ApplicationVerificationFailed` result
  recorded above.
- **Developer Mode does not help.** `_AMFIIsDeveloperModeEnabled` disassembles to a
  single kernel sysctl read (`security.mac.amfi.developer_mode_status == 1`), and the
  `_developerModeEntitlements` list it unlocks is the debugging set only —
  `get-task-allow`, `task_for_pid-allow`, `com.apple.system-task-ports.*`,
  `com.apple.private.cs.debugger`. Developer Mode relaxes debugging, task-port attach
  and JIT; it never widens the restricted-entitlement allowlist and contains no
  pasteboard entry.
- All ten pasteboard entitlements are checked by the **daemon**, not the client
  framework: the device `Pasteboard.framework` carries none of the entitlement
  strings and imports neither `SecTaskCopyValuesForEntitlements` nor
  `LSApplicationExtensionRecord`. So there is nothing to spoof on the client side.

**Verdict: the first-party entitlement route is closed for any developer-signed
third-party build, Developer Mode on or off.** The extension (`isExtension`) path is
the only lawful way to reach the general pasteboard in the background, and it is what
this app uses.

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

Re-checked in October 2026 against the full MDM restriction schema and current Apple
deployment docs, including supervised-only payloads:

- The only pasteboard key in Apple's MDM schema is `requireManagedPasteboard`
  (`com.apple.applicationaccess`, iOS 15+): "If `true`, the
  `allowOpenFromManagedToUnmanaged` and `allowOpenFromUnmanagedToManaged`
  restrictions also limit copy-and-paste functionality." It *restricts* pasting
  between managed and unmanaged apps; no payload *grants* an app a background read.
  This matches the daemon logic: `MCProfileConnection` governs pasting into apps, not
  reading from the pasteboard.
- Supervision is no help, and getting it is costly. Apple Platform Deployment, *About
  device supervision*: manual supervision with Apple Configurator "requires that you
  have the device in your physical possession. During this process, the device is
  erased and all data is lost." Automated Device Enrollment supervises only during
  Setup Assistant, and adding a personally bought iPhone to Apple Business via
  Configurator prompts to erase it. Every documented route to supervising an
  already-set-up iPhone erases it or requires an already-erased device; none grants
  pasteboard background access anyway. (Oliver recalled supervising without an erase;
  no current Apple doc describes that path — the likeliest explanation is installing
  an unsupervised profile or restoring a backup after a Configurator prepare, neither
  of which is supervision and neither of which helps here.)

### Launch daemons and launchd jobs

Not possible on iOS without a jailbreak. Apple Platform Security states all
third-party apps are sandboxed and "apps can only perform background processing
through system-provided APIs"; third-party code runs as the unprivileged `mobile`
user with no way to install a persistent daemon. The Service Management framework
(`SMAppService`, the supported way to register a login/daemon helper) is macOS and
Mac Catalyst only — there is no iOS equivalent. `xcrun devicectl device process
launch` starts an ordinary app process under the normal lifecycle; Apple documents
no way for such a process to outlive the host connection or survive a reboot, and
Developer Mode only permits development-signed apps to run, granting no daemon
capability. So a launchd-style always-resident reader is off the table on his phone.

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

repeating on a fixed cadence up to a fixed number of attempts, checked against the
store both by `DatabaseManager.hasItemSaved(after:)` and by the change count the
widget records once it saves. If a newer copy arrives while a trigger is in flight,
the trigger re-aims at the newest change count and resets its deadline rather than
giving up early (the widget always reads whatever is current, so the newest copy is
the one that survives). The widget's read is idempotent: it skips work when the
current change count was already saved (`ChangeCountGate` + `lastSavedChangeCount` in
the shared defaults), so repeated launches for the same copy don't duplicate it.

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

### Measuring it: the capture ledger

None of this can be called rock solid without measurement, so the app keeps a small,
content-free ledger in the App Group (`CaptureLedger`, written by the app and the
widget both). It records each change heard, each reload requested, each widget run,
each save, each duplicate, each store wait, and each miss — with the change count and
timestamp, and **never the clipboard contents** (ac158ef removed content logging
deliberately; the ledger keeps it out). Settings ▸ Diagnostics shows the miss rate
computed from it: the fraction of change counts the app saw that never produced a
save. It is on by default in development builds and off in a shipped release.

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

## Surviving the app being closed

The point of a clipboard manager is that it keeps working after you stop looking at
it. "Closed" is four different things on iOS, and they behave differently. None of
this is beaten by a private entitlement (restricted, above) or a daemon (impossible,
above), so the question is only what the location mechanism can recover from. The
findings below are from Apple's current Core Location docs and, where the docs are
silent, from Apple engineers on the developer forums (flagged as such).

| Close case | What happens today | What can bring capture back without opening the app |
|-----------|--------------------|-----------------------------------------------------|
| **Suspended / backgrounded** (normal) | The process stays alive under the location session; the change listener fires and the widget trigger runs. | Already works. This is the common case. |
| **System-terminated** (memory pressure, Low Power Mode) | The process is killed. | Significant-location-change, which the app uses, **relaunches the app into the background** when a new event arrives (Apple, documented; region and visit monitoring do the same but aren't used). The app re-registers the listener on launch and capture resumes, with latency. |
| **User force-quit** (swipe up in the App Switcher) | The process is killed and not relaunched. **Capture stops until Oliver opens the app again.** | Nothing the app ships. **Accepted** (Oliver, 2026-10-25). The current docs name no relaunch mechanism; region monitoring is the only candidate, on the strength of a single Apple-engineer forum post, and it was considered and dropped (see below). |
| **Reboot, before first unlock** | Nothing runs. | Nothing. Apple: "the system does not launch an app in the background before the user first unlocks the device." |
| **Reboot, after first unlock** | Nothing until a location event. | Significant-location-change can relaunch the app once the device has been unlocked once, if the app was not force-quit before the reboot. Opening the app always resumes capture. |

Apple's statements, for the record:

- `startMonitoringSignificantLocationChanges()`: "If you start this service and your
  app is subsequently terminated, the system automatically relaunches the app into
  the background if a new event arrives." Expect no more than one event per ~5 min /
  500 m.
- Region monitoring (*Monitoring the user's proximity to geographic regions*): "If an
  iOS app isn't running when a condition is satisfied, the system tries to launch
  it… Monitoring can only occur after the user unlocks the device after a reboot."
- `startMonitoringVisits()`: "If your app is terminated while this service is active,
  the system relaunches your app when new visit events are ready to be delivered."
- BGTaskScheduler does **not** help after a force-quit: "the system… constrains to
  the set of apps that are still visible in the App Switcher" (WWDC20), and
  "The system cancels any running tasks if a person closes the app in the app
  switcher."
- Background App Refresh is an additional gate: with it off, the system relaunches
  for no location events (archived Location Awareness guide).

What the app does about this: it keeps the significant-change + continuous-update
session it always had, which covers suspension and system termination. A force-quit
is **accepted** as the stopping point, decided by Oliver on 2026-10-25: swiping
Clipboard away in the App Switcher stops capture until he opens the app again, and
opening it resumes capture straight away (the foreground read also saves whatever is
on the clipboard at that moment).

Region monitoring (`CLMonitor`, a geofence re-centred as you move) was considered as a
way to get relaunched after a force-quit and **dropped**. The only evidence it works is
one forum statement from an Apple engineer, contradicted by a report of it failing on
iOS 26.4.2. A first attempt also aborted the app at launch, because `CLMonitor.init`
raised an uncatchable Objective-C assertion in this build context. Don't pick it up
again unless that decision changes.

Every third-party clipboard manager runs into the force-quit limit. Only the Apple-only
entitlement, which AMFI blocks for a developer-signed build, would get around it.

## Private routes evaluated (no notification)

These were reverse-engineered on the iOS 27.2 runtime to see whether capture could be
made to work without the app process and without a notification. None removes the
force-quit wall; recorded here with the evidence so they are not re-investigated.

- **A system-launched process woken *by a pasteboard change*.** No. On a change the
  daemon does nothing but `notify_post` + `notify_set_state` on the Darwin name
  `_PBPasteboardChangedNotifyNotification`. It registers no launchd `LaunchEvent`, no
  `xpc_activity`, no SpringBoard launch, no BGTask, and nothing in WidgetKit/Chrono. A
  Darwin notification only wakes an already-running registrant; it cannot launch a
  process. So nothing — no extension, no helper — is started because a copy happened.
- **The change listener surviving suspension.**
  `+[PBServerConnection beginListeningToPasteboardChangeNotifications]` is a
  `notify_register_dispatch` on an in-process queue. It cannot run in a suspended app
  (the queue isn't serviced; notifications coalesce) and not at all in a force-quit
  app. It needs the process alive.
- **A cheap change-count read.** `notify_get_state` on that name returns the change
  count with no content read and no authorization. `-[PBServerConnection
  preauthorizePasteForAuditToken:pasteboardName:changeCount:completionBlock:]` takes a
  change count too. Useful for dedup and polling (the app now dedups saves by change
  count), but not a background capture path.
- **The extension allowance's exact shape.** `isExtension` is set purely from
  `[LSBundleRecord isKindOfClass:LSApplicationExtensionRecord]` — no narrowing by
  extension-point identifier, by being currently hosted, or by host foreground state.
  For the general pasteboard the daemon even skips the `linkedOnVersion >= 14.5` check
  it applies to other named pasteboards. So *any* system-launched app extension
  clears the background-withholding rule; the differentiator between extension points
  is only who launches each, and when.
- **Private WidgetKit/ChronoKit SPI to force an unthrottled reload.** None exposed.
  Refresh goes through `CHSWidgetRefreshStrategyFactory rateLimitedWithPolicyIdentifier:`
  and is budgeted by `DuetBudgetServicing` ("Throttling additional refresh request…").
  There is no third-party call to bypass it. Widget reloads come from the app
  (`WidgetCenter.reloadTimelines`, needs the app alive) or from `chronod`'s own
  relevance / Smart-Stack / scheduled refreshes (app-independent but throttled and not
  pasteboard-driven).
- **Other extension points.** WidgetKit, ChronoServices, ChronoCore and ChronoKit
  contain **zero** references to "pasteboard". Only the widget and the notification
  service extension are launched by the system without user interaction, and neither
  is launched by a pasteboard change. App Intents, Live Activity, a full-access
  keyboard and the share extension are all user- or automation-invoked, so none is a
  background, copy-triggered reader.

One item needs on-device confirmation and could not be settled from the binaries:
whether `chronod` still fires its own scheduled/relevance widget refreshes for a
widget whose host app was **force-quit** (the `chronod` binary is not in the shared
cache). If it does, an occasional later refresh would read whatever is on the
pasteboard at that time — not per-copy capture, but a partial recovery. This is on
the device checklist.

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

Toolchain note (October 2026): Homebrew now ships Ghidra 12.2, which `rea-agents`
rejects (it wants 12.1.x) and which arrives without a prebuilt native decompiler, so
the `rea … function` recipe above no longer runs as-is. The entitlement and
AMFI findings in this doc were produced by driving Ghidra 12.2 headless directly for
disassembly, references, symbols and data-table decoding (and by building Ghidra's
`ghidra_opt` decompiler from source for the C pseudo-code), plus `nm`, `otool` and
`strings`. The AMFI tables live in the **device** runtime, not the simulator: pull
`AppleMobileFileIntegrity` and the `Pasteboard` client from
`~/Library/Developer/Xcode/iOS DeviceSupport/<device> <build>/.processed_dyld_shared_cache_arm64e`.
