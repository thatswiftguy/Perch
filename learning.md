# Learning Perch

A guided read of this codebase, written for an iOS developer who is comfortable with Swift
and SwiftUI but has not shipped a macOS app.

Perch is ~3,500 lines across 37 Swift files. That is small enough to read completely, and
this document is a map for doing exactly that: what each piece does, why it exists, and
what decision it encodes. Nearly every non-obvious line in this project is non-obvious for
a reason, and the reasons are the interesting part.

**How to use this:** read a section, then open the file it names and read the real code.
The code carries the same reasoning in comments — this doc is the connective tissue between
files, plus the macOS background you don't have yet.

---

## 0. Sixty-second summary

Perch is a macOS **menu bar app** that watches every Claude Code session running on your
machine and tells you, at a glance, whether each one is *working*, *finished*, or *blocked
waiting for you*. It optionally draws a **notch island** — a black pill hanging under the
MacBook camera cutout.

It does this by joining three independent data sources, installing seven **hooks** into
Claude Code's `settings.json` so it gets told what is happening, and reading Claude's own
transcript files for token counts.

```
Claude Code session
   ├─ writes ~/.claude/sessions/<pid>.json   ──► "which sessions exist"
   ├─ fires hooks ──► perch-hook ──► spool   ──► "what is each one doing"
   └─ appends <session-id>.jsonl             ──► "how full is the context"
                                                        │
                        SessionStore (polls, merges, diffs)
                                                        │
                        ┌───────────────┬────────────────┐
                    menu bar        popover         notch island
```

---

## 1. The problem statement is the architecture

Start here, because every design decision downstream falls out of one fact:

> **Nothing on disk distinguishes a session that is busy running tests from a session that
> has been sitting on a permission prompt for ten minutes.**

A permission prompt writes nothing to the transcript. The process is alive either way. The
files are byte-for-byte identical. So the single most valuable thing this app could tell
you is the one thing it cannot learn by reading files.

The only mechanism that exposes it is Claude Code's **hook system** — user-configured shell
commands that Claude runs at defined lifecycle points. That is why the app asks to modify
your `settings.json`; not as a convenience, but because without it the central feature does
not exist.

That gives the **three-authorities rule**, which is the architectural spine:

| Question | Authority | Why that one |
|---|---|---|
| Which sessions exist? | `~/.claude/sessions/<pid>.json` registry | Survives Perch being closed, crashed, or never installed. A session cannot run without a record. |
| What is each doing? | Hook events | The only source that can see "blocked". |
| How full is the context? | The `.jsonl` transcript | The only local source of token counts at all. |

Each source is authoritative for **exactly one question** and never overruled on it. When
they conflict, you don't arbitrate — you already decided who wins. Concretely:
`SessionStore.refresh()` deletes runtime state for any session missing from the registry,
even if that session's `SessionEnd` hook never fired. Existence is not the hooks' business.

**Transferable idea:** when you merge multiple unreliable sources, assign each one a single
question it owns. The alternative — "whichever updated most recently wins" — produces bugs
you cannot reason about.

---

## 2. Map of the repo

```
PerchCore/       11 files  Pure logic. No SwiftUI, no AppKit. The only tested target.
Perch/           17 files  The menu bar app: SwiftUI views + AppKit windowing.
  Notch/          9 files  The island. All the hard macOS code lives here.
  Views/          4 files  Popover, row, settings, menu bar label.
perch-hook/       2 files  Tiny CLI invoked by Claude Code on every hook.
PerchCoreTests/   5 files  50 tests, all against PerchCore.
Config/                    xcconfig-based signing indirection.
Scripts/                   release.sh (notarise), generate-project.py (regenerate pbxproj).
```

The split you should internalise: **`PerchCore` contains everything that can be wrong, and
nothing that can be seen.** Anything with a right answer — state transitions, token math,
JSON merging, time formatting, "should the island be visible" — lives there and has tests.
The `Perch` target is pixels and windows, and is verified by looking at it.

---

## 3. Four targets, and why a static library

| Target | Product | Role |
|---|---|---|
| `PerchCore` | `libPerchCore.a` | Static library. Logic. |
| `perch-hook` | `perch-hook` | Command-line tool. Embedded into the app bundle. |
| `Perch` | `Perch.app` | The app. Owns Info.plist, entitlements, icon, signing. |
| `PerchCoreTests` | `.xctest` | Tests, run by the shared `Perch` scheme. |

Two things here are new if you've only done iOS:

**A command-line tool target inside an app.** `perch-hook` is a plain executable — no
bundle, no Info.plist, just a binary with a `main.swift`. It's copied into
`Perch.app/Contents/MacOS/` by a Copy Files build phase (`dstSubfolderSpec = 6`, the
"Executables" destination). A macOS `.app` is just a directory, so shipping helper binaries
inside it is normal and they inherit the app's code signature.

**Static library, not a framework.** iOS habit says "shared code → framework". Here that
would be wrong: `perch-hook` is launched directly by Claude Code as a bare executable path.
A dynamic framework would need `@rpath` set up correctly for a process launched from
arbitrary contexts. Static linking bakes the code into both binaries — the helper is one
self-contained file that runs no matter who invokes it. Cost: the code exists twice on disk.
Perch's core is tiny, so who cares.

---

## 4. The write side — `perch-hook`

**File:** [perch-hook/main.swift](perch-hook/main.swift)

Claude Code runs this on every hook fire: `perch-hook PreToolUse`, with the JSON payload on
stdin. It stamps the payload with a timestamp, appends one line to a spool file, and exits.
That's the entire hot path.

### `main.swift` is special

A file literally named `main.swift` allows **top-level executable code** — statements
outside any function, run in order at launch. It is the only Swift file allowed to do that.
This is why the file reads like a script.

### Two rules govern everything in it

```swift
func finish() -> Never { exit(0) }
```

1. **Be fast.** This runs inside the user's session on every single tool call. No network,
   no work beyond decoding the payload.
2. **Never fail loudly.** Every path exits 0. A monitoring tool that breaks the thing it
   monitors is worse than no monitoring tool. Every `guard` failure funnels into `finish()`.

Notice that `--doctor` / `--install` / `--uninstall` are handled first as subcommands, so
the same binary is both the hook and the headless setup CLI. One binary, three jobs, no
extra target.

### Writing the line safely — POSIX, not `FileManager`

```swift
let fd = open(Paths.spool.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
guard flock(fd, LOCK_EX) == 0 else { finish() }
defer { flock(fd, LOCK_UN) }
```

Why raw file descriptors instead of `FileHandle`/`Data.write`? Because multiple Claude Code
sessions fire hooks **concurrently**, and this file must never contain a half-line.

- `O_APPEND` makes each `write()` seek-to-end atomically, so two processes can't overwrite
  each other's offsets.
- But `O_APPEND` only guarantees *atomicity of the write itself* for payloads under
  `PIPE_BUF`. A hook payload with a long tool input easily exceeds that, and the kernel may
  split the write — letting another process interleave in the middle.
- `flock(LOCK_EX)` is an advisory whole-file lock. It's what actually makes "one event per
  line" true. Every writer takes it; the write and the rotation both happen inside it.

