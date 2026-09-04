# Promptdeck v1.0 Pre-Launch Audit

**Date:** 2026-09-04
**Commit:** `092c02f` (main, clean)
**Scope:** Full read-only audit of all 14 Swift sources (~4,000 lines), the Xcode project, and the built Release artifact.
**Focus areas requested:** race conditions, cryptography, packaging/launch readiness.

Everything below was verified against the source or against a Release build produced during the audit (`** BUILD SUCCEEDED **`, zero compiler warnings). No files were modified, and nothing was committed.

---

## Executive summary

The core is genuinely good. The archive format is well-designed (AES-256-GCM, PBKDF2-HMAC-SHA256 at 600k iterations, random salt and nonce, AAD covering the full header, generic failure messages that never distinguish wrong-passphrase from tampering). The backup engine is written defensively — fail-closed ownership checks before deletion, atomic writes, state that only advances after verification. Manual export and automatic backup share one byte-identical format, which is exactly right. The code compiles clean under Swift 6 language mode.

The problems are concentrated in three places:

1. **Packaging is not launch-ready.** The Release build is ad-hoc signed with `com.apple.security.get-task-allow` enabled. That entitlement lets any local process attach a debugger and read the decrypted passphrase and derived AES key out of memory, and it will cause notarization to be rejected outright.
2. **The backup feature can permanently destroy the user's ability to read their own backups**, and there is no restore path in the app at all.
3. **Every cryptographic and filesystem operation runs synchronously on the main thread**, in an app whose own Settings screen recommends putting the backup folder on a network or synced volume.

The race conditions you asked about are mostly *latent* rather than active — the code is accidentally safe because everything is synchronous on the MainActor. That safety is not enforced by any type or lock, and the most obvious performance fix (moving crypto off the main thread) would convert several of them into live bugs. They are documented below with that coupling made explicit.

### Priority ordering

| # | Finding | Severity | Effort |
|---|---------|----------|--------|
| C1 | `get-task-allow` in Release build | **Blocker** | Trivial |
| C2 | Ad-hoc signing / no Developer ID | **Blocker** | Small |
| D1 | Turning backup off destroys the decryption key | **Blocker** | Small |
| D2 | No restore path in the app | **High** | Medium |
| P1 | All crypto + file I/O on the main thread | **High** | Medium |
| D3 | Retention keeps "last 14 writes", not a time window | **High** | Medium |
| X1 | Attacker-controlled PBKDF2 iteration count | Medium | Trivial |
| R1 | `BackupConfigurationStore` is unsynchronised shared mutable state | Medium | Small |
| R2 | Nested modal run loops permit backup reentrancy | Medium | Small |
| R3 | Content mutations are not flushed before backup is scheduled | Medium | Trivial |
| D4 | 24-hour retry interval for failed backups | Medium | Small |
| S1 | `isDangerous` is stored and edited but never shown | Medium | Trivial |
| Q1 | No test target for 4,000 lines of crypto/backup code | Medium | Large |
| — | 20 further findings below | Low–Medium | Varies |

---

## 1. Packaging and launch readiness

### C1 — `com.apple.security.get-task-allow` is present in the Release build — **Blocker**

Verified against the built artifact:

```
$ codesign -d --entitlements - Promptdeck.app
[Key] com.apple.security.get-task-allow
[Value] [Bool] true

$ codesign -dvvv Promptdeck.app
CodeDirectory ... flags=0x10002(adhoc,runtime)
Signature=adhoc
TeamIdentifier=not set
```

`get-task-allow` grants any process running as the user the right to attach to Promptdeck and read its address space. In this app that address space contains, at various moments, the plaintext passphrase (`String`), the derived 32-byte AES key (`Data`), and the full decrypted library. This directly undermines the threat model the encrypted-archive design was built for.

It is also an automatic notarization rejection: Apple's notary service refuses any binary carrying `get-task-allow`.

Xcode injects this entitlement because `CODE_SIGN_IDENTITY = "-"` (`Promptdeck.xcodeproj/project.pbxproj:245`, `:268`). It disappears once you sign with a real Developer ID identity for the Release configuration. Verify after fixing with the exact `codesign -d --entitlements -` command above — do not assume.

### C2 — Ad-hoc signing means the app will not run on any other Mac — **Blocker**

`CODE_SIGN_IDENTITY = "-"` with `ENABLE_HARDENED_RUNTIME = YES` and no team identifier. Gatekeeper will block this on first launch on any machine other than the one that built it.

Two knock-on effects specific to this app, both worth understanding before you pick a signing strategy:

- **Keychain ACLs are bound to the code signature.** Under ad-hoc signing the signature changes on every rebuild, so the backup passphrase item created by `BackupKeychainService.save` (`BackupKeychainService.swift:41`) will prompt the user — or become inaccessible — after each update. A stable Developer ID identity fixes this; ad-hoc distribution never will.
- **TCC grants are bound to the same signature.** The backup folder picker allows any location, including Desktop, Documents, Downloads, and iCloud Drive — all TCC-protected. Those approvals reset on every signature change too.

