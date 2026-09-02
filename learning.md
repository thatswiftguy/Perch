# Perch — technical notes

The techniques and APIs this project uses, and why. For an iOS developer moving to macOS.

**The one fact the design rests on:** nothing on disk distinguishes a Claude Code session
*busy running tests* from one *blocked on a permission prompt*. Only Claude's hook system
exposes it — hence a helper CLI, a spool file, and edits to someone else's config file.
Three sources, each authoritative for exactly one question: the registry for *which sessions
exist*, hooks for *what they're doing*, transcripts for *token counts*. Conflicts never need
arbitrating because ownership is decided up front.

---

## macOS app shape

| Thing | Why here |
|---|---|
| `LSUIElement = true` (Info.plist) | Agent app: no Dock icon, no app-switcher entry. One key turns an app into a background utility. |
| `MenuBarExtra` + `.menuBarExtraStyle(.window)` | SwiftUI scene for a menu bar item. `.window` allows arbitrary views; the default `.menu` is a real NSMenu and can't lay out progress bars. |
| `@NSApplicationDelegateAdaptor` | Needed for launch ordering: `UNUserNotificationCenter` authorization requested before `applicationDidFinishLaunching` is **silently dropped** and the app never appears in System Settings. |
| `SMAppService.mainApp.register()` | Modern launch-at-login (macOS 13+). Read `.status` back after mutating — the user can revoke it in System Settings. |
| Sandbox **off** (`com.apple.security.app-sandbox = false`) | On iOS mandatory, on macOS a choice. Sandboxed, the app would be confined to its own container and see no sessions; no entitlement grants access to another app's support dir. Legal for Developer ID, not for the App Store. |
| `NSRunningApplication.runningApplications(withBundleIdentifier:)` | Single-instance guard. Launch Services stops double-clicks, not a second copy from the CLI or a stale DerivedData build. |
| Static library, not a framework | The helper is launched by Claude Code as a bare path; a dynamic framework would need `@rpath` set up for arbitrary launch contexts. Static links the code into both binaries. |
| Copy Files phase, `dstSubfolderSpec = 6` | Embeds the helper in `Perch.app/Contents/MacOS/`. A `.app` is just a directory; helper binaries inside inherit its signature. |

## Windows and screens (AppKit)

You create windows on macOS. `NSPanel` is the auxiliary-window subclass.

```swift
NSPanel(styleMask: [.borderless, .nonactivatingPanel], ...)
panel.level = .statusBar                 // z-order alongside the menu bar
panel.isOpaque = false; panel.backgroundColor = .clear
panel.hasShadow = false                  // a shadow would outline the shape
panel.ignoresMouseEvents = true          // fully click-through
panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
panel.isReleasedWhenClosed = false       // AppKit deallocs on close by default
```

- `.nonactivatingPanel` — showing the window must not bring the app forward.
- `.canJoinAllSpaces` / `.stationary` / `.fullScreenAuxiliary` — visible on every Space and
  over full-screen apps, without sliding during Space animations.
- **Never animate an `NSWindow` frame** — it stutters. Keep the window fixed and oversized;
  animate only the SwiftUI content inside it.

**Measuring the notch.** `NSScreen.safeAreaInsets` works as on iOS, but the useful pair is
`auxiliaryTopLeftArea` / `auxiliaryTopRightArea` — the menu bar fragments either side of the
cutout. What's left between them *is* the cutout. (`NSScreen.screens` is empty during app
delegate construction — reading it there silently concludes there's no notch.)

The notch is a **physical hole**: no pixels behind it, so nothing can draw "in" it. The
illusion is pure `.black` meeting black down the centre — which is why no shadow, no
translucent material, and no concave shoulder that dips below the menu bar (that reveals
desktop wallpaper).

**Hover without event delivery.** The window ignores mouse events, so tracking areas never
fire. Poll `NSEvent.mouseLocation` on a timer instead — one static read, no Accessibility
permission, no interference with other apps. Use **asymmetric zones**: a small rect opens,
a large one keeps open, or it flickers on the boundary.

**Multi-display:** key windows by `CGDirectDisplayID` (from `deviceDescription`), and on
`NSApplication.didChangeScreenParametersNotification` tear down and rebuild rather than
patch — geometry and the set of screens can both have moved.

## POSIX / low-level

**Concurrent appends from multiple processes:**

```swift
let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
guard flock(fd, LOCK_EX) == 0 else { ... }
defer { flock(fd, LOCK_UN) }
```

`O_APPEND` gives **ordering** (atomic seek-to-end), but atomicity of the write itself only
holds under `PIPE_BUF` — a big payload can be split and interleaved. `flock` is what makes
"one line per event" actually true. Different guarantees; the gap only shows under load.

**Rewriting in place** (log rotation, keeping the tail): `pwrite(fd, buf, n, 0)` writes at an
explicit offset without moving the position (needed because the fd is `O_APPEND`),
`ftruncate` sets the length, `lseek(fd, 0, SEEK_END)` restores the position.