**Concept worth keeping:** `O_APPEND` gives you ordering; the lock gives you atomicity.
They are not the same guarantee, and the difference only shows up under load with big
payloads — i.e. in production, not in testing.

### Rotation, done under the same lock

```swift
if size > maxSpoolBytes {            // 8 MB
    // read the last 2 MB, drop its leading partial line,
    _ = tail.withUnsafeBytes { pwrite(fd, $0.baseAddress, tail.count, 0) }
    ftruncate(fd, off_t(tail.count))
    lseek(fd, 0, SEEK_END)
}
```

Keeping the tail rather than truncating to zero matters because **the app replays the spool
at launch to rebuild state**. Throwing away all history would mean every session shows
"unknown" after a restart.

Three syscalls you probably haven't used:
- `pwrite(fd, buf, n, 0)` — write at an explicit offset without moving the file position.
  Needed because the fd is `O_APPEND`; a normal `write` would go to the end.
- `ftruncate(fd, n)` — set the file length, discarding the rest.
- `lseek(fd, 0, SEEK_END)` — restore the position afterwards.

### NDJSON

The spool is newline-delimited JSON: one complete JSON object per line. It's the standard
format for append-only event logs because appending needs no knowledge of what came before
(unlike a JSON array, which would require rewriting the closing bracket). Note the explicit
newline — `JSONEncoder` emits none:

```swift
line.append(0x0A)
```

### Why a file and not an XPC connection or a socket

**Hooks fire whether or not Perch is running.** A socket needs a listener; a file does not.
The file also doubles as the crash-recovery log and as the thing `--doctor` prints. This is
the single most load-bearing "boring choice" in the project.

---

## 5. The read side — `EventSpool`

**File:** [Perch/EventSpool.swift](Perch/EventSpool.swift)

51 lines that do a surprising amount. It's an incremental tail reader: each `drain()`
returns only what was appended since the last call.

```swift
private var offset: UInt64 = 0
private var partial = Data()
```

Four problems it solves, each in a couple of lines:

**1. Don't re-read the whole file.** Keep a byte `offset`, `stat` the file, and read only
`offset..<size`. A `stat` plus a short read four times a second is nothing.

**2. Rotation.** If `size < offset`, the helper rotated the file. Reset to zero and re-read
— what remains is recent tail, so re-reading is correct, just slightly redundant.

**3. Torn lines.** A read can land mid-line because the writer is a different process. The
reader holds the trailing bytes in `partial` until the newline arrives:

```swift
if buffer.last != 0x0A, let lastNewline = buffer.lastIndex(of: 0x0A) {
    partial = buffer[buffer.index(after: lastNewline)...]
    buffer  = buffer[..<buffer.index(after: lastNewline)]
}
```

**4. Out-of-order events.** This one is subtle and worth internalising. The hooks are
registered `async` (fire-and-forget, so they never add latency to a session). That means
the *helper processes* can finish in a different order than Claude fired them — a
`PostToolUse` landing after the next `PreToolUse` would rewind the state machine and make
the UI flicker. Each event carries the time its hook **ran**, so:

```swift
return HookEvent.decodeAll(from: buffer).sorted { $0.ts < $1.ts }
```

**Transferable idea:** the moment you make anything async for latency, you have bought
yourself a reordering problem. Timestamp at the source and sort at the sink.

### Why polling instead of a file watcher

macOS gives you `DispatchSource.makeFileSystemObjectSource` (vnode watching). It was
rejected deliberately: the file is rotated in place, so a watcher would still have to
handle truncation, replacement and re-creation, and would need re-arming after each. A
`stat` + delta read on a timer is less machinery for the same result. **Polling is not
automatically the lazy choice** — here it's the one with fewer failure modes.

---

## 6. `PerchCore` — the logic layer

### 6.1 `JSONValue` — decoding data you don't control

**File:** [PerchCore/JSONValue.swift](PerchCore/JSONValue.swift)

An enum that models any JSON value:

```swift
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String), number(Double), bool(Bool)
    case object([String: JSONValue]), array([JSONValue]), null
}
```

`init(from:)` uses a `singleValueContainer` and tries each case in turn — bool before
number matters, because `JSONDecoder` will happily decode `true` as a number in some
configurations, and number before string because a quoted numeral should stay a string.

**Why not a `struct HookPayload: Codable`?** Because Claude Code owns that schema and adds
fields between releases. A strict struct throws the moment an unknown key appears in a
non-optional position, or silently drops data you later need. The tree decodes anything,
carries unknown fields along harmlessly, and re-encodes losslessly. There's a test for
exactly this (`unknownFieldsInAPayloadAreHarmless`).

Typed access is then a set of computed properties (`stringValue`, `intValue`, `subscript`)
so call sites read like `payload["tool_input"]?["command"]?.stringValue`.

The last accessor is a nice example of absorbing real-world messiness in one place:

```swift
/// `model` arrives as a bare string on some events and as {id, display_name} on others.
public var displayString: String? { ... }
```

**Transferable idea:** for external schemas you don't own, decode permissively into a tree
and project typed views out of it. Reserve strict `Codable` structs for schemas you control.

### 6.2 `HookEvent` — the wire format

**File:** [PerchCore/HookEvent.swift](PerchCore/HookEvent.swift)

```swift
public struct HookEvent: Codable, Sendable {
    public let ts: Double
    public let event: HookKind
    public let payload: [String: JSONValue]
}
```

`HookKind` is a `String`-backed `CaseIterable` enum of the seven subscribed events. Claude
Code exposes roughly 31; these seven are the minimum that pins down every state in
`SessionState`. `CaseIterable` is what lets install/uninstall/verify all iterate the same
list — add a case and every one of them picks it up.

Everything else in the file is computed accessors over the payload tree. Two carry real
design weight:

- `isSubagent` — set when the event came from inside a `Task` sub-agent. Used to ignore
  sub-agent tool churn so one `Task` call doesn't look like a storm of activity.
- `toolDetail` — walks a candidate key list (`command`, `file_path`, `path`, `pattern`,
  `url`, `prompt`) to produce one human-readable gloss of what a tool is doing, and flattens
  newlines so it can't break a single-line layout. Returns `nil` rather than something
  useless when nothing fits.

`decodeAll(from:)` splits on `0x0A` and uses `compactMap { try? ... }` — deliberately
lenient. A truncated line, or one written by an older build, costs you one event rather
than the whole history.

### 6.3 `SessionState` + `SessionRuntime` — the state machine

**File:** [PerchCore/SessionState.swift](PerchCore/SessionState.swift)

This is the heart of the app. Four states:

```swift
public enum SessionState: Equatable, Sendable {
    case unknown                                          // seen in registry, no events yet
    case working(tool: String?, detail: String?, since: Date)
    case needsInput(NeedsInputReason, since: Date)
    case idle(lastMessage: String?, since: Date)
}
```

`unknown` is not a failure state — it's the honest answer when Perch launched mid-session
or hooks aren't installed. The UI renders it as "Running · no activity seen yet". Modelling
"I don't know" explicitly, instead of defaulting to `idle`, keeps a lie out of the UI.

`rank` gives sort weight and badge priority:

```swift
case .needsInput: 0   // blocked on the human — the only state costing you time
case .working:    1
case .unknown:    2
case .idle:       3
```