Required before shipping: Developer ID Application certificate, `--options runtime`, notarization, and stapling. Confirm the universal slice survives (the current build is correctly `x86_64 arm64`).

### C3 — `.promptdeck` is not a declared file type — **Medium**

The generated `Info.plist` contains no `UTExportedTypeDeclarations` and no `CFBundleDocumentTypes` (verified with `plutil -p` on the built app). `UTType(filenameExtension: "promptdeck")` at `ExportService.swift:327` and `ImportService.swift:309` therefore resolves to a *dynamic* UTI rather than a type you own.

Consequences: `.promptdeck` files show a blank generic icon in Finder, double-clicking one does nothing, "Open With" does not list Promptdeck, and the save/open panel filtering rests on LaunchServices' extension-to-`dyn.` mapping rather than on a declared type. For an app that names data portability as an explicit design goal, this is the most visible gap.

Declare an exported type (`com.mbuckingham.promptdeck.archive`, conforming to `public.data`), give it a document icon, and add a `CFBundleDocumentTypes` entry so double-click opens the import flow.

### C4 — `.gitignore` is empty (0 bytes) — **Low**

Nothing is ignored. `build/`, `DerivedData/`, `*.xcuserdatad/`, and `.DS_Store` will all be committed the moment they appear. Add a standard Swift/Xcode ignore file before the v1.0 tag.

### C5 — Deployment target is macOS 26.0 — **Informational**

`MACOSX_DEPLOYMENT_TARGET = 26.0` restricts the app to the current major release only. Nothing in the source requires it that I could find — SwiftData, `@Observable`-era SwiftUI, and `NSSearchToolbarItem` are all available considerably earlier. If reach matters at launch, test-lowering the target is probably a small change. If it is deliberate, ignore this.

### C6 — Missing launch metadata — **Low**

No `LICENSE`, no `CHANGELOG`, no privacy statement, no `NSHumanReadableCopyright` in the plist. `README.md` is six lines and `docs/` was empty before this file. For a utility that encrypts user data and writes to user-chosen folders, a short "what is stored, where, and how" statement is worth having.

---

## 2. Cryptography

The scheme itself is correct and modern. Findings here are hardening, not breaks.

### What is right (do not change it)