**Process liveness — a PID is a slot number, not an identity.** PIDs get recycled, so
`kill(pid, 0)` reports unrelated processes as alive. Ask the kernel:

```swift
var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
var info = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.stride
guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
```

`sysctl` describes what you want as a MIB (a path through the kernel's parameter tree). **The
trap: for a dead PID it still returns 0** and just writes nothing — `size > 0`, not the
return code, is what detects absence. Identity = (PID, start time), correlated against a
recorded registration time.

## File handling

- **NDJSON** for append-only logs: one JSON object per line, so appending needs no knowledge
  of what came before (a JSON array would need the closing bracket rewritten). `JSONEncoder`
  emits no newline — append `0x0A` yourself.
- **Incremental tail read:** keep a byte offset, `stat` for size, read only the delta. If
  `size < offset` the file was rotated — reset to 0. Hold trailing bytes in a `partial`
  buffer until their newline arrives, since a read can land mid-line.
- **Bounded backwards read** of a huge append-only file: seek to the last 512 KB, drop the
  certainly-truncated first line, scan back through at most N lines, stop at the first match.
  Constant work regardless of file size.
- **Atomic writes destroy symlinks.** `Data.write(options: .atomic)` writes a temp file and
  `rename()`s it over the path — replacing a symlink with a regular file. Call
  `resolvingSymlinksInPath()` first so the write lands on the real file.
- **Backup once**, before the first edit, and never overwrite it — otherwise the "backup"
  eventually contains your own changes.
- **Refusing to act is valid error handling.** Unparseable input throws *before* anything is
  written, leaving the user's file byte-identical.
- **Editing a config file you don't own:** read-modify-write preserving unrecognised keys,
  identify your own entries by a marker string (makes uninstall exact, not best-effort),
  strip-then-append so install is idempotent, and delete emptied containers so uninstall
  leaves no scaffolding.

## Codable for schemas you don't own

A strict struct throws or drops data the moment an external schema gains a field. Decode into
a permissive tree instead and project typed views out of it:

```swift
enum JSONValue: Codable, Sendable, Equatable {
    case string(String), number(Double), bool(Bool)
    case object([String: JSONValue]), array([JSONValue]), null
}
// init(from:) uses singleValueContainer() and tries each case — bool before number,
// number before string. Unknown fields ride along and re-encode losslessly.
```

Add `subscript(key:)` + `stringValue`/`intValue` so call sites read
`payload["tool_input"]?["command"]?.stringValue`. Keep bulk decoding lenient
(`compactMap { try? ... }`) so one bad line costs one record, not the whole file.

Rule of thumb: strict `Codable` for your data, a tree for theirs.

## State machines

Enums with associated payloads, plus a `mutating func apply(_ event:)` reducer.

- Model **"I don't know"** explicitly (`case unknown`) so the UI never has to lie by
  defaulting to `idle`.
- Give the enum a `rank: Int`. One definition of "urgent" then drives sorting, badge colour,
  glyph choice, and which item is featured.
- **Notify on transitions, not states** — switch on the tuple:

```swift
switch (before, after) {
case (_, .needsInput(let r, _)) where !before.isNeedsInput: notifier.needsInput(...)
case (.working, .idle(let msg, _)):                         notifier.finished(...)
default: break
}
```

- Replaying history to rebuild state must be **silent** (`notify: false`), plus a freshness
  guard (`event.date.timeIntervalSinceNow > -30`) because rotation makes old events re-arrive.
- **Async work buys reordering.** Fire-and-forget hooks finish out of order and would rewind
  the machine — timestamp at the source, sort at the sink.

## Swift 6 concurrency

The shape: **a `@MainActor` island of mutable state, surrounded by `Sendable` value types,
with explicit hops for slow work.**

```swift
Task.detached(priority: .utility) {        // detached: do NOT inherit @MainActor
    let snapshot = TranscriptStats.read(path: path)   // filesystem
    await MainActor.run { ... }
}
```

- A plain `Task` inside a `@MainActor` type **inherits** that isolation and runs your file
  I/O on the main actor. `Task.detached` is the opt-out.
- Value semantics is what makes strict concurrency painless — immutable structs/enums of
  `Sendable` members conform for free. A graph of classes fights you at every boundary.
- Bridge legacy callbacks: `Timer.scheduledTimer { _ in Task { @MainActor in ... } }`.
- A stored `Task` + `Task.sleep` + `cancel()` is a clean debounce (used for hover collapse).
- Keep an in-flight `Set` so a burst of events doesn't launch N concurrent reads of one file.

## SwiftUI

- `@Observable` (macro, not `ObservableObject`): SwiftUI tracks which properties a view
  actually read, so a view reading only a count doesn't redraw when a list mutates. Pass the
  store as a plain `let`.
- **Assign-on-change diffing** — nearly free render performance if you designed for it:

```swift
if rebuilt != sessions { sessions = rebuilt }   // this runs 4×/second
```

  That single line is why every model type is `Equatable`.
- `TimelineView(.periodic(from: .now, by: 1))` re-renders on a schedule and hands you the
  date — how elapsed counters tick without a global timer invalidating everything. Scope it
  to the row so nothing redraws while the popover is closed. Pass `now` down as a parameter
  rather than calling `Date()` inside views; it's also what makes formatting testable.
- **Two sizing strategies, and the difference matters.** `fixedSize(horizontal: true) +
  frame(minWidth:)` hugs content; a `maxWidth` makes the frame greedy and stretches three
  words across the window. But a fixed `frame(width:)` is required when rows use `Spacer()`
  to push content to the trailing edge — a spacer needs something to push against. Wrap the
  choice in a `ViewModifier`.
- Custom `Shape` returning `UnevenRoundedRectangle` for per-corner radii.
- `.monospacedDigit()` so numbers don't jitter as digit widths change; `.truncationMode(.middle)`
  for identifiers, `.tail` for prose; `.contentShape(.rect)` to make padding hit-testable.
- `ImageRenderer` rasterises **any view off-screen** to an `NSImage` — visual review without
  screenshots or screen-recording permission, driven by an env var and fake data. This is how
  the wallpaper-gap bug was found; no unit test would have caught it.

## Testing

Swift Testing, not XCTest: `@Suite struct`, `@Test func`, `#expect(...)`,
`try #require(...)` to unwrap-or-fail, `@Test(arguments: [...])` for parameterised cases.
A **fresh instance per test** (so `init` is setup, no `tearDown`), and suites run **in
parallel** — hence UUID-named scratch directories for anything touching the filesystem.

Designed-in testability:
- Inject the paths (`init(settingsURL:executable:)`) so tests hit a scratch file.
- Every time-dependent function takes `now: Date = Date()`.
- Put presentation *logic* in a UI-free module as pure functions over plain values — then a
  dozen tests cover "should this be visible, what colour, which item wins" with no rendering.

**Round-trip discipline** for anything editing a file you don't own: the tests are mostly not
"did we add our entry" but *did we leave everything else exactly as we found it* — install,
uninstall, assert deep equality with the original; assert no empty scaffolding; assert the
symlink survived; assert a malformed file is untouched after a failed write.

Name tests as sentences about behaviour (`aPermissionPromptMeansBlockedNotBusy`) so the suite
reads as a specification.

## Build and distribution

**xcconfig indirection** so a fresh clone builds with no Apple account:

```
PERCH_CODE_SIGN_STYLE = Manual
PERCH_CODE_SIGN_IDENTITY = -        // ad-hoc
#include? "Local.xcconfig"          // "?" = optional; git-ignored per-developer override
```

Build settings reference `$(PERCH_CODE_SIGN_IDENTITY)`. Defaults go **first** — in xcconfig
the *last* assignment wins, which is the opposite of most people's assumption.

**Notarisation** (required for anyone else to open the app): a **Developer ID Application**
certificate — an *Apple Development* one cannot be notarised — then `xcodebuild archive` with
hardened runtime and `--timestamp` → `-exportArchive` (`method: developer-id`) → **`ditto -c
-k --keepParent`** to zip (`zip` does not preserve the signature) → `notarytool submit
--wait` → `stapler staple` (embeds the ticket so it opens offline) → `stapler validate` +
`spctl --assess`. Check every prerequisite up front; the round trip costs minutes.

**Repo hygiene:** commit the scheme under `xcshareddata/` (that's what makes `-scheme` work in
CI), ignore `xcuserdata/`, and mark the generated project file binary so merges stay legible:

```
*.pbxproj -text merge=union
```

**Observability as a feature.** A `--doctor` subcommand prints what every layer can see, and
deliberately folds events through *the same* state machine the app uses, so the diagnosis
can't disagree with the app. Plus `PERCH_DEBUG=1` for a live trace and `PERCH_SNAPSHOT=<dir>`
for the off-screen render. ~150 lines total; this is how the hard bugs got found.

## Integration quirks worth knowing generally

- **Cached tokens are real context.** A turn resuming from prompt cache reports
  `input_tokens` ≈ 2 with everything else under `cache_creation_input_tokens` /
  `cache_read_input_tokens`. Summing only `input_tokens` shows an empty window on a nearly
  full session. (And a per-iteration `usage.iterations[]` array double-counts — ignore it.)
- **When a fact isn't recorded, find a value that constrains it.** The context window size is
  written nowhere and a 1M session logs the same plain model id as a 200k one — but a session
  holding >200k tokens is definitionally not on the 200k model. Then write the limitation down
  in the code, the tests, and the README instead of passing an inference off as a measurement.
- **`ps -o lstart=` captured by another process is rendered in *that* process's timezone.**
  String-comparing it against local `ps` output marks everything dead. Prefer epochs.
- **Directory names that encode paths by replacing `/` with `-` are lossy.** Search for the
  known filename instead of reconstructing the folder name.
- `CLAUDE_CONFIG_DIR`-style overrides: honour them, or you silently show nothing to anyone
  who relocated their config. Silent wrongness is the failure mode to design against.
- Derive helper paths from `Bundle.main.executableURL`'s *directory*, not the bundle root, so
  they resolve whether you're the app, the helper, or a bare dev binary.