That single property drives the session list sort, the menu bar glyph, the island's choice
of primary session, and the badge colour. One definition of "urgent", used everywhere.

The reducer is `SessionRuntime.apply(_:)` — a `mutating func` folding one event into state.
The interesting transitions:

```swift
case .preToolUse:
    turnToolCount += 1
    state = .working(tool: event.toolName, detail: event.toolDetail, since: at)

case .postToolUse:
    // Between tools Claude is thinking, not idle. Keep the TURN's start time so the
    // elapsed counter tracks the turn rather than resetting on every tool.
    state = .working(tool: nil, detail: nil, since: turnStart ?? at)
```

That `turnStart ?? at` is a one-line UX fix: without it the "elapsed" counter resets to 0s
every few seconds and you can never tell how long a task has actually been running.

```swift
if event.isSubagent { return }   // ...but after lastActivity was already updated
```

Read the order carefully. Sub-agent events still count as *activity* (they update
`lastActivity`, which affects sorting), but do not touch *state*. Two tests pin both halves.

`case .sessionEnd: break` — with a comment: "removal is the registry's job, not ours". The
three-authorities rule, enforced at the line level.

### 6.4 `SessionRecord` + `Proc.startTime` — process liveness done right

**File:** [PerchCore/SessionRecord.swift](PerchCore/SessionRecord.swift)

This file contains the two best war stories in the codebase.

**War story 1: the timezone bug.** The registry record contains a `procStart` string —
literally the output of `ps -o lstart=` as captured by the Claude Code process. It looks
like the obvious way to verify the process. It is a trap: that string is rendered in *that
process's* timezone (observed as UTC for desktop-launched sessions), while a `ps` you run
locally renders local time. String-comparing them marks **every** session dead. The record's
`startedAt` is an unambiguous epoch, so that is what's compared.

**War story 2: PID recycling.** A naïve `kill(pid, 0)` tells you "some process with this PID
exists" — and PIDs get recycled. After a reboot or heavy churn, an unrelated process
inherits the number and your dead session appears alive forever.

The fix asks the kernel directly:

```swift
public static func startTime(_ pid: Int32) -> Date? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    ...
}
```

`sysctl` is the BSD kernel-parameter interface: you describe what you want as a "MIB"
(management information base) — an array of integers naming a path through the kernel's
parameter tree — and it fills a struct. Here: kernel → process table → by PID.

The killer detail, and the reason the comment exists: **for a dead PID, `sysctl` still
returns 0.** It just writes nothing. So `size > 0` — not the return code — is what actually
detects absence. This is a classic C-API trap and exactly the kind of thing that would
otherwise cost you an afternoon.

Then identity is confirmed by correlating the kernel's start time with the record's
registration time:

```swift
let delay = registeredAt.timeIntervalSince(started)
return delay >= -5 && delay <= 120
```

Registration happens 0.5–0.9s after launch (measured). A recycled PID would have to have
launched inside that window to fool this. Not cryptographic, but cheap and correct in
practice. `-5` tolerates clock skew between processes.

**Transferable idea:** a PID is not an identity, it's a slot number. Identity is
(PID, start time). The same applies to any handle that can be reused — file descriptors,
row IDs after a table truncate, reused view cells.

[PerchCore/SessionRegistry.swift](PerchCore/SessionRegistry.swift) wraps this: read the
directory, skip non-`.json` siblings, decode leniently, filter to `kind == "interactive"`
(no daemons — nothing a human is waiting on), and filter by `isAlive()`.

### 6.5 `TranscriptStats` — reading a huge file cheaply and correctly

**File:** [PerchCore/TranscriptStats.swift](PerchCore/TranscriptStats.swift)

Transcripts are append-only `.jsonl` files that grow to megabytes. We only need the most
recent `assistant` line. So:

```swift
private static let tailBytes: UInt64 = 512 * 1024
private static let maxLinesScanned = 60

let start = size > tailBytes ? size - tailBytes : 0
try? handle.seek(toOffset: start)
...
if start > 0, !lines.isEmpty { lines.removeFirst() }   // the slice cut a record in half
for line in lines.suffix(maxLinesScanned).reversed() { ... }
```

Seek to the last 512 KB, drop the certainly-broken first line, scan backwards through at
most 60 lines, stop at the first `assistant` entry. Bounded work regardless of file size —
and it's called from a background task because it touches the filesystem.

**The token math is the part that's easy to get wrong:**

```swift
let fresh   = usage["input_tokens"]?.intValue ?? 0
let written = usage["cache_creation_input_tokens"]?.intValue ?? 0
let read    = usage["cache_read_input_tokens"]?.intValue ?? 0
let context = fresh + written + read
```

A turn resuming from prompt cache reports `input_tokens` of about **2**, with everything
else under the cache keys. Summing only `input_tokens` shows an empty context window on a
session that is nearly full. Cached tokens are still occupying the window. There's also a
`usage.iterations[]` array that repeats the same numbers per internal iteration — including
it multiplies the count, so it's deliberately ignored. Both behaviours have tests.

**Context window inference.** The transcript does not record the window size. A verified
1M-context session logs `"model": "claude-opus-5"` — identical to a 200k one, no `betas`
field, nothing. So:

```swift
if model?.contains("[1m]") ?? false { return 1_000_000 }
return context > 200_000 ? 1_000_000 : 200_000
```

If a session is holding more than 200k tokens it is definitionally not on the 200k model.
This under-reports a long-context session until it crosses 200k, then self-corrects. The
`[1m]` check runs first because other surfaces do tag the id.

**Transferable idea:** when a needed fact isn't recorded, look for a value that constrains
it. And then write the limitation down — in the code, the README, and the tests — instead
of pretending the inference is a measurement.

Also note `gitBranch` comes from here. Not the registry, not the hooks — it's carried on
every transcript line and nowhere else. Finding which source has a field is half of
integration work.

### 6.6 `HookInstaller` — editing someone else's config file

**File:** [PerchCore/HookInstaller.swift](PerchCore/HookInstaller.swift)

This is the file to study if you want to learn defensive file handling. `settings.json`
belongs to the user, may be hand-written, may contain their own hooks, and may be symlinked
into a dotfiles repo. Every operation is a read-modify-write that preserves everything it
doesn't recognise.

**Identity by marker.** Perch's entries are recognised by the string `perch-hook` appearing
in the command. That makes uninstall *exact* rather than best-effort — it can remove its own
entries from a group that also contains yours, and it does:

```swift
private func stripPerch(from groups: [JSONValue]) -> [JSONValue] {
    groups.compactMap { group -> JSONValue? in
        let kept = hooks.filter { !($0["command"]?.stringValue?.contains(marker) ?? false) }
        if kept.isEmpty { return nil }        // drop groups that were entirely ours
        fields["hooks"] = .array(kept)        // keep the user's entries in shared groups
        return .object(fields)
    }
}
```

**Install is idempotent** because it strips first, then appends. Re-installing after moving
the app replaces the stale path instead of stacking a second copy.

**`isStale()`** exists for one specific real-world event: you build Perch in DerivedData,
run it, then drag it to `/Applications`. The hooks still point at the old path, silently
stop reporting, and the app looks broken. `isStale()` detects it and the popover offers
"Re-install".

