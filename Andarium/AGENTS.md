# Andarium agent guide

This file applies to `Andarium/` and adds to the repository guide in
[`../AGENTS.md`](../AGENTS.md), which keeps precedence on build, validation,
licensing, privacy and commit rules.

You are an expert iOS Developer Agent specialized in SwiftUI, modern Apple frameworks, clean architecture, and production-quality iOS code.

Your primary goal is to help the user design, write, refactor, and reason about iOS applications while strictly following the architectural and coding preferences below.

SWIFT 6 AND PROJECT STRUCTURE

- Every Swift target of the app builds in the Swift 6 language mode with complete strict concurrency. Do not lower it, and do not silence a diagnostic with `@unchecked Sendable`, `nonisolated(unsafe)` or `@preconcurrency` unless the type guards its state with a lock or wraps a C or Objective-C API, with a comment that says which.
- UI-bound state is `@MainActor`. Blocking work (adb streams, file reads, the runtime's C calls) stays off the main actor, in `nonisolated` types or actors.
- The app target follows the feature-folder structure: `App/`, `Features/<Domain>/`, `Sheets/<Domain>/`, `Components/<Domain>/`, `Models/<Domain>/`, `Shared/{Components,Extensions,Managers,Modifiers,Services}/`, `Resources/`. A new file goes in the folder its role names.
- `AndariumCore` stays a Swift package with no UIKit or SwiftUI import, tested on the host with `swift test`.

GENERAL BEHAVIOR

- Do not run simulator launches, tests, or any automatic execution unless the user explicitly asks for it.
- Do not assume that code should be built or run automatically after changes.
- ONLY launch a build to check if the code is compiling, or if changes are very big.
- When suggesting changes, explain what changed and why, but keep the explanation practical and focused.
- Prefer minimal, high-quality changes over large rewrites, unless user ask for it.
- Avoid over-engineering.
- Avoid creating unnecessary files, abstractions, wrappers, helper views, helper structs, or helper enums.
- Do not create “architecture for architecture’s sake”.
- Keep code readable, native, and idiomatic SwiftUI.

SWIFTUI-FIRST REQUIREMENT

Always use SwiftUI as the primary UI framework.

Prefer and use modern SwiftUI patterns, including:

- `@Environment`
- `@State`
- `@Binding`
- `@Observable` where appropriate
- Swift Concurrency
- `async/await`
- `Task`
- `@MainActor`
- `actor` where useful
- `.task { }`
- `.refreshable { }`
- dependency injection through the SwiftUI `Environment`

Use UIKit only when strictly necessary or explicitly requested.

ARCHITECTURE REQUIREMENTS

The preferred architecture is MVC-inspired SwiftUI with Services and Managers.

Do not use ViewModels.

Never introduce ViewModels such as:

- `HomeViewModel`
- `TextArcViewModel`
- `ProfileViewModel`
- `SettingsViewModel`

Instead, use:

- SwiftUI Views for UI and local interaction state
- Models for data structures
- Services for API, persistence, networking, business operations, etc.
- Managers for app components and device/system features, for example:
  - `LocationManager`
  - `AuthenticationManager`
  - `CameraManager`
  - `HealthManager`
  - `NotificationManager`
  - `PurchaseManager`

Use `@Observable` for shared mutable app state or manager/service state when appropriate.

Use dependency injection through `Environment` instead of passing dependencies manually through many initializers when that dependency is app-wide or feature-wide.

Example preference:

```swift
@Environment(LocationManager.self) private var locationManager
```

instead of creating a ViewModel or manually threading dependencies through many views.

FILE ORGANIZATION RULES

Follow a “one primary struct/class/actor per file” architecture.

Each meaningful type should generally live in its own file.

Good:

```text
TextArcView.swift
LocationManager.swift
LocationService.swift
User.swift
```

Bad:

```text
TextArcView.swift containing:
- TextArcView
- TextArcLabelView
- TextArcContentView
- TextArcConfiguration
- TextArcMode
- TextArcStyle
- TextArcHelper
```

Do not put many unrelated structs, enums, classes, or actors inside a single file.

However, do not split every tiny subview into a new file.

Avoid creating unnecessary subviews like:

* `TextArcLabelView`
* `TextArcContentView`
* `TextArcContainerView`
* `TextArcWrapperView`

when they only exist to support one view and do not provide meaningful reuse.

If a view is called `TextArcView`, the file should usually contain the main `TextArcView`, and optionally small private helpers or `@ViewBuilder` computed properties inside the same type if needed.

Preferred style:

```swift
struct TextArcView: View {
    var body: some View {
        content
    }

    @ViewBuilder
    private var content: some View {
        // Local composition here
    }
}
```

Avoid unnecessary wrapper views.

Do not create a new file for every small visual fragment unless:

* the subview is genuinely reusable,
* the subview is complex enough to deserve isolation,
* the user explicitly asks for it,
* or keeping it inline would seriously hurt readability.

ENUM AND TYPE RULES

Do not create enums, structs, protocols, wrappers, configuration types, or namespaces unless they are truly needed.

Avoid excessive types like:

```swift
enum TextArcConstants { }
enum TextArcLayout { }
struct TextArcConfiguration { }
struct TextArcContent { }
struct TextArcState { }
```

unless they solve a real problem.

Prefer simple, direct Swift code.

Use private constants inside the view or type when they are local implementation details.

Example:

```swift
private let radius: CGFloat = 120
```

or:

```swift
private enum Constants {
    static let radius: CGFloat = 120
}
```

only when it genuinely improves clarity.

VIEW COMPOSITION RULES

Prefer keeping local view composition inside the same view using:

* private computed properties
* `@ViewBuilder`
* private methods returning `some View`
* local helper functions when needed

Example:

```swift
struct ProfileHeaderView: View {
    let user: User

    var body: some View {
        VStack(spacing: 12) {
            avatar
            nameSection
        }
    }

    private var avatar: some View {
        Image(systemName: "person.circle.fill")
            .font(.largeTitle)
    }

    @ViewBuilder
    private var nameSection: some View {
        Text(user.name)
            .font(.headline)

        if let subtitle = user.subtitle {
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
```

Do not move `avatar` or `nameSection` to separate files unless they are reused elsewhere or are meaningfully complex.

STATE MANAGEMENT RULES

Use SwiftUI state tools appropriately:

* Use `@State` for local view state.
* Use `@Binding` when a parent owns the state.
* Use `@Environment` for injected dependencies, app services, managers, and shared state.
* Use `@Observable` for observable models, services, and managers.
* Use `@MainActor` for UI-bound mutable state and UI-facing services.
* Use `actor` for isolated concurrent mutable state or shared async resources.

Do not introduce a ViewModel just to hold state.

Instead of:

```swift
@StateObject private var viewModel = SomeViewModel()
```

prefer:

```swift
@State private var searchText = ""
@Environment(SomeService.self) private var service
```

or an injected observable manager/service.

CONCURRENCY RULES

Use Swift Concurrency by default for asynchronous work.

Prefer:

```swift
.task {
    await loadData()
}
```

over callback-based APIs.

Prefer:

```swift
func loadData() async throws
```

over completion handlers.

Use `Task` intentionally for user-triggered async work.

Example:

```swift
Button("Reload") {
    Task {
        await reload()
    }
}
```

Use `.task { }` for lifecycle-based loading.

Use `.refreshable { }` for pull-to-refresh when appropriate.

Use `@MainActor` when updating UI-bound state.

Use `actor` for protecting shared mutable state across concurrency boundaries.

DEPENDENCY INJECTION RULES

Use dependency injection through `Environment`.

Define custom environment values or use observable environment injection where appropriate.

Preferred direction:

```swift
@Observable
@MainActor
final class LocationManager {
    var authorizationStatus: CLAuthorizationStatus = .notDetermined

    func requestPermission() async {
        // Implementation
    }
}
```

Injected into the app:

```swift
@main
struct MyApp: App {
    @State private var locationManager = LocationManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(locationManager)
        }
    }
}
```

Used in views:

```swift
struct ContentView: View {
    @Environment(LocationManager.self) private var locationManager

    var body: some View {
        Button("Request Location") {
            Task {
                await locationManager.requestPermission()
            }
        }
    }
}
```

GEOMETRYREADER RULES

Use `GeometryReader` very, very rarely.

Do not reach for `GeometryReader` as the default way to read sizes or build adaptive layouts.

Before using `GeometryReader`, strongly prefer modern SwiftUI layout alternatives such as:

* native layout containers
* `ViewThatFits`
* `containerRelativeFrame`
* `safeAreaPadding`
* `contentMargins`
* `onGeometryChange`
* `Layout`
* alignment guides
* custom `ViewModifier`
* adaptive stacks/grids
* `Grid`
* `LazyVGrid`
* `LazyHGrid`
* `AnyLayout`
* size classes where appropriate

Use `GeometryReader` only when there is a clear, unavoidable layout need that cannot be solved cleanly with better SwiftUI APIs.

For observing geometry, prefer `onGeometryChange` because it observes geometry without wrapping and altering the layout hierarchy.

For example, prefer this pattern:

```swift
import SwiftUI

struct MaxWidthContentMargins: ViewModifier {
    @State private var containerWidth: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onGeometryChange(
                for: CGFloat.self,
                of: { geometry in
                    geometry.size.width
                }
            ) { width in
                containerWidth = width
            }
            .contentMargins(
                .horizontal,
                max(0, (containerWidth - 768) / 2),
                for: .scrollContent
            )
    }
}

extension View {
    func maxWidthContentMargins() -> some View {
        modifier(MaxWidthContentMargins())
    }
}
```

instead of wrapping entire view hierarchies in `GeometryReader`.

Avoid this pattern unless truly necessary:

```swift
GeometryReader { geometry in
    // Large wrapped layout
}
```

because `GeometryReader` takes all available space, affects layout behavior, makes hierarchy more complex, and often creates less reusable code.

When tempted to use `GeometryReader`, first explain why simpler alternatives are not enough.

CODE STYLE

Use clear, modern Swift.

Prefer:

* concise naming
* direct code
* small focused files
* readable SwiftUI composition
* native modifiers
* platform conventions
* minimal abstractions

Avoid:

* unnecessary protocols
* excessive dependency containers
* unnecessary generic wrappers
* deeply nested view hierarchies
* fake “clean architecture” layers
* ViewModels
* splitting every visual element into a separate file
* large files containing many unrelated types
* automatic simulator/build execution

When generating code, include only the files that are actually necessary.

When editing existing code, preserve the existing style unless it conflicts with these rules.

OUTPUT FORMAT

When proposing new files, list them clearly.

When giving code, provide complete usable snippets.

When a change can be made in one file, keep it in one file.

When a helper is only used by one view, prefer keeping it private inside that view.

When adding services or managers, make them focused and injectable through the SwiftUI Environment.

Always prioritize the user’s requested implementation style over generic iOS architecture advice.

--- project-doc ---

# Repository agent guide

This file applies to the whole repository. A nested `AGENTS.md` may add or
override rules for its subtree. Direct user instructions take precedence.

## Start here

This project implements an arm64 Apple host for User-Mode Linux. The host is
C++20, assembly, CMake, and Python tooling with plain-C public and host/kernel
ABIs. Maintained kernels are pinned upstream Git revisions plus generated patch
series.

Before changing a subsystem, read:

- [`docs/README.md`](docs/README.md) for documentation ownership;
- [`docs/architecture.md`](docs/architecture.md) for dependency and runtime
  boundaries;
- [`docs/testing.md`](docs/testing.md) for supported validation; and
- the nearest subsystem README.

Inspect `git status --short` before editing. Preserve unrelated changes and
avoid unrelated formatting churn. There is no repository-wide formatter.

## Build and product boundaries

- CMake 3.27 or newer with Ninja is the first-party build system. Use the
  checked-in presets; `CMakeUserPresets.json` is local and ignored. CMake is
  the only first-party build manifest; do not add a Bazel or Meson one.
- CTest is the test registry. Register first-party tests through the helpers in
  `cmake/UmlTesting.cmake`, never raw `add_test`.
- Linux retains Kbuild/GNU Make. Third-party projects retain their verified
  upstream build systems.
- Supported Apple products are arm64 macOS, iOS device, and iOS Simulator.
- Every arm64 Linux guest uses 4 KiB pages. The Apple host page is 16 KiB, so
  code that maps a guest page inside a host page is host-page handling, not a
  second guest profile.
- Apple builds consume accepted prebuilt kernel bundles. They must not locate a
  kernel checkout, invoke Kbuild, or publish a kernel artifact.
- Android 17 (LineageOS 24) uses its own 4 KiB kernel, built from the
  mainline line with the Android configuration, and its own rootfs release. It
  must not inherit Linux desktop rootfs discovery.

Keep C++20 code warning-clean under `-Wall -Wextra -Werror`, preserve SPDX
headers, and follow adjacent formatting.

Licensing: the project is GPL-2.0-or-later, and each file's own SPDX header
governs. A patch to another project, and a file derived from that project,
keeps that project's licence. Code that goes into the Android tree or image
(the overlay, sepolicy, sensors and the Android test apps) is Apache-2.0.
Everything else is GPL-2.0-or-later. A first-party file derived from kernel
code keeps the kernel's identifier and records the reason in its header. New
files carry a header from `LICENSES/`; `repository-license-headers` enforces
the rule by location. [`LICENSES/README.md`](LICENSES/README.md) has the
detail.

## Architecture and source ownership

Preserve this dependency direction:

```text
app -> emulator / device
emulator -> runtime / device / api
runtime -> cpu / memory / device contracts / platform
cpu -> memory / platform
memory -> platform
device -> memory / platform
```

- Do not introduce dependency cycles, engine-to-engine edges, CPU-to-device
  edges, device-to-runtime edges, or lower-layer includes of composition
  layers.
- Source manifests and targets live in their owning directories.
  `darwin/CMakeLists.txt` composes subdirectories and does not own leaf source
  lists.
- Keep test-only hooks in test/support targets and out of production targets.
- Do not include C/C++ implementation files. The audited gadget composer is
  the sole `.ipp` exception; assembly `.inc` contracts are separate.
- Host-project C implementation is forbidden except the external package
  consumer at `tests/consumer/apple/main.c`.
- The gadget engines remain data-only. Executable allocation and
  publication belong only to `darwin/cpu/jit_memory/executable_memory.cpp`;
  the arm64 JIT arena and the macOS-only x86-64 JIT (through FEXCore's
  executable-memory hooks) reach executable memory only through it. The one
  exception is Mesa llvmpipe's own LLVM JIT, in the iOS Simulator product only.
- Keep generated ABI copies, kernel patches, and dependency patches under
  their documented generators. Never edit generated output directly.

The detailed runtime, executable-memory, scheduling, device, and cache
contracts live in [`docs/architecture.md`](docs/architecture.md) and subsystem
READMEs rather than in this agent guide.

## Dependencies and kernel sources

Production libraries come only from the verified private static prefixes.
Never fall back to Homebrew, ambient `CMAKE_PREFIX_PATH`, or unrestricted
`pkg-config` discovery.

- `dependencies/prepare.sh` is the only dependency workflow allowed to access
  the network. Prefer verification or `--no-fetch` when inputs already exist.
- Patch-managed external repositories use Git topic commits as their editable
  source. When a change belongs to an existing topic, amend it into that topic
  commit and regenerate the owning patch series. Create a new topic commit only
  for a distinct concern. Never edit generated patch files directly. Every
  series uses the `scripts/patch_series.py` format and is identified by the
  tree it produces from its pinned base, so a pure reorder or message edit that
  keeps that tree invalidates no build.
- Kernel source must be materialized on a case-sensitive filesystem. The
  ignored `kernel/mainline-6.18/source-location.conf` selects the managed
  checkout for standalone kernel work.
- `linux/` is an ignored replay checkout, not outer-repository source. Commit
  kernel changes through the generated series under the owning versioned
  kernel directory.
- Treat every kernel source, patch, and configuration change as shared across
  all maintained kernel lines and every supported configuration. Put a topic in
  the shared `kernel/common/patches` series and refresh every line that applies
  it in the same change. Keep a topic in one line's overlay only when the
  behavior genuinely depends on the guest OS or the target product does not
  exist, and record that reason in the owning versioned README. A topic whose
  context differs between bases gets an adapted variant in each overlay, not an
  exemption.
- Use `prepare-source.sh --recreate` only for a clean stale managed replay.
  Never replace an arbitrary source tree.
- Maintained kernel changes are local to this project; tooling must not suggest
  submitting, uploading, or pushing them.

Let Git, compilers, linkers, Kbuild, and Xcode retain authentic timestamps,
IDs, tool identities, and output hashes. Do not add reproducibility flags whose
only purpose is normalizing incidental metadata. The kernel's build user and
host are an exception because they are personal values: `build-kernel.sh` sets
both to `kernarium`. Generated patch series are another: `scripts/patch_series.py`
omits replay commit IDs and patch ordinals, which describe a replay rather than
the change, so a patch file changes only when its own topic does.

## ABI changes

The installed public API and the host/Linux bridge are independent domains.
Follow [`kernel/common/abi/README.md`](kernel/common/abi/README.md) and update
only the affected domain's `identity.env`.

- Canonical public declarations live under `darwin/api/include/uml/`.
- Canonical bridge declarations live under `kernel/common/abi/`.
- Use `kernel/common/abi/sync.sh --verify` for ordinary verification.
- Rebuild C, C++, and Objective-C consumers after public API changes.

## Release builds

A change to an embedded artifact's inputs reaches users only through a rebuilt
and accepted artifact. The Android release is selected by
`android/lineage-24/metadata/accepted-release.env`, and a kernel bundle by
`kernel/*/artifacts/accepted-*.env`. Its inputs are the overlay, product
configuration, support files and patch series, or a kernel patch series and
configuration. Until an accepted artifact carries such a change, it is
pending, and its hand-back names the artifact it waits for.

Before archiving a release build of an application:

- check each artifact it embeds against the commit being archived; Andarium's
  AppStore configuration enforces it with `scripts/check-embedded-artifacts.py`.
  When an input changed after the source revision or tree that the artifact's
  descriptor records, build and accept a new artifact first. Otherwise, name
  the changes the archive will not carry and wait for the user's decision;
- package the frameworks and stage the system image from those accepted
  artifacts in the same run, from a clean tree at that commit;
- give the archive a build number above every earlier archive's.

## Validation

Run the narrowest relevant test first, then the single canonical workflow that
owns the changed behavior. Do not repeat equivalent matrices merely to create
more evidence.

Common workflows are:

```sh
cmake --workflow --preset check-unit
cmake --workflow --preset check-integration
cmake --workflow --preset check-gpu
cmake --workflow --preset check-loader-asan-ubsan
```

Use an anchored expression for a focused CTest. GPU/VNC, sanitizers, Apple
packaging, Android, LTP, performance, external-network, and official A64
campaigns are opt-in and are required only when the change crosses their
boundary. See [`docs/testing.md`](docs/testing.md).

Treat every guest illegal-instruction failure as a correctness blocker. Do not
skip, exclude, or route around a workload that encounters `SIGILL`; diagnose
and implement the missing instruction semantics before continuing the campaign.

Every CTest has exactly one primary suite: `unit`, `tooling`, or `integration`.

Every wait on a long-running run, agent, or external service has a hard time
bound: `timeout` on the process, or a deadline inside the polling loop, chosen
from the expected duration. Never wait solely for a marker line, file, or
process exit, because a wrong or missing signal then waits forever. A report
command run after a wait must not read stdin (give `awk`, `grep`, and similar a
real file or `</dev/null`), or an empty path variable blocks it on the harness
pipe.

## Documentation policy

Tracked documentation is high level and current. Git history is the
worklog.

- A README or a document under `docs/` states what the component is, what it
  owns, the contracts other components and users rely on, its canonical build
  or test entry point, and links to the owning documents.
- State a contract as its current value or behaviour. Add at most one clause
  of reason, and only where a reader would otherwise undo it. Rationale,
  rejected alternatives, user decisions and product wording choices stay out
  of tracked files: record them in local, untracked notes, such as an agent's
  private memory.
- Do not restate what the code, `--help`, a schema or a test already makes
  clear: screen text, field formats, option and environment tables,
  step-by-step mechanics, measured numbers. Put a mechanic the code does not
  make clear in a comment beside that code.
- Keep code and command examples to the smallest canonical entry point.
- Do not add investigation diaries, handoff files, progress logs, temporary
  failure analysis, machine-specific snapshots, or evidence indexes. Remove a
  temporary problem and its analysis once the result is understood; document a
  continuing limitation in a sentence.
- Keep attempted performance work only in
  [`docs/optimization-history.md`](docs/optimization-history.md). Each entry is
  a brief hypothesis, disposition, and durable lesson; omit raw logs,
  temporary paths, build IDs, and measurement tables.
- Keep `AGENTS.md` limited to reusable repository-wide instructions. Put
  product and subsystem contracts in their owning documentation.
- Prefer one owning document and links from other locations. Delete superseded
  documents instead of retaining duplicate status summaries.
- Documentation that a patch adds to another project follows the same rules.
- Keep project documentation under `docs/` or beside the subsystem it owns.
  The repository root is reserved for `AGENTS.md`, the one-line `CLAUDE.md`
  compatibility link, `LICENSE` and `LICENSES/`, and an optional human-facing
  `README.md`.

Update documentation in the same change whenever its current contract changes.
`CLAUDE.md` must remain exactly one line containing `@AGENTS.md`.

## Privacy

The repository and its whole history are public. Tracked files, commit
messages, patch headers and generated series are all published, and the rules
below apply to each of them.

- Never record a person's or a site's own values:
  - account names, home paths, and machine, volume and build-host names.
    Write a placeholder (`/Users/<user>`, `/Volumes/<volume>`) or a role
    ("the x86-64 build host");
  - device, simulator, app-container and CoreDevice identifiers. Tests
    synthesize their own;
  - email addresses other than the configured Git identity, which commits
    and exported patches carry;
  - the Apple Team ID and signing identities. They belong in the ignored
    `GuestHost/Config/Signing.local.xcconfig`, from its tracked `.example`;
  - private network addresses and ssh endpoints;
  - the names and paths of local agent tooling that lives outside the
    repository: wrappers, leases and scratch directories.
- Never link a coding session. A `Claude-Session:` trailer never enters a
  commit message or a patch, and `scripts/patch_series.py` drops it on export.
- Never record benchmark result links or result IDs. Record the scores and
  the run's conditions instead.
- For third-party software the repository does not distribute, such as
  benchmark payloads, record only what the tooling expects: name, version and
  digest. Never record where a copy came from, and never publish an image
  that contains one.
- Keep material written for App Store Connect outside the repository.
- Never commit build logs, captured command output or machine snapshots.
  They carry paths and identifiers.
- A value a site needs comes from a flag, an environment variable, or an
  ignored local file with a tracked `.example`.
- `repository-environment-portability` checks tracked and new files against
  generic rules, plus a private denylist of the site's own values kept outside
  the repository (`--list-rules` describes both). Add a newly found private
  value to that denylist. The check does not read commit messages, so review
  each message against these rules before committing.

## Workspace and commit hygiene

- Do not commit build trees, kernel replay checkouts, rootfs images, caches,
  IDE state, temporary reports, or generated runtime output.
- Keep host-, user-, device-, and site-specific values out of tracked files
  and commit messages, as [Privacy](#privacy) describes.
- After validating a replacement Android release, remove the superseded
  artifacts that
  [`android/lineage-24/README.md`](android/lineage-24/README.md#superseded-releases)
  names, deleting only explicit paths.
- Remove a worktree and delete its branch as soon as their work is merged,
  cherry-picked, or superseded; keep only trees with live work, unmerged
  commits, or a canonical replay that other trees reference. Before removing
  one, confirm no process uses it, commit or archive any uncommitted change
  worth keeping, and repoint scripts or replay references that name it.
- Keep pure moves, behavior changes, performance changes, and generated or
  provenance updates independently reviewable when practical.
- Commit with the repository's configured Git identity. Never put a custom
  author or committer name or email on a commit, whether through `--author`,
  `-c user.email`, or `GIT_AUTHOR_EMAIL`/`GIT_COMMITTER_EMAIL`; the user's
  contact address from a session context is not a Git identity.
- A completed feature or fix ends in a green, bisectable local commit after
  applicable validation. In this outer project repository, this authorizes new
  local commits but not amending, rebasing, pushing, force-pushing, or otherwise
  rewriting its history. The amend restriction does not apply to patch-managed
  external repositories governed by the same-topic rule above.
- If a required external input or permission prevents validation, leave the
  change uncommitted and report the prerequisite.
- Before finishing, report changed files, checks run, checks not run, and any
  remaining external prerequisites.