- AES-256-GCM via CryptoKit; nonce from `AES.GCM.Nonce()` (CSPRNG), never reused, never derived from anything.
- PBKDF2-HMAC-SHA256 at 600,000 iterations — at or above current OWASP guidance.
- 16-byte salt from `SecRandomCopyBytes`, per-archive.
- AAD covers magic ‖ version ‖ headerLen ‖ header bytes, so the KDF parameters are authenticated and cannot be downgraded by an attacker who lacks the key (`PromptdeckArchiveCodec.swift:155-159`).
- Wrong passphrase, corruption, and tampering all collapse to a single `decryptionFailed`, and the `emptyPassphrase` case is explicitly re-mapped to it on the open path (`:230-235`) so the error channel leaks nothing. This is a detail most implementations get wrong.
- Passphrase used as exact UTF-8 bytes with no trimming or normalisation, consistently on both sides.
- Keychain item uses `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — correct choice; the passphrase never syncs.
- No secret, hash, or path appears in any user-facing error string.

### X1 — `iterations` is read from the untrusted header and bounded only at 10,000,000 — **Medium**

`PromptdeckArchiveCodec.swift:84` accepts any value in `1...10_000_000` from the file header, and `open` passes `header.iterations` straight into `deriveKey` (`:229`).

A malicious or corrupted `.promptdeck` file can therefore request ~16× the normal key-derivation work. Because the whole import path is synchronous on the main thread (see P1), that is a multi-second frozen UI with a spinning beachball, with no cancel. Conversely a file claiming `iterations: 1` is accepted silently — harmless for confidentiality (the file's author already knows its contents) but it removes any guarantee about what a "successfully opened" archive cost to open.

**Fix:** clamp the accepted range on read to something defensible, e.g. `100_000...2_000_000`, and reject outside it as `invalidArchive`. Keep writing 600,000.

### X2 — Byte-order readers assume zero-based `Data` indices — **Low (latent)**

`readUInt16BE` / `readUInt32BE` (`PromptdeckArchiveCodec.swift:52-64`) index with `data[offset]`. Swift's `Data` subscript is offset-*into-the-parent*, not slice-relative, so passing a slice would read the wrong bytes or trap.

Every current caller passes a zero-based `Data` (`Data(contentsOf:)`, or the fresh buffer returned by `AES.GCM.open`), so this is not reachable today. It is a sharp edge on a routine that parses untrusted input. Use `data[data.startIndex + offset]`, or take a `RandomAccessCollection` and index relatively.

### X3 — No minimum passphrase strength, and no way to check it later — **Medium**

Both passphrase sheets accept any non-empty string (`ExportService.swift:400-407`, `BackupSettingsView.swift:310-316`). A single character is accepted.

In isolation that is a defensible "no arbitrary complexity rules" stance. It stops being defensible in combination with the Settings copy that *recommends* placing backups "in a synced/network location" (`BackupSettingsView.swift:57`) — that is an explicit instruction to put the ciphertext somewhere the user does not fully control, protected by a passphrase the app never evaluates. 600k PBKDF2 iterations buy very little against a 6-character passphrase.

**Fix:** a minimum length (12 is a reasonable floor) plus a non-blocking strength indicator on the *automatic backup* sheet specifically, since that one is protecting an off-machine copy. Leaving manual export unconstrained is fine.

### X4 — Key and passphrase material is never zeroed — **Low**

`deriveKey` builds `[UInt8]` and returns `Data` (`:87-116`); the passphrase lives in `String` and in SwiftUI `@State`. None of it is wiped after use. Swift makes truly reliable zeroisation difficult (values get copied, `String` may be heap-allocated and CoW'd), so this is partial mitigation at best — but zeroing the derived-key array in a `defer` before it goes out of scope is cheap and reduces the window. Lower priority than C1, which is what actually exposes this memory today.

### X5 — Export can silently overwrite a file the save panel never asked about — **Low**

`exportDestinationURL` appends `.promptdeck` *after* `NSSavePanel` has run and performed its overwrite check (`ExportService.swift:336-339`). If the returned URL lacked the extension, the appended path may collide with an existing file that the user was never warned about, and `write(to:options:.atomic)` will replace it.

With `allowedContentTypes` set and `allowsOtherFileTypes = false` the panel normally enforces the extension already, so this is a narrow path — but it is a silent data-destroying one. Check `FileManager.fileExists` after appending and re-confirm.

---

## 3. Data safety and the backup feature

This section contains the findings I would fix first after the signing blockers.

### D1 — Turning automatic backup off destroys the only key to every existing backup — **Blocker**

`AutomaticBackupService.disable()` deletes the Keychain passphrase (`AutomaticBackupService.swift:296`) and then clears all configuration. Backup *files* are deliberately kept — the UI says so: *"Turning off removes the saved settings and passphrase. Backup files are kept."* (`BackupSettingsView.swift:120`).

The setup sheet, meanwhile, tells the user: *"Choose a passphrase to protect automatic backups. **You will not be asked for it again on this Mac.**"* (`BackupSettingsView.swift:290`).

Those two sentences combine into a trap. The app actively tells users they will never need to remember the passphrase, then offers a one-click button that deletes it while keeping fourteen files that are worthless without it. The button is styled `.destructive` and has no confirmation dialog. There is no undo.

The same shape exists in `cleanupFailedSetup()` (`:580-583`): the documented behaviour is that a snapshot file written before a later failure "is left in place", while the Keychain item is deleted — producing an orphaned, permanently undecryptable archive.

**Fix, in order of value:**
1. Add a confirmation sheet to "Turn Automatic Backup Off" that states plainly that existing backups will become unreadable without the passphrase, and offers to reveal it one last time so the user can store it in a password manager.
2. Soften the setup copy — "you will not be asked for it again on this Mac, but you will need it to restore on a different Mac, so save it somewhere safe."
3. Offer to reveal the passphrase from Settings at any time while backup is enabled, gated behind local authentication.

### D2 — There is no way to restore a backup from inside the app — **High**

`grep -i restore` across the entire source returns nothing. The automatic backup engine writes fourteen encrypted snapshots and offers no path to read any of them back. The only route is the manual Import toolbar button, which requires the user to navigate to `~/…/Promptdeck Backups/`, pick a file whose type the app has not declared (C3), and type a passphrase the setup sheet told them they would never need (D1).

A backup system with no restore is not a backup system. This is the largest functional gap for a 1.0 that markets automatic backup as a headline feature.

**Fix:** a "Restore from Backup…" control in Settings that lists managed snapshots by date (`listManagedSnapshots()` already provides exactly this), decrypts the chosen one using the Keychain passphrase, and routes into the existing `prepareImport` → confirm → `applyImport` pipeline. Most of the machinery exists; this is mostly UI.

### D3 — Retention keeps the last 14 *writes*, which is not the same as a recovery window — **High**

`maxSnapshots = 14` (`AutomaticBackupService.swift:24`), and `enforceRetention` deletes the oldest managed snapshots beyond that (`:551-575`).

Backups are triggered by content change with a 30-second debounce (`AutomaticBackupScheduler.swift:34`). So a single focused editing session — add a prompt, pause, tweak a tag, pause, fix a typo, pause — can produce fourteen snapshots in under ten minutes and evict every snapshot from the preceding weeks.

The failure this creates is precisely the one backups exist to prevent: the user deletes something on Tuesday, notices on Thursday, and every retained snapshot is from Thursday afternoon.

**Fix:** generational retention. Keep the most recent N, plus one per day for the last week, plus one per week for the last month. The filenames already carry sortable timestamps, so bucketing is straightforward, and the change is contained entirely within `enforceRetention`.

### D4 — A failed backup is not retried for 24 hours, and warns only once per process — **Medium**

The only retry mechanisms are content change, process launch, and a 24-hour loop (`AutomaticBackupScheduler.swift:88-100`). If a backup fails at 09:00 because an external drive is unplugged or a network share is unmounted — the *most likely* failure given the recommended setup — nothing retries until the user next edits something, relaunches the app, or 24 hours pass.

Compounding this: the warning alert is gated to one presentation per process by `didRequestBackupWarning` (`:53-57`), and `dismissWarning()` deliberately does not reset it. A user who dismisses the alert on Monday and leaves the app running gets no further signal, however many backups fail afterwards. The Settings screen shows the stored error, but only if opened.

Note also that the 24-hour loop is anchored to *process start*, not to `lastBackupDate`. Nothing in the system asks "how long has it been since a backup actually succeeded?"

**Fix:** exponential backoff retry (1 min → 5 → 15 → 60, capped) after a failure; anchor the periodic check to `lastBackupDate` rather than process uptime; and re-arm the warning after a meaningfully long interval or after a *new distinct* error rather than never.

### D5 — Import overwrites local entries with no pre-import snapshot — **Medium**

`applyImport` overwrites every matching local entry field-by-field, including `createdAt` and `updatedAt`, with no comparison of which side is newer (`ImportService.swift:205-226`, `:258-286`). Importing an older export over newer local edits silently reverts them.

`contentDidChange()` is called *after* the merge (`ContentView.swift:206`), which schedules a backup of the post-import state 30 seconds later. The pre-import state is recoverable only from whatever snapshot happens to still be in the retention window — which, per D3, may be minutes old.

**Fix:** call `performBackup(force: true)` immediately before applying an import, and surface that in the confirmation alert ("A backup will be taken first"). Optionally add an `updatedAt`-based conflict summary so the user can see they are about to import older data.

### D6 — Retention orders by creation date, which is unreliable on synced volumes — **Medium**

`listManagedSnapshots` sorts by `.creationDateKey`, falling back to filename (`:451-460`). Dropbox, iCloud Drive, and OneDrive all rewrite creation dates when re-materialising evicted files — on exactly the volumes the Settings copy recommends. The wrong snapshots get pruned.

The filenames already encode `yyyy-MM-dd HH-mm-ss`, which sorts lexicographically in chronological order, and `isManagedSnapshot` has already validated the stamp by strict formatter round-trip before any file reaches the sort. Make the filename the primary key and drop the creation-date read entirely — it is both more correct and one fewer stat per file.

### D7 — Backup filenames use local time — **Low**

`uniqueDestination` (`:516-528`) and `snapshotStampFormatter` (`:427-434`) both use the default time zone. A time-zone change or a DST fall-back means filenames stop increasing monotonically, which interacts badly with D6's filename ordering. Use UTC for the on-disk stamp and format for display only.

### D8 — `uniqueDestination` has a TOCTOU gap and an unbounded loop — **Low**

`fileExists` then `write(options: .atomic)` (`:523`, `:535`) — a sync client or a second Promptdeck instance can create the file in between, and the atomic write will replace it. Nothing prevents two instances of the app running. The `while` loop also has no iteration cap.

Use `Data.write(to:options:[.atomic, .withoutOverwriting])` and retry on collision, and bound the counter.

---

## 4. Race conditions and concurrency

The headline: **the app is currently safe by accident, not by construction.** Every path that touches shared backup state happens to run synchronously on the MainActor with no suspension point inside the critical section. Nothing in the type system enforces that, several functions are `nonisolated` and callable from anywhere, and the natural fix for P1 below (moving crypto off the main thread) removes the accident.

### R1 — `BackupConfigurationStore` is unsynchronised shared mutable state — **Medium**

```swift
static nonisolated(unsafe) let shared = BackupConfigurationStore()
```
`BackupConfigurationStore.swift:14`. The comment justifies this as *"all reads/writes funnel through UserDefaults (thread-safe) plus plain in-memory state."* That is not accurate — the seven `@Published` properties are plain stored properties with no synchronisation, and `UserDefaults` thread-safety says nothing about them. Mutating a `@Published` off the main thread is also a SwiftUI violation in its own right.

Callers that mutate the store while *not* being `@MainActor`-isolated:

- `AutomaticBackupService.enforceRetention` → `store.lastErrorMessage = …; store.save()` (`:571-573`) — a plain `static func`
- `AutomaticBackupService.disable()` → `clearAll()` (`:300`) — a plain `static func`

Both are reached today only from `@MainActor` callers, so no live bug. But `nonisolated(unsafe)` is exactly the annotation that tells the compiler to stop checking, and these two functions are the ones that will be called from a background context the moment anyone moves the write path off the main thread.

**Fix:** annotate the class `@MainActor` and mark `enforceRetention` / `disable()` `@MainActor` too. The compiler then proves what the comment currently only asserts, and `nonisolated(unsafe)` can go away.

### R2 — Nested modal run loops permit backup reentrancy — **Medium**

There is no mutual-exclusion guard anywhere in `AutomaticBackupService`. Five entry points can start a backup: the debounce task, the daily task, the launch catch-up, "Back Up Now", and "Change Location…".

Serialisation currently comes from all five being synchronous on the MainActor — but `NSOpenPanel.runModal()`, `NSSavePanel.runModal()`, and `NSAlert.runModal()` each **spin a nested run loop on the main thread**, which lets queued MainActor work execute mid-operation. Concretely:

- `pickFolderForChange()` (`BackupSettingsView.swift:175-181`) blocks in `runModal()`. A pending 30-second debounce or the daily task can fire during that window and run a full `performBackup` against the *old* location, advancing `lastHash`, `lastSnapshotFilename`, and `lastBackupDate`. `changeLocation` then proceeds and overwrites all three.
- Every `NSAlert.runModal()` in the export/import flows (`ExportService.swift:290`, `ImportService.swift:324`) has the same property.

The observable outcomes today are benign — the writes are individually atomic and the store ends up internally consistent. But it means two backups genuinely can be in flight at once, which is not what the code is written to assume.

**Fix:** a single `private static var isRunning = false` guard at the top of `performBackup` / `setupFirstBackup` / `changeLocation`, returning early or throwing if already running. Cheap, and it makes the invariant explicit rather than emergent.

### R3 — Content mutations are not flushed before a backup is scheduled — **Medium**

`grep '\.save()'` shows **no** `modelContext.save()` anywhere in the UI mutation paths. Every insert, edit, delete, and favourite-toggle relies on SwiftData autosave:

```swift
modelContext.insert(newEntry)
AutomaticBackupScheduler.shared.contentDidChange()   // ContentView.swift:854-856
```

The scheduled backup runs 30 seconds later on a **fresh** `ModelContext(PromptdeckApp.sharedContainer)` (`AutomaticBackupScheduler.swift:143`). A separate context cannot see another context's unsaved changes. If autosave has not flushed, the backup fingerprints stale content.

The outcome is self-healing but not harmless: the fingerprint matches the stored `lastHash`, `performBackup` returns `.alreadyBackedUp`, and the edit is simply **not backed up** until some later trigger. Given D4's 24-hour retry and the launch catch-up, "later" can mean the next app launch. Thirty seconds is usually enough for autosave — but "usually" is the wrong guarantee for a backup system.

**Fix:** `try? modelContext.save()` immediately before each `contentDidChange()` call, or have `contentDidChange` take the context and save it. Seven call sites.

### R4 — Snapshot/fingerprint capture is not atomic with the store update — **Medium (latent; becomes live if P1 is fixed)**

`sealedArchive` captures and fingerprints at T0 (`:477-512`); `writeArchive` completes at T1; `store.lastHash` is then set to the T0 fingerprint (`:110`). Any mutation landing in [T0, T1] is recorded as already-backed-up when it is not.

Today T0 and T1 are in the same synchronous MainActor turn, so the interval is unenterable and the bug is unreachable. **If you move the crypto and file I/O off the main thread — which P1 recommends — this becomes a live data-loss bug.** The two findings must be fixed together: capture the fingerprint and the resulting state transition under the same actor hop, or re-verify the fingerprint after the write before advancing `lastHash`.

I am flagging this specifically because it is the trap waiting behind the obvious performance fix.

### R5 — `Dictionary(uniqueKeysWithValues:)` will trap on duplicate IDs, and `id` has no uniqueness constraint — **Medium**

```swift
let promptsByID = Dictionary(uniqueKeysWithValues: existingPrompts.map { ($0.id, $0) })
```
`ImportService.swift:178-179`. This is a `precondition` — on a duplicate key it traps and kills the process, in Release, mid-import.

Neither `PromptEntry.id` nor `CommandEntry.id` carries `@Attribute(.unique)` (`PromptEntry.swift:6`, `CommandEntry.swift:12`), so nothing at the storage layer prevents duplicates. I traced the current insert paths and could not construct a reachable duplicate: fresh entries get a new `UUID()`, `prepareImport` rejects intra-document duplicates (`:121-128`), and `newPrompts`/`updatePrompts` are disjoint by construction. So this is not reachable today.

It is still the wrong construct: the failure mode is a hard crash rather than a handled error, and a future migration, a CloudKit sync, or a restored-from-backup store could introduce duplicates without warning.

**Fix:** `Dictionary(existingPrompts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })`, and add `@Attribute(.unique)` to both `id` properties (note this requires a lightweight migration).

### R6 — `focusSearchNow()` can target the wrong window — **Medium**

```swift
guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible), …
```
`ContentView.swift:501` and `:987`. This picks a window by global search rather than by view ownership, then calls `NSApp.activate(ignoringOtherApps: true)` and force-sets first responder.

This is the exact bug that Task 16C fixed for the key monitor — `LibraryKeyMonitor` now correctly scopes to its own window via `viewDidMoveToWindow` (`:294-353`) — but the same treatment was never applied to focus handling. With the Settings window open, `NSApp.keyWindow` is Settings; the `guard` then falls through harmlessly because Settings has no `NSSearchToolbarItem`, but the `NSApp.activate(ignoringOtherApps: true)` on line 500/986 has **already executed** and stolen activation.

Worse, this fires from `.onReceive(NSApplication.didBecomeActiveNotification)` (`:725`, `:1211`) — every single app activation — and each `focusSearch()` schedules it *twice*, once immediately and once after a 150 ms `asyncAfter` (`:489-496`). That timing hack races with sheet presentation and alert dismissal.

**Fix:** resolve the window through the same `NSViewRepresentable` ownership mechanism `LibraryKeyMonitor` already uses, and drop the 150 ms retry. Separately, `NSApp.activate(ignoringOtherApps:)` is deprecated as of macOS 14 — with a 26.0 deployment target, use `NSApplication.activate()`.

### R7 — `isWorking` never disables anything — **Low**

```swift
isWorking = true
defer { isWorking = false }
```
`BackupSettingsView.swift:187-188`, `:205-206`, `:225-226`, `:241-242`. Because the enclosed work is fully synchronous on the MainActor with no suspension point, SwiftUI never gets a chance to render between the two assignments. The `.disabled(isWorking)` modifiers on all four buttons are dead code, and the user gets a frozen window with no progress indication during a multi-hundred-millisecond operation.

This resolves itself once P1 makes the operations genuinely asynchronous — at which point `isWorking` starts doing its job and also becomes load-bearing for R2.

### R8 — Copy actions mutate the model without scheduling a backup — **Low**

`copyPrompt` / `copyCommand` set `lastCopiedAt` (`ContentView.swift:483`, `:969`) and do not call `contentDidChange()`, unlike the seven other mutation sites. Since `lastCopiedAt` is part of the export DTO and therefore of the fingerprint (`BackupFingerprint.swift:22-31`), copy history is only ever captured incidentally by the next unrelated backup.

I think this is the right call — backing up on every copy would fire on the app's hottest path — but it contradicts the scheduler's own doc comment (*"every successful content mutation calls `contentDidChange()`"*, `AutomaticBackupScheduler.swift:10`). Worth a one-line comment at the call site recording the deliberate exception.

### R9 — Symlink re-check before delete remains a TOCTOU — **Low**

`enforceRetention` re-guards with `isManagedSnapshot(url)` immediately before `removeItem` (`:561-565`), which is good defensive practice, but a symlink can still be swapped in between the check and the removal. This is the classic unavoidable filesystem race and requires a local attacker with write access to the backup folder; `removeItem` also does not follow symlinks for the unlink itself. Noted for completeness — the existing design is already at the reasonable-effort frontier.

### R10 — `applyImport` silently coerces an invalid platform — **Low**

```swift
let platform = CommandPlatform(rawValue: dto.platform) ?? .macOS
```
`ImportService.swift:230`, `:259`. `prepareImport` already validated every platform (`:113-117`), so the fallback is unreachable — but if it ever became reachable it would silently write wrong data rather than failing the import. Prefer throwing.

---

## 5. Performance

### P1 — All cryptography and file I/O runs on the main thread — **High**

Every backup and every import/export blocks the UI for its full duration. `performBackup` is `@MainActor` (`AutomaticBackupService.swift:62`) and synchronously performs:

1. Keychain read
2. `createDirectory` on the backup volume
3. Full SwiftData fetch and DTO mapping of both libraries
4. JSON encode ×2, pretty-printed with sorted keys
5. SHA-256 fingerprint over the whole encoded document
6. **PBKDF2, 600,000 iterations** — hundreds of milliseconds even on Apple Silicon
7. AES-GCM seal
8. Atomic write to the destination
9. `enforceRetention` → `contentsOfDirectory` plus a `resourceValues` read **and a `FileHandle` open** for every candidate file (`isManagedSnapshot`, `:390-406`) — roughly fifteen file opens
10. Possibly a second `store.save()`

Steps 2, 8, and 9 are filesystem round-trips on a volume the Settings screen explicitly recommends should be a **network or synced location** (`BackupSettingsView.swift:57`). On a stalled SMB mount or a sleeping external drive, those calls can block for tens of seconds with a spinning beachball and no cancel.

The import path has the same shape: `Data(contentsOf:)`, PBKDF2 at an attacker-chosen iteration count (X1), AES-GCM open, JSON decode, and a full store fetch — all inside a SwiftUI sheet callback on the main actor (`ContentView.swift:167-180`).

**Fix:** move steps 3–9 to a detached task; keep the SwiftData fetch on the MainActor and hand the resulting DTOs (which are `Sendable` value types) across the boundary. Make the Settings actions `async` so `isWorking` (R7) starts working and can show a progress indicator. **Fix R4 at the same time** — it is the race this change exposes.

### P2 — Import reads the entire file into memory with no size cap — **Medium**

`let data = try Data(contentsOf: url)` (`ContentView.swift:91`), from a user-picked file, on the main thread, with no bound. Picking a multi-gigabyte file will exhaust memory or hang. A sane ceiling (say 100 MB — orders of magnitude above any plausible library) rejected with a clear message costs three lines.

### P3 — Filtering and sorting are recomputed many times per render — **Medium**

`filteredPrompts` is a computed property that filters, then sorts with `localizedCaseInsensitiveCompare` (`ContentView.swift:455-474`, `sortPromptsByRecency` `:250-266`). It is evaluated in `content`, in `selectedPrompt`, in `handleDown`/`handleUp`, and again inside `.onChange(of: filteredPrompts.map(\.id))` (`:732`) — several full O(n log n) localized-comparison passes per body evaluation.

`@Query(sort: \PromptEntry.title)` also fetches the whole table and filters in memory; the search predicate is never pushed into SwiftData.

For a keyboard-first tool whose value proposition is instant retrieval, this will feel sluggish somewhere in the low thousands of entries. Memoize the filtered list against `(searchText, viewMode, storeRevision)`, or move the predicate into the `@Query`.

---

## 6. Product and UX gaps

### S1 — `isDangerous` is stored, exported, and editable but never displayed — **Medium**

The field exists on the model (`CommandEntry.swift:17`), round-trips through export and import, and has a "Dangerous command" toggle in the editor (`ContentView.swift:1337`). It appears **nowhere** in `CommandRowView` (`:866-910`), and `copyCommand` (`:967-973`) does not consult it.

So: the user explicitly flags a command as dangerous, and the app's response is to let them copy it to the clipboard with a single Return keypress, hide itself, and show no indication whatsoever. For a tool whose entire purpose is one-keystroke retrieval of shell commands, a dead safety flag is worse than no flag — the user believes they have marked it.

**Fix (should ship in 1.0):** at minimum a visible badge in the row. Ideally a confirmation step, or a distinct visual treatment on the selected row, before Return copies a flagged command.

### S2 — No global hotkey to summon the app — **Medium (product)**

The app hides itself aggressively — Escape calls `NSApp.hide(nil)` (`:527-530`) and a successful Return-to-copy does the same (`:556-564`). There is no registered global shortcut and no menu-bar item, so the only way back is the Dock or ⌘-Tab.

For something described as *"reduce the number of decisions, clicks, and context switches required to retrieve a known prompt"*, the summon path is the single highest-leverage missing feature. Consider `MASShortcut`-style global hotkey registration or an `NSStatusItem`. Worth deciding before 1.0 because it affects whether the app should be `LSUIElement`.

### S3 — Accessibility gaps in the editors — **Low**

The `TextEditor` fields in `PromptEditorView` (`:834`) and `CommandEditorView` (`:1326`, `:1329`) have no labels. VoiceOver announces an unlabelled text area; the Commands editor has two adjacent unlabelled ones (command and explanation) with nothing to distinguish them. The row buttons are correctly labelled, so the pattern is already established — just extend it.

### S4 — `ModelContainer` failure is `fatalError` — **Medium**

```swift
fatalError("Could not create ModelContainer: \(error)")
```
`PromptdeckApp.swift:10`. A corrupted or migration-failed store means the app crashes on launch, permanently, with no message and no recovery.

This is particularly unfortunate in an app that ships a backup system: the one situation where the user most needs the restore path is the one situation where they cannot reach it. Catch the error, show an alert explaining the store could not be opened, and offer "Import from Backup…" into a fresh store.

### S5 — Deleted entries have no undo, and the alert says so — **Low**

`confirmDelete` calls `modelContext.delete` (`:581`) behind a "This cannot be undone" alert. That is honest, but with the backup engine already in place, a scheduled backup 30 seconds after the deletion means the pre-delete state may exist in a snapshot — and D2 means the user cannot get at it. Fixing D2 largely fixes this.

### S6 — `disable()` is not `@MainActor` while `cleanupFailedSetup()` is — **Low**

`AutomaticBackupService.swift:294` vs `:579`. Two functions doing near-identical teardown with different isolation. Cosmetic, but it is the kind of inconsistency that hides R1-class bugs. Align them.

---

## 7. Quality and process

### Q1 — No test target — **Medium**

`project.pbxproj` contains exactly one `PBXNativeTarget`, of type `com.apple.product-type.application`. There is no unit-test bundle and no XCTest dependency anywhere.

Roughly 1,500 lines of this codebase is cryptography, binary container parsing, filename-grammar validation, and retention logic — code whose correctness is not observable by using the app, and whose failure modes are silent data loss. The `isManagedSnapshot` filename grammar alone (regex plus strict formatter round-trip, `:353-434`) is intricate enough to deserve tests on its own.

Highest-value tests, roughly in order:

1. `seal` → `open` round-trip; wrong passphrase; each single-byte mutation of magic / version / headerLen / header / ciphertext / tag must fail as `decryptionFailed` or `invalidArchive`
2. Truncated and oversized archives; malformed inner length framing
3. `isManagedSnapshot` — accept the exact grammar, reject `2026-02-31`, reject directories, reject symlinks, reject files with the right name but wrong magic, reject the `-0`/`-1`/`-01` suffix forms
4. `enforceRetention` — never deletes the just-written file, never deletes unmanaged files, correct count retained
5. `lastSuccessfulSnapshotExists` — reject `../`, absolute paths, embedded NUL, empty, `.`, `..`
6. `BackupFingerprint` determinism — identical content at different `exportedAt` values must hash identically; DTO ordering must not matter
7. `prepareImport` validation matrix — version, library name, timestamp mismatch, duplicate IDs, invalid platform

These are all pure functions over `Data` and `URL`. A test target is a couple of hours of setup and would meaningfully de-risk the launch.

### Q2 — No logging — **Low**

Nothing uses `os.Logger`. When a user reports "backups stopped working", there is no record beyond a single `lastErrorMessage` string in `UserDefaults`. A privacy-safe `Logger(subsystem:category:)` recording backup outcomes, durations, and retention decisions — never content, never the passphrase, never a hash — would pay for itself the first time you have to debug a report from someone else's Mac.

### Q3 — Documentation drift — **Informational**

The doc comments are unusually thorough and were clearly maintained alongside the code, which is a real asset. Two spots have drifted:

- `AutomaticBackupScheduler.swift:74-78` describes `startLifecycle()` being called on "reactivation, window reappearance, Settings" — the only call site is `PromptdeckApp.init` (`PromptdeckApp.swift:19`).
- `BackupSettingsView.swift:9-10` says *"there is no scheduling, timer, or launch catch-up here"* — accurate for that file, but the sentence reads as if it describes the app.
- `ImportService.swift:298` has a `_ = mainContext` to silence an unused-parameter warning for a parameter kept only to "document intent". Either use it or drop it.

---

## 8. Suggested sequencing

**Before you can ship at all:**
1. C1 — real Developer ID signing; verify `get-task-allow` is gone with `codesign -d --entitlements -`
2. C2 — notarize and staple; verify on a machine that has never seen the app
3. D1 — confirmation + passphrase reveal before disabling backup

**Before you should ship:**
4. D2 — restore UI in Settings
5. P1 + R4 together — move crypto and I/O off the main thread, atomically
6. D3 — generational retention
7. S1 — surface `isDangerous`
8. X1 — clamp header iterations
9. R3 — save the context before scheduling a backup

**Shortly after:**
10. C3 — declare the `.promptdeck` type, add a document icon
11. R1, R2 — `@MainActor` the config store; add the reentrancy guard
12. D4 — retry backoff and warning re-arm
13. R5 — non-trapping dictionary construction, `@Attribute(.unique)`
14. Q1 — test target covering the codec and the filename grammar
15. R6 — window-scoped focus handling
16. C4 — a real `.gitignore`

**Considered and deliberately deferred:** S2 (global hotkey) is the biggest product win here, but it is a feature rather than a fix and it changes the app's activation model — better as 1.1 than as a late addition to 1.0.

---

## Appendix: verification performed

- Read all 14 Swift sources in full (4,000 lines).
- Read `project.pbxproj` build configurations in full.
- Built the Release configuration: `** BUILD SUCCEEDED **`, zero compiler warnings under Swift 6 language mode.
- Inspected the built artifact with `codesign -dvvv` and `codesign -d --entitlements -` (confirmed adhoc signature, no team identifier, `get-task-allow` present).
- Inspected the generated `Info.plist` with `plutil -p` (confirmed no document-type or exported-UTI declarations).
- Confirmed via `grep`: no test target, no `@Attribute(.unique)`, no `modelContext.save()` in any UI path, no occurrence of "restore", `isDangerous` absent from `CommandRowView`, and the exact set of seven `contentDidChange()` call sites.

No files were modified. Nothing was committed or pushed.