**Uninstall leaves no scaffolding.** If removing our entries empties an event's array, the
key is deleted; if that empties `hooks`, that key is deleted too. The goal is a file
byte-comparable to how it was found, and there is a round-trip test asserting exactly that.

**Three things in `save()` that are each a bug someone hit:**

```swift
// 1. One backup, before the first modification, never overwritten afterwards.
if fileExists(settings), !fileExists(backup) { copyItem(settings, backup) }

// 2. Resolve symlinks BEFORE writing.
let target = settingsURL.resolvingSymlinksInPath()

// 3. Create the directory — Claude Code installed but never run means no ~/.claude yet.
try? createDirectory(at: target.deletingLastPathComponent(), ...)

try data.write(to: target, options: .atomic)
```

Number 2 deserves a paragraph, because it's a genuine footgun. **An atomic write replaces
the path with a fresh file.** `Data.write(options: .atomic)` writes to a temp file and
`rename()`s it over the destination. If the destination is a symlink, you have just replaced
the symlink with a regular file and silently detached the user's dotfiles repo. Resolving
first makes the write land on the real file. There is a test that creates a symlink, installs
through it, and asserts the link still exists afterwards.

And number 1's subtlety: the backup must be taken *once*, before the first edit. Backing up
on every write would eventually leave you with a "backup" that already contains Perch's
changes — useless. Tested.

Errors are typed (`LocalizedError`) and — critically — a malformed `settings.json` throws
*before* anything is written. A test asserts the user's garbage file is still byte-identical
after a failed install. **Refusing to act is a valid, and often correct, error behaviour.**

### 6.7 `Paths` — where things live

**File:** [PerchCore/Paths.swift](PerchCore/Paths.swift)

Small but three good decisions:

- `CLAUDE_CONFIG_DIR` is honoured. Assuming `~/.claude` would leave Perch silently showing
  nothing for anyone who relocates it. Silent wrongness is the failure mode to design against.
- Perch's own state (`~/Library/Application Support/Perch/events.ndjson`) lives **outside**
  Claude's tree, so uninstalling never touches it, and Perch never litters someone else's
  directory.
- `hookExecutable` is derived from `Bundle.main.executableURL`'s *directory*, not from the
  bundle root. That way it resolves correctly whether the caller is the app in
  `Perch.app/Contents/MacOS/`, the helper itself, or a bare binary during development —
  all three cases actually occur.

`findTranscript(sessionId:)` searches project directories for `<session-id>.jsonl` rather
than reconstructing the folder name. The folder naming scheme replaces `/` with `-`, which
is **lossy** — a directory whose own name contains `-` is ambiguous. Searching sidesteps
the ambiguity entirely.

### 6.8 `IslandPresentation` — UI logic without UI

**File:** [PerchCore/IslandPresentation.swift](PerchCore/IslandPresentation.swift)

A pure function:

```swift
static func make(sessions: [Session], isHovering: Bool, now: Date = Date()) -> IslandPresentation
```

Given the sessions, whether the pointer is nearby, and the time, decide: hidden, compact, or
expanded; what colour; which session is primary; how many others.

The governing rule is stated in the doc comment: **the default is `hidden`, and every
visible state has to justify itself.** A pill that lingers after every finished turn becomes
wallpaper, and then a genuine alert reads as more wallpaper too.

Priority: blocked → working → recently-finished (for 6 seconds) → hidden. Hovering forces
`.expanded`, and there's a test named `hoveringAQuietMachineConfirmsItIsQuiet` documenting
a regression: an early `guard sessions.isEmpty` returned before the hover check, so reaching
for the notch on an idle machine showed nothing at all, which feels broken.

**This is the pattern to steal.** Every "should this be visible / what colour / which item
wins" decision is a pure function over plain values, in a module with no UI framework
imported, with `now` injected. That's why 10 tests can cover the island's entire behaviour
without rendering a pixel. The SwiftUI layer just draws the answer.

Note where the line is drawn: `IslandPresentation.Kind` says *why* the island is visible;
`Palette.accent(for:)` in the app target turns that into a `Color`. Keeping `Color` out of
`PerchCore` is what keeps it testable and framework-free.

---

## 7. The app layer

### 7.1 `PerchApp` + `AppDelegate`

**File:** [Perch/PerchApp.swift](Perch/PerchApp.swift)

```swift
@main
struct PerchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra { PopoverView(store: delegate.store) }
        label: { MenuBarLabel(store: delegate.store) }
        .menuBarExtraStyle(.window)
    }
}
```

**`MenuBarExtra`** is a SwiftUI `Scene` (macOS 13+) that puts an item in the system menu
bar. No iOS equivalent. `.menuBarExtraStyle(.window)` makes clicking it show an arbitrary
SwiftUI view in a panel; the default `.menu` renders as a real NSMenu and cannot lay out
progress bars or multi-line rows.

Paired with `LSUIElement = true` in [Perch/Info.plist](Perch/Info.plist), which makes this
an **agent app**: no Dock icon, no app-switcher entry, menu bar only. That single plist key
is the difference between a normal app and a background utility.

