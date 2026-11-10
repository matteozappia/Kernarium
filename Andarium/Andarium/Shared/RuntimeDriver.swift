// SPDX-License-Identifier: GPL-2.0-or-later

import AndariumCore
import Foundation

/// What the Cancel button of a long task does. Two are equal when they are the
/// same button, so a state that only changes its words stays equal to itself.
struct BusyCancel: Equatable {
    let id = UUID()
    let action: @MainActor () -> Void

    static func == (lhs: BusyCancel, rhs: BusyCancel) -> Bool { lhs.id == rhs.id }
}

/// How an operation ended, when its overlay stays up to say so until the
/// person closes it.
struct BusyResult: Equatable {
    /// The operation did not do what was asked.
    var failed: Bool
    /// Closes the overlay.
    let dismiss: BusyCancel
}

/// A long task the screens wait for: creating or erasing a guest, or one of
/// the guest's own operations.
struct BusyState: Equatable {
    var title: String
    var detail: String
    /// 0 to 1, or nil while the length of the task is not known.
    var progress: Double?
    /// Shows a Cancel button that does this; nil for a task that cannot stop.
    var cancel: BusyCancel?
    /// Set once the task is over: the overlay then shows how it ended and a
    /// button that closes it, in place of the progress and Cancel.
    var result: BusyResult?
}

/// What a running operation tells the overlay: any part may be left out.
nonisolated struct BusyUpdate: Sendable {
    var progress: Double?
    var detail: String?
    /// False once the task is past the point where it can stop; true again is
    /// never sent.
    var cancellable: Bool?

    init(progress: Double? = nil, detail: String? = nil, cancellable: Bool? = nil) {
        self.progress = progress
        self.detail = detail
        self.cancellable = cancellable
    }
}

/// Something the person should know and acknowledge.
struct AppAlert: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
}

/// How far the system lets Andarium use the microphone.
enum MicrophoneState: Equatable {
    case notAsked, denied, granted
}

/// A question about a permission iOS has already refused, which only the
/// person can change in Settings.
enum PermissionPrompt: Identifiable, Equatable {
    case microphone

    var id: Self { self }
}

/// What the device application does behind the screens: the guest's files and
/// its run. The Simulator preview has no driver, and the model then plays the
/// same steps against mock data.
@MainActor
protocol RuntimeDriver: AnyObject {
    func create(_ guest: Guest, progress: @escaping @Sendable (Double) -> Void) async throws -> Guest
    /// Deletes the guest and everything it stored, its choices included.
    func erase(progress: @escaping @Sendable (Double) -> Void) async throws
    func save(_ guest: Guest) throws
    /// What a start would be, from the guest's files; nil when they cannot be
    /// read, which a start then reports.
    func startPlan() -> StartPlan?
    /// What the guest's data disk occupies now, measured from its file; the
    /// guest changes it while it runs.
    func measuredUsedBytes() -> UInt64
    /// A run is wanted. The runtime starts once the guest's display has its
    /// size, after the disk is ready.
    func begin(guest: Guest, mode: StartMode, kind: BootKind)
    /// Puts the data back to what the update that did not finish started
    /// from; the guest does not start.
    func restoreUpdate() throws
    /// The person resumes a guest paused for want of space. Reads the space
    /// again and wakes the guest when it is at least `RunSpace.resumeAtBytes`;
    /// returns whether it did. The guest stays paused otherwise.
    func resumeAfterSpacePause() async -> Bool
    /// The person asks to check again over a guest that could not be paused:
    /// reads the space, and returns true when there is enough for the guest
    /// to run on; otherwise pauses the guest again, and the model hears how
    /// that came out.
    func checkSpaceAfterPauseFailed() async -> Bool
    /// The person shuts down a guest paused for want of space: wakes it
    /// without watching the space again and asks Android to power off, which
    /// ends the run. Throws when Android cannot be asked; the guest runs on
    /// and the watch starts again then.
    func shutDownAfterSpacePause() async throws
    /// Enables or stops sharing motion with the guest.
    func setMotionSensors(_ on: Bool)
    /// The scene's geometry changed, which may include its interface
    /// orientation.
    func sceneGeometryDidChange()
    /// Asks the guest for a bug report and copies it into `BugReportStaging`.
    /// Returns the staged file; cancelling the task stops the report.
    func createBugReport(update: @escaping @Sendable (BusyUpdate) -> Void) async throws -> URL
    /// Installs the APK at `url`, which the caller can read, into the guest.
    /// Cancelling the task stops it while the file is still being sent.
    func installApk(at url: URL, sizeBytes: Int, update: @escaping @Sendable (BusyUpdate) -> Void) async throws
    /// Flashes the ZIP at `url`, which the caller can read: restarts the guest
    /// into recovery and sends the package. Returns once recovery has the
    /// whole package; `finished` is called when recovery no longer reads it.
    func flashZip(
        at url: URL, sizeBytes: Int, update: @escaping @Sendable (BusyUpdate) -> Void,
        finished: @escaping @Sendable () -> Void
    ) async throws
    /// Whether the guest's USB debugging setting is on; nil when it cannot be
    /// read now.
    func usbDebugging() async -> Bool?
    /// Opens the listener of ADB over the network on the device's network
    /// addresses. Throws when it cannot (`AdbError.io(EADDRINUSE)` for a
    /// port in use).
    func startAdbOverNetwork() throws
    /// Closes the listener and every computer's connection through it.
    func stopAdbOverNetwork()
    /// The device's IPv4 address on a local network, which a computer
    /// connects to; nil without one.
    func localNetworkAddress() -> String?
    /// One reading of the running guest's host-side figures, taken off the
    /// main thread; nil when no guest runs.
    func readStatistics() async -> StatsSample?
    /// How many graphics allocations the host has refused the running guest,
    /// since its display was made; nil when no guest runs. It reads one
    /// counter, never waits for the guest and may be asked while the
    /// statistics are not shown.
    func readGraphicsRefusals() async -> UInt64?
    /// The guest's graphics memory budget and who holds it: only holders
    /// quiet for `minimumIdle` and holding `minimumBytes` or more are listed.
    /// nil when no guest runs or its GPU has not started. It reads counters,
    /// never waits for the guest and may be asked while the statistics are not
    /// shown.
    func readGraphicsMemory(minimumIdle: Duration, minimumBytes: UInt64) async -> GraphicsMemoryReading?
    /// Frees graphics memory by asking Android to end the cached app that
    /// holds the most of it (`GraphicsReclaim.reclaim`), within the guest's
    /// shell; nothing is ended that the activity manager does not list under
    /// the holder's process.
    func reclaimGraphicsMemory(_ reading: GraphicsMemoryReading, using policy: GraphicsReclaim) async
        -> GraphicsReclaimResult
    /// The guest kernel's own memory figures; nil when they could not be
    /// had: the kernel does not answer the request yet, or asking could wake
    /// a guest that sleeps. The caller keeps the last figures then. It may
    /// wait up to half a second, and never on the main thread.
    func readGuestMemory() async -> GuestMemorySample?
}

/// What a screen needs from its launch arguments to open a state directly.
struct ScreenHints {
    var scrollTarget: String?
    var infoPage: InfoPage?
}