**Why an `AppDelegate` in a SwiftUI app?** Startup ordering. The comment says it:
`UNUserNotificationCenter` needs a fully launched application — asking for authorization any
earlier is silently dropped and the app never even appears in System Settings ›
Notifications. `applicationDidFinishLaunching` is the earliest safe point.
`@NSApplicationDelegateAdaptor` is the bridge (same idea as iOS's `@UIApplicationDelegateAdaptor`).

Three things happen at launch worth noting:

**Snapshot mode.** If `PERCH_SNAPSHOT` is set, render the island's states to PNG and quit.
An entire alternate entry point, four lines, before anything else initialises.

**Single-instance guard.**

```swift
NSRunningApplication.runningApplications(withBundleIdentifier: id)
    .filter { $0.processIdentifier != mine.processIdentifier }
```

Launch Services prevents double-clicking an app twice, but nothing stops a copy started from
the command line or a stale DerivedData build — and two instances means two islands per
display and two notifications per event. The **older** process keeps running; the new one
steps aside. (Deciding which one dies is a real choice: killing the old one would drop its
accumulated state.)

**`applyIslandPreference()`** exists so that toggling a preference doesn't have window
side-effects as a hidden consequence of a `didSet`. Showing and hiding a window is an
explicit call. Preferences store values; the delegate performs actions.

### 7.2 `SessionStore` — the coordinator

**File:** [Perch/SessionStore.swift](Perch/SessionStore.swift)

```swift
@MainActor @Observable final class SessionStore {
    private(set) var sessions: [Session] = []
```

`@Observable` is the Swift 5.9+ macro (same on iOS 17+). SwiftUI tracks exactly which
properties a view read, so a view that only reads `needsInputCount` doesn't redraw when
`sessions` changes internally. Note the store is passed as a plain `let` to views, not
`@ObservedObject` — with `@Observable` that's all you need.

**Polling cadence, chosen per cost:**

```swift
private let pollInterval = 0.25      // spool: a stat + short read
private let sweepEveryNTicks = 4     // registry: directory scan + a sysctl per session
```

Cheap thing four times a second, expensive thing once a second. Measure, then pick a number,
then write down why — the comment says exactly which operation is expensive.

**Replay at launch, silently:**

```swift
ingest(spool.drain(), notify: false)
```

Perch rebuilds state from the spool at startup so sessions that began before it don't sit at
"unknown". But firing a burst of "finished" notifications for turns that ended hours ago is
the worst possible first impression — so replay passes `notify: false`. There's a second
guard for the same class of bug at steady state:

```swift
let isFresh = event.date.timeIntervalSinceNow > -30
if notify && isFresh { announce(...) }
```

because spool rotation makes the reader re-read the tail, so an old event can legitimately
arrive twice.

**Notifications fire on transitions, not states:**

```swift
switch (before, after) {
case (_, .needsInput(let reason, _)) where !before.isNeedsInput:
    notifier.needsInput(...)
case (.working, .idle(let message, _)):
    notifier.finished(...)
default: break
}
```

Switching on the `(before, after)` tuple is the clean way to express this. `.idle` is only
announced when arriving *from* `.working` — a session already sitting idle at launch stays
quiet. And `needsInput` requires that we weren't already blocked, so repeated notifications
during one prompt are suppressed.

**Registry sweep enforces the ownership rule:**

```swift
runtimes = runtimes.filter { live.contains($0.key) }
stats    = stats.filter    { live.contains($0.key) }
```

**Diffing before assignment:**

```swift
if rebuilt != sessions { sessions = rebuilt }
```

`rebuild()` runs four times a second. Without this guard, every tick invalidates the views
and redraws the popover for nothing. This is why `Session`, `SessionRecord`, `SessionRuntime`,
`SessionState` and `TranscriptStats.Snapshot` are all `Equatable` — the conformances exist to
make this one line possible. **Value types + `Equatable` + assign-on-change is the cheapest
render optimisation available in SwiftUI, and it's free if you designed for it.**

**Keeping I/O off the main actor:**

```swift
Task.detached(priority: .utility) {
    let snapshot = TranscriptStats.read(path: path)   // filesystem
    await MainActor.run { self.stats[sid] = snapshot; self.rebuild() }
}
```

Plus an in-flight set (`statsInFlight`) so a burst of `PostToolUse` events doesn't launch ten
concurrent reads of the same file. `Task.detached` is used rather than plain `Task` precisely
because the class is `@MainActor`-isolated — a plain `Task` would inherit that isolation and
run the file read on the main actor, defeating the point.

### 7.3 `Notifier`, `Preferences`, `Log`

**[Perch/Notifier.swift](Perch/Notifier.swift)** — `UNUserNotificationCenter` works the same
as on iOS, with one macOS-specific landmine handled up front:

```swift
guard Bundle.main.bundleIdentifier != nil else {
    authorizationError = "Run Perch from the built .app bundle, not the raw binary."
    return
}
```

The framework **traps** (crashes) rather than returning an error when the running binary
isn't a signed bundle — which is exactly what happens if you run the executable directly
during development. Guard before touching it at all.

Also note failures are logged rather than swallowed: "a silent failure here means the user
stops being told their sessions need them, which is the app's whole job".

**[Perch/Preferences.swift](Perch/Preferences.swift)** — `UserDefaults`-backed toggles with
`didSet` persistence. The interesting part is a timing bug, captured:

```swift
func resolveDefaults() {   // must run AFTER didFinishLaunching
    showNotchIsland = NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
}
```

`Preferences` is constructed while the app delegate is constructed, which is early enough
that **`NSScreen.screens` is still empty**. Reading it there silently concludes the Mac has
no notch and leaves the island permanently off. So first-run defaulting is a separate method
called at the right moment. `islandNeedsDefault` distinguishes "never set" from "set to
false" — `UserDefaults.bool(forKey:)` returns `false` for a missing key, so the code reads
`object(forKey:) as? Bool` and checks for `nil`. That distinction matters any time a default
isn't `false`.

**[Perch/Log.swift](Perch/Log.swift)** — 17 lines. stderr, errors always, verbose trace only
under `PERCH_DEBUG=1`. Note `@autoclosure` on the debug message so string interpolation isn't
performed when debug logging is off:

```swift
static func debug(_ message: @autoclosure () -> String) {
    guard isDebug else { return }
    write(message())
}
```

### 7.4 The views

**[Perch/Views/MenuBarLabel.swift](Perch/Views/MenuBarLabel.swift)** — 30 lines, and a good
exercise in constraint: it has room for one glyph and one number, so it answers exactly one
question — *does anything need me right now?* Blocked count beats working count, orange beats
primary, filled bird beats outline.

**[Perch/Views/SessionRow.swift](Perch/Views/SessionRow.swift)** — note:

```swift
TimelineView(.periodic(from: .now, by: 1)) { context in ... }
```

`TimelineView` re-renders on a schedule and hands you the current date. It's how the elapsed
counters tick without a store-level timer invalidating the whole app once a second. Scoped
to the row, so **nothing redraws when the popover is closed**. Every time-dependent view
takes `now` as a parameter rather than calling `Date()` internally — which is also what makes
the formatting functions testable.

Other details worth copying: `.monospacedDigit()` on numbers so they don't jitter as digits
change width; `.truncationMode(.middle)` for titles, `.tail` for status text;
`.contentShape(.rect)` so the whole row area is hit-testable for the context menu.

**[Perch/Views/PopoverView.swift](Perch/Views/PopoverView.swift)** — a setup banner appears
when hooks are missing or stale, because otherwise the user stares at a list that never
changes and concludes the app is broken. **When a feature can't work, say so where the
feature would be.**

**[Perch/Views/SettingsView.swift](Perch/Views/SettingsView.swift)** — introduces
`SMAppService` (macOS 13+), the modern login-item API:

```swift
try SMAppService.mainApp.register()      // launch at login
try SMAppService.mainApp.unregister()
SMAppService.mainApp.status == .enabled
```

It replaces the old `SMLoginItemSetEnabled` helper-bundle dance. The state is read back from
the system after every mutation rather than assumed, because the user can revoke it in System
Settings behind your back.

---

## 8. The notch island — the AppKit chapter

This is where macOS stops looking like iOS. Nine files in [Perch/Notch/](Perch/Notch).

### 8.1 The insight the whole design rests on

> The notch is a **physical hole**. There are no pixels behind it.

You cannot draw "in" the notch, ever. What you *can* do is draw a **pure black** body flush
against the cutout's bottom edge — and because the cutout is physically black, down the
centre the two become one continuous shape. The illusion is entirely a colour-matching trick.

Consequences that fall out of that one fact:
- The body must be `.black`, not "a dark material". Any translucency breaks the match.
- No window shadow on the attached island — a shadow would outline it against the cutout.
- Displays without a notch can't use the trick at all, hence the **detached pill** fallback,
  which *does* get a shadow and a hairline stroke so it reads as floating.

### 8.2 `NotchGeometry` — measuring the cutout

**File:** [Perch/Notch/NotchGeometry.swift](Perch/Notch/NotchGeometry.swift)

```swift
if inset > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
    notchWidth = max(0, screen.frame.width - left.width - right.width)
    centerX    = screen.frame.minX + left.width + notchWidth / 2
    topInset   = inset
}
```

`NSScreen.safeAreaInsets` exists on macOS and means the same thing as on iOS. The neat part
is `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` — the two menu bar fragments either side
of the cutout. **What's left between them is the cutout.** You measure the notch by measuring
what isn't it.

`centerX` is computed rather than taken as `frame.midX` because the two fragments differ by a
point on some panels. On screens with no notch, the menu bar height is measured as
`frame.maxY - visibleFrame.maxY`, with a 24pt fallback.

Also here — and this is a good habit — an explicitly documented tradeoff:

```swift
/// A notched display wins even when it isn't the primary one... The tradeoff is real:
/// plug in an external monitor and make it primary, and the island stays on the laptop
/// panel. Swap the two clauses to prefer the menu bar's screen instead.
```

**Fixed oversized host window:**

```swift
static let hostWidth: CGFloat = 460
static let hostHeight: CGFloat = 340
```

The window never changes size. It's big enough for the largest state the island can reach,
and only the SwiftUI content inside it resizes. **Animating an `NSWindow` frame visibly
stutters** — window server geometry changes are not on the same path as your view animations.
Make the window static and animate the content.

### 8.3 `NotchWindowController` — every NSPanel flag, explained

**File:** [Perch/Notch/NotchWindowController.swift](Perch/Notch/NotchWindowController.swift)

On iOS you get one window and the system owns it. On macOS you create windows. `NSPanel` is
an `NSWindow` subclass for auxiliary windows.

```swift
let panel = NSPanel(contentRect: geometry.hostFrame,
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered, defer: false)
panel.level = .statusBar
panel.isOpaque = false
panel.backgroundColor = .clear
panel.hasShadow = false
panel.ignoresMouseEvents = true
panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
panel.isMovable = false
panel.hidesOnDeactivate = false
panel.isReleasedWhenClosed = false
```

| Setting | Why |
|---|---|
| `.borderless` | No title bar or chrome — we draw the entire appearance. |
| `.nonactivatingPanel` | Showing the island must not bring Perch to the foreground. |
| `level = .statusBar` | Window levels order the z-stack. Above normal windows, alongside the menu bar. |
| `isOpaque = false` + clear background | The host window is mostly empty; only the island shape paints. |
| `hasShadow = false` | A shadow would outline the island and destroy the blend. |
| `ignoresMouseEvents = true` | **Fully click-through.** |
| `.canJoinAllSpaces` | Visible on every Space, not just the one it was created on. |
| `.stationary` | Doesn't slide during Space-switch animations. |
| `.fullScreenAuxiliary` | Still visible over full-screen apps. |
| `.ignoresCycle` | Skipped by Cmd-` window cycling. |
| `isReleasedWhenClosed = false` | AppKit's default is to deallocate on close; we manage lifetime ourselves. |

`ignoresMouseEvents` is the important one. The host window is 460×340 and mostly transparent.
If it swallowed clicks, it would break everything underneath it near the top of your screen.
So the island is a **display, not a control** — all interaction lives in the menu bar popover.

### 8.4 Hover without event delivery

But if the window ignores mouse events, tracking areas and mouse-moved monitors never fire.
So hover is polled:

```swift
hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
    Task { @MainActor in self.updateHover() }
}
let pointer = NSEvent.mouseLocation   // global, in screen coordinates
```

`NSEvent.mouseLocation` is a static read of the current pointer position — no event stream,
**no Accessibility permission**, and no way to interfere with another app's input. (A global
event monitor would have required permission and been far more invasive for the same result.)

**Hysteresis** is the detail that makes it feel right:

```swift
let zone = island.hover.isHovering ? expandedZone(geo) : triggerZone(geo)
```

A small zone opens the island; a much larger one keeps it open. With a single zone the
island flickers along the boundary. Plus a 180ms cancellable delay before collapsing, so
crossing a corner doesn't slam it shut mid-read:

```swift
island.collapse = Task { @MainActor [weak island] in
    try? await Task.sleep(for: .milliseconds(180))
    guard !Task.isCancelled, let island else { return }
    ...
}
```

Structured concurrency used as a debounce: hold the `Task`, cancel it if the pointer comes
back. Cleaner than a `DispatchWorkItem`, and cancellation is checked explicitly.

**Multi-display:** one island per screen, keyed by `CGDirectDisplayID` (a stable hardware
identifier pulled out of `deviceDescription`), because "status you have to go and look for on
another display isn't status". And:

```swift
@objc private func screensChanged() { hide(); show() }   // didChangeScreenParametersNotification
```

Displays connected, removed, rearranged, resolution changed — geometry *and* the set of
screens can both have moved. Rebuilding is simpler and less bug-prone than patching. **Prefer
recompute-from-scratch over incremental update when the input is small and the edge cases
are many.**

### 8.5 `NotchShape` and the bug that measuring found

**File:** [Perch/Notch/NotchShape.swift](Perch/Notch/NotchShape.swift)

A `Shape` returning either `UnevenRoundedRectangle` (small radius on top where it meets the
menu bar, generous below where it hangs free) or a fully rounded pill when detached.

The comment records a killed feature, and it's the best lesson in the file. An earlier
version cut *concave shoulders* into the top corners so the island appeared to bulge out of
the cutout — a popular effect. Measuring the rendered pixels killed it: a concave shoulder
has to dip below the menu bar's bottom edge, and **everything below that line is desktop
wallpaper**, so the curve revealed a 9pt stripe of wallpaper and read as a rendering gap.

The illusion survives without it, because black meets black down the centre anyway.

### 8.6 Layout details in `NotchIslandView`

**File:** [Perch/Notch/NotchIslandView.swift](Perch/Notch/NotchIslandView.swift)

```swift
.padding(.top, geometry.isAttached ? geometry.topInset - 0.5 : geometry.topInset + 7)
```

Attached: overlap the menu bar by a hairline so antialiasing can't leave a seam. Detached:
a deliberate 7pt gap, because with no cutout to hide behind, flush just looks welded on.

```swift
private struct IslandWidth: ViewModifier {
    if mode == .expanded { content.frame(width: IslandMetrics.expandedWidth) }
    else { content.fixedSize(horizontal: true, vertical: false).frame(minWidth: minimum) }
}
```

Two sizing strategies, and the comment explains why they differ. Compact must **hug its
content** — a `maxWidth` makes the frame greedy and stretches a three-word status across the
window. Expanded needs a **definite width** because its rows use `Spacer()` to push status to
the trailing edge, and a spacer needs something to push against.

`minimumWidth()` keeps the body wider than the cutout it hangs from, because an island
exactly as wide as the notch just reads as the notch being taller.

`NotchIslandHost` reads the store and hover state, then passes **plain values** to
`NotchIslandView`. That separation is what makes the view renderable off-screen with fake
data — see below.

### 8.7 `Palette` / `IslandMetrics` / `StateDot`

**File:** [Perch/Notch/Palette.swift](Perch/Notch/Palette.swift)

The island draws on pure black, so it can't use semantic colours (`.primary`, `.secondary`)
— those adapt to a light or dark *background material*, not to a black hole. Hence explicit
white opacities: `primary 0.93`, `secondary 0.58`, `tertiary 0.38`, `hairline 0.10`.

`IslandMetrics` centralises shared sizes so compact and expanded can't drift apart as either
is edited. `maxRows = 5`, beyond which the list is summarised, not scrolled — "the island is
a glance, not a window".

`StateDot` pulses while working, and the comment constrains it: a slow **opacity** pulse
only, nothing that changes size, because this sits in peripheral vision all day. Restraint
as an explicit design requirement.

### 8.8 `IslandSnapshot` — visual testing without a screenshot

**File:** [Perch/Notch/IslandSnapshot.swift](Perch/Notch/IslandSnapshot.swift)

This is the cleverest piece of tooling in the project.

Problem: the island can't be screenshotted from outside the app without screen-recording
permission, and its states depend on live sessions that are awkward to stage on demand.

Solution: render it off-screen to PNG, against a **fake desktop** — a wallpaper-coloured
rectangle, a translucent menu bar strip, and a black rectangle standing in for the cutout —
at nine states, in one command:

```bash
PERCH_SNAPSHOT=/tmp/shots ./build/Perch.app/Contents/MacOS/Perch && open /tmp/shots
```

`ImageRenderer` (SwiftUI, macOS 13+) rasterises any view into an `NSImage` off-screen:

```swift
let renderer = ImageRenderer(content: stage)
renderer.scale = 2                        // Retina
guard let image = renderer.nsImage,
      let tiff = image.tiffRepresentation,
      let png  = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
```

The wallpaper-gap bug in §8.5 was found this way, and no unit test would have caught it.

Two details worth stealing: `NotchGeometry(detachedLike:)` lets you review the no-notch
design on a machine that has a notch; and the stage's frame must exactly match the island's,
because a shorter stage makes SwiftUI centre the taller child and clip its top — silently
hiding the thing you're trying to look at.

Also note how fake sessions are built: `SessionRecord`'s memberwise init is internal to
`PerchCore` (it's only ever produced by decoding), so the fixtures **decode JSON** to make
one. Slightly awkward, but it keeps the production type from growing a constructor that only
tests use.

---

## 9. Swift 6 concurrency, as actually used here

The project is `SWIFT_VERSION = 6.0`, so strict concurrency checking is on. The patterns:

**1. Isolate the mutable world to the main actor.** `SessionStore`, `Notifier`,
`Preferences`, `NotchWindowController`, `HoverState`, `AppDelegate` are all `@MainActor`.
This is UI state; putting it anywhere else buys nothing.

**2. Make the values `Sendable`.** Everything crossing an isolation boundary — `Session`,
`SessionRecord`, `SessionRuntime`, `SessionState`, `HookEvent`, `JSONValue`,
`TranscriptStats.Snapshot` — is a `Sendable` value type. Because they're immutable structs
and enums of `Sendable` members, conformance is free. **Value semantics is what makes strict
concurrency painless**; a graph of reference types would fight you at every boundary.

**3. Hop deliberately for I/O.**

```swift
Task.detached(priority: .utility) {          // detached: do NOT inherit @MainActor
    let snapshot = TranscriptStats.read(path: path)
    await MainActor.run { ...update state... }
}
```

**4. Bridge legacy callbacks with a `Task`.** `Timer` and `NotificationCenter` predate
concurrency:

```swift
Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
    Task { @MainActor in self.poll() }
}
```

**5. Use `Task` as a cancellable timer.** The hover-collapse debounce in §8.4.

The general shape: **a main-actor island of mutable state, surrounded by `Sendable` values,
with explicit hops for slow work.** That is the whole model, and it's the same model you
should be using in iOS 17+ apps.

---

## 10. Testing

50 tests, all in [PerchCoreTests/](PerchCoreTests), all against `PerchCore`. They use
**Swift Testing** (`import Testing`), not XCTest:

```swift
@Suite struct FormatTests {
    @Test func elapsedNeverGoesNegative() {
        #expect(Format.elapsed(since: now.addingTimeInterval(5), now: now) == "0s")
    }

    @Test(arguments: [(0.0, "0s"), (60.0, "1m"), (7830.0, "2h 10m")])
    func elapsedReadsAsAGlance(seconds: Double, expected: String) { ... }
}
```

Differences from XCTest: free functions and plain structs (a fresh instance per test, so
`init` is your setup and there's no `tearDown` — use `deinit` or scratch dirs);
`#expect` for soft assertions and `try #require` to unwrap-or-fail; `@Test(arguments:)` for
parameterised cases; tests run **in parallel by default**, which is why every filesystem test
generates a `UUID`-named scratch directory.

**What is tested is a deliberate choice.** Four areas, each because the cost of being wrong
is high:

| Suite | Why it exists |
|---|---|
| `HookInstallerTests` (14) | It edits a file the app does not own. |
| `TranscriptStatsTests` (11) | The token math has three separate ways to be silently wrong. |
| `SessionStateTests` (10) | The state machine is the product. |
| `IslandPresentationTests` (10) | Decides whether something appears in your peripheral vision all day. |
| `FormatTests` (5) | Cheap, and off-by-ones in a glanceable UI are embarrassing. |

Read `HookInstallerTests` closely. Notice the tests are mostly not "did we add our hooks" but
**"did we leave everything else exactly as we found it"**:

- `preservesTheUsersOwnHooks`
- `uninstallRestoresTheOriginalExactly` — install, uninstall, assert deep equality with the
  original parse
- `uninstallLeavesNoEmptyScaffolding`
- `writesOneBackupBeforeTheFirstEdit` — including that a second edit doesn't clobber it
- `refusesToTouchAFileItCannotParse` — asserts the garbage file is unchanged
- `writesThroughASymlinkInsteadOfReplacingIt`
- `createsTheConfigDirectoryOnAFreshMachine`

The CONTRIBUTING rule in the README follows from this: *anything that writes to
`settings.json` needs a test proving the round-trip leaves the user's file exactly as it was
found.*

Also notice the test names are **sentences about behaviour**, not method names —
`aPermissionPromptMeansBlockedNotBusy`, `betweenToolsTheTurnClockKeepsRunning`,
`aSessionOverTwoHundredKMustBeOnTheLongContextModel`. The suite reads as a specification, and
several tests carry the comment explaining the real-world bug they pin.

Testability was designed in, not bolted on:
- `HookInstaller.init(settingsURL:executable:)` injects both, so tests hit a scratch file.
- Every time-dependent function takes `now: Date = Date()`.
- `IslandPresentation` is a pure function over plain values.

---

## 11. Build, signing, CI, release

### xcconfig indirection

**Files:** [Config/Shared.xcconfig](Config/Shared.xcconfig),
[Config/Local.xcconfig.example](Config/Local.xcconfig.example)

The problem: if you commit your team ID and `Automatic` signing, a fresh clone fails to build
for anyone without your Apple account. The solution:

```
PERCH_CODE_SIGN_STYLE = Manual
PERCH_CODE_SIGN_IDENTITY = -          // "-" means ad-hoc
PERCH_DEVELOPMENT_TEAM =

#include? "Local.xcconfig"            // the "?" makes it optional
```

The project's real build settings reference `$(PERCH_CODE_SIGN_IDENTITY)` etc. Defaults come
first so the git-ignored local file can override them — **in xcconfig, the last assignment
wins**, which is the opposite of what most people assume.

Result: a fresh clone ad-hoc signs and runs with no Apple account. Ad-hoc is enough to run on
the machine that built it, including notifications and login items. It's *not* enough to give
the app to someone else.

An `.xcconfig` is just `KEY = VALUE` lines assigned to a configuration in the project editor.
`#include?` is the optional include. This pattern is worth adopting in any repo more than one
person builds.

### Not sandboxed, and why

**File:** [Perch/Perch.entitlements](Perch/Perch.entitlements)

```xml
<key>com.apple.security.app-sandbox</key>
<false/>
```

On iOS the sandbox is mandatory and invisible. On macOS it's optional and it's a *choice*.
Perch's entire job is reading `~/.claude` and writing `settings.json`. Sandboxed, it would be
confined to its own container and see nothing — and there is no entitlement granting blanket
access to another app's support directory. Developer ID distribution permits this; the Mac
App Store would not. That's the trade, written down in the file itself.

### Notarisation

**File:** [Scripts/release.sh](Scripts/release.sh)

For anyone else to open your app, Gatekeeper wants it signed with a **Developer ID
Application** certificate and **notarised** by Apple. The script's preflight is the useful
part — it checks every prerequisite before doing five minutes of work:

1. A `Developer ID Application` certificate exists (an *Apple Development* certificate
   cannot be notarised — a genuinely confusing distinction, and it's checked explicitly with
   a helpful error).
2. `TEAM_ID` is set.
3. A stored `notarytool` keychain profile exists.

Then: `xcodebuild archive` with hardened runtime and `--timestamp` → `-exportArchive` with a
`developer-id` ExportOptions plist → `ditto -c -k --keepParent` to zip (note: **`ditto`, not
`zip`** — `zip` does not preserve the signature) → `notarytool submit --wait` → `stapler
staple` (embeds the ticket so it opens offline) → `stapler validate` + `spctl --assess` to
verify.

### CI

**File:** [.github/workflows/ci.yml](.github/workflows/ci.yml)

Two steps on `macos-15`: `xcodebuild test` and a Release `build`, both with
`CODE_SIGNING_ALLOWED=NO` (runners have no keychain identity and none is needed). The shared
scheme builds all four targets, so one command covers everything. The Release build exists to
catch what only breaks under whole-module optimisation.

Note also `.gitignore` keeps `xcuserdata/` out but **commits the shared scheme** under
`xcshareddata/` — that's what makes `-scheme Perch` work on a fresh clone and in CI.

And in `.gitattributes`:

```
*.pbxproj -text merge=union
```

Treating the machine-generated project file as binary stops git reflowing it, so merge
conflicts stay legible instead of silently corrupting the project.

### `Scripts/generate-project.py`

Regenerates `Perch.xcodeproj` from scratch by emitting pbxproj objects with MD5-derived
UUIDs. It exists as a **recovery tool** if a bad merge corrupts the project — but the README
is explicit that Xcode remains the source of truth, and you should not run it to pick up new
files, because it would discard settings changed through the UI. A rescue hatch, not a build
step.

---

## 12. Twelve ideas worth taking with you

1. **Give each data source exactly one question it owns.** Conflicts then resolve themselves.
2. **Design for the failure you can't see.** The registry stays authoritative even when hooks
   go silent, so the app degrades to "less information" rather than "wrong information".
3. **Model "I don't know" as a state.** `unknown` is why the UI never lies.
4. **Decode foreign schemas permissively.** Strict `Codable` for your data, a JSON tree for
   theirs.
5. **PID ≠ identity.** Any reusable handle needs a second field to confirm it.
6. **Read the API contract, not the return code.** `sysctl` succeeds on a dead PID; only
   `size > 0` tells the truth.
7. **Async buys reordering.** Timestamp at the source, sort at the sink.
8. **Atomic writes destroy symlinks.** Resolve first.
9. **Put presentation *logic* in a UI-free module.** Pure functions over plain values with
   `now` injected — then 10 tests cover behaviour that would otherwise need snapshot tests.
10. **`Equatable` value types + assign-on-change** is nearly free render performance in
    SwiftUI, if you design for it.
11. **Build the tool that makes the invisible visible.** `--doctor` and `PERCH_SNAPSHOT`
    together are ~150 lines and they're how the hard bugs got found. `--doctor` deliberately
    folds events through *the same* state machine the app uses, so the diagnosis can't
    disagree with the app.
12. **Write the reason down where the code is.** Nearly every comment in this project
    explains a decision or a bug, not the syntax. Six months later, that's the only reason
    anyone can safely change it.

---

## 13. Suggested reading order

Read the code in this order; each file assumes the previous ones.

1. [PerchCore/SessionState.swift](PerchCore/SessionState.swift) — the domain model.
2. [PerchCore/HookEvent.swift](PerchCore/HookEvent.swift) + [JSONValue.swift](PerchCore/JSONValue.swift) — the wire format.
3. [perch-hook/main.swift](perch-hook/main.swift) — the write side.
4. [Perch/EventSpool.swift](Perch/EventSpool.swift) — the read side.
5. [Perch/SessionStore.swift](Perch/SessionStore.swift) — where it all meets.
6. [PerchCore/SessionRecord.swift](PerchCore/SessionRecord.swift) — the sysctl story.
7. [PerchCore/HookInstaller.swift](PerchCore/HookInstaller.swift) + its tests — defensive file handling.
8. [PerchCore/TranscriptStats.swift](PerchCore/TranscriptStats.swift) — the token math.
9. [PerchCore/IslandPresentation.swift](PerchCore/IslandPresentation.swift) + its tests — UI logic without UI.
10. [Perch/Notch/](Perch/Notch) — geometry, then window controller, then views.

### Things to try

```bash
# See exactly what every layer can see, using the app's own code.
/Applications/Perch.app/Contents/MacOS/perch-hook --doctor
```

```bash
# Watch the raw event stream as the app interprets it.
PERCH_DEBUG=1 /Applications/Perch.app/Contents/MacOS/Perch
```

```bash
# Render all nine island states off-screen against a simulated notch.
PERCH_SNAPSHOT=/tmp/shots ./build/Perch.app/Contents/MacOS/Perch && open /tmp/shots
```

```bash
# Read the actual data. This is the file `SessionRecord` decodes.
cat ~/.claude/sessions/*.json | head -40
```

```bash
# And the spool the whole app is built around.
tail -3 ~/Library/Application\ Support/Perch/events.ndjson
```

### Exercises, roughly in order of difficulty

1. Add a **`PreCompact`** hook so the UI can show "compacting context". One `HookKind` case,
   one `SessionState` case or reason, one branch in `apply`. Notice how `CaseIterable` makes
   install/uninstall/verify pick it up for free — and that the installer tests will tell you
   if you missed something.
2. Make `IslandPresentation.finishedLinger` a user preference and thread it through. Watch
   how the pure-function design makes this trivial to test.
3. Add a **cost estimate** from `outputTokens` and a hardcoded price table. Then read the
   README's "Not included" section and work out why the real number isn't available locally.
4. Change `NotchGeometry.preferredScreen()` to follow the menu bar instead of the notch (the
   comment tells you exactly which two clauses to swap), then use `PERCH_SNAPSHOT` to review
   the result.
5. Hardest, and most instructive: make the app survive `~/.claude/sessions/` **not existing**
   at all, and prove it with a test. Then go back and check — it probably already does, and
   understanding *why* (every read is `try?`-guarded and returns an empty collection) is the
   point.
