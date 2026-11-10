// SPDX-License-Identifier: GPL-2.0-or-later

import AndariumCore
import Observation
import SwiftUI

/// A view that shows the guest's statistics.
enum StatisticsViewer: Hashable {
    /// The capsule over the session.
    case pill
    /// The Stats rows of the session's Settings.
    case settings
}

enum SheetKind: String, Identifiable, Hashable {
    case create, resize, info, system

    var id: String { rawValue }
}

/// What a launch argument asks the session to show first.
struct SessionPreset: Equatable {
    /// Android's volume panel, as after a volume key press.
    var volumePanel = false
    var settings = false
    /// Settings opens at full height instead of half.
    var settingsLarge = false
    /// Settings scrolls to the section with this identifier ("stats",
    /// "display" or "capabilities").
    var settingsScroll: String?
    var powerMenu = false
    var leftEdge = false
    var guestScreen: GuestScreen = .home
}

enum GuestScreen: Equatable {
    /// Android's home screen.
    case home
    /// The launcher's search with Android's own keyboard up.
    case search
    /// Android's first-run setup.
    case setup
    /// Android's screen asleep.
    case off
}

/// What the running guest offers through Settings (ADB and the stats
/// overlay) and whether its side keys are open. It lasts for one run.
@Observable
final class SessionState {
    /// ADB over network is on: the listener runs.
    var adb = false
    /// The device's address on the local network while `adb` is on; nil
    /// without one.
    var adbAddress: String?
    /// Why ADB over network did not start, in words.
    var adbProblem: String?
    /// The guest's USB debugging setting as last read; nil until it has
    /// been. ADB over network needs it on.
    var usbDebugging: Bool?
    var showStats = false
    var readout = Readout()
    /// The side keys are open. The session owns it because a touch on the
    /// guest's display, which is another view, closes them.
    var sideKeysOpen = false

    /// The address the preview shows, from the range reserved for examples.
    static let previewAddress = "198.51.100.23"

    /// Puts the side keys away. A touch that begins on the guest's display
    /// calls it, so the touch both reaches Android and closes the keys.
    func closeSideKeys() {
        guard sideKeysOpen else { return }
        withAnimation(SideKeysOverlay.motion) { sideKeysOpen = false }
    }
}

/// What the screens read and change. The guest's life (create, start, boot,
/// erase, how a run ends) is `Lifecycle` in AndariumCore; this adds what only
/// a screen holds: the open sheet, display options and the session's state.
@Observable
final class AppModel {
    var lifecycle: Lifecycle {
        // The readings run while the guest does.
        didSet {
            if lifecycle.phase != oldValue.phase {
                refreshStatistics()
                refreshGraphicsNotice()
            }
        }
    }
    var host: HostDevice
    /// The system this build of Andarium carries.
    var system: SystemInfo
    /// What the runtime behind the screens can do; a screen shows only the
    /// controls whose capability exists.
    var capabilities: Capabilities
    /// Free space a new guest needs, which the storage behind the screens
    /// decides.
    var createRequirementBytes: UInt64
    /// The largest data disk the carried system accepts, in GiB; the storage
    /// rulers stop there when it is below `Limits.capacityRangeGiB`.
    var releaseMaximumGiB = Limits.capacityRangeGiB.upperBound
    /// The sizes the storage rulers offer, in steps of 4 GiB.
    var capacityStopsGiB: [Int] { Limits.capacityStopsGiB(releaseMaximumGiB: releaseMaximumGiB) }
    var sheet: SheetKind?
    var startBlocked = false
    /// Erase guest is asking to be confirmed.
    var confirmingErase = false
    /// What a start would be, from the guest's files: Home words Start and
    /// shows the update notices by it.
    var plan: StartPlan = .normal
    /// The release the running boot updates from, where it is known.
    var bootFrom: String?
    /// The preview's plan after Restore; a device reads it from the files.
    var planAfterRestore: StartPlan?

    // App-wide display option, set on the home screen: the guest draws at the
    // screen's pixel density. The guest's display always follows the window.
    var retina = false
    /// Whether the person has set Retina mode themselves. Until they do, it
    /// follows the device (`DisplayOptions.defaultRetina`); once they have,
    /// the default never replaces their choice.
    var retinaChosen = false
    /// The person's choice of Retina mode on Home.
    func chooseRetina(_ on: Bool) {
        retina = on
        retinaChosen = true
    }
    /// What is kept of the display options across launches.
    var displayOptions: DisplayOptions {
        DisplayOptions(chosenRetina: retinaChosen ? retina : nil)
    }
    /// The launch stated Retina mode (automation): the value belongs to that
    /// run and is not kept.
    var retinaStatedByLaunch = false
    /// The display options to keep; nil where the launch stated Retina mode,
    /// so what the person chose stays stored.
    var displayOptionsToKeep: DisplayOptions? { retinaStatedByLaunch ? nil : displayOptions }
    /// The host window owns display rotation until iPadOS grants the
    /// full-screen session's orientation lock. Never a saved guest setting.
    var hostDrivesGuestRotation = false

    var sessionPreset = SessionPreset()
    var session = SessionState()
    /// The launch decided whether the statistics show (automation, see
    /// `StatsPreference.launch`): the value belongs to that run and is not kept.
    var statsDecidedByLaunch = false
    /// What is kept of Settings' "Show on screen" across launches
    /// (`StatsPreference`); nil where the launch decided it.
    var showStatsToKeep: Bool? { statsDecidedByLaunch ? nil : session.showStats }
    /// How the last run ended, for the screen that says so.
    var runEnd = RunEnd(result: 0)
    var runUptimeSeconds: Int?
    /// Where Resize opens; nil opens at the current capacity.
    var resizePreset: Int?
    /// Holds the boot screen at one stage instead of animating (screenshots).
    var frozenBootStage: Int?
    /// Seconds the boot screen shows when it is held.
    var frozenElapsed = 9

    #if !APP_STORE
    /// The launch's automation work (create, erase, start) has run; a scene
    /// that connects to this model again does not repeat it.
    var launchApplied = false
    #endif

    /// The runtime and storage behind the screens; nil plays mock data.
    var driver: (any RuntimeDriver)?
    /// A long task the screens wait for.
    var busy: BusyState?
    /// The guest is paused because the device is nearly out of space; the
    /// screen over the session asks what to do.
    var spacePause: SpacePause?
    var alert: AppAlert?
    /// How far the current boot has got, from the guest's console.
    var bootTracker = BootTracker()
    /// The guest's disk is being written before the run can begin.
    var preparingDisk = false
    var diskProgress: Double?
    var motionSensorsAvailable = true
    var motionSensorsProblem: String?
    var microphoneState = MicrophoneState.notAsked
    /// The question about a permission the person is being asked, if any.
    var permissionPrompt: PermissionPrompt?
    /// The person went to Settings to allow the microphone: when Andarium is
    /// active again with access, the switch they tapped turns on.
    var microphoneAwaitsSettings = false
    /// Asks iOS about the microphone and tells the guest. The device
    /// application and the Simulator preview's system mode have one; a preview
    /// without it takes the access as given.
    @ObservationIgnored var microphone: MicrophoneController?
    /// Opens Andarium's page in the system's Settings. A test puts its own here.
    @ObservationIgnored var openSettings: @MainActor () -> Void = {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
    private var persistTask: Task<Void, Never>?
    /// The Android operation under way (a bug report, an install), which the
    /// overlay's Cancel stops, and the run it belongs to.
    private var operation: Task<Void, Never>?
    private var operationEpoch = 0
    private var operationCancelled = false
    /// A flash restarts the guest itself: that restart does not end it.
    private var operationSurvivesRestart = false
    /// Looks after ADB over network while it is on.
    private var adbWatcher: Task<Void, Never>?
    private var readingUsbDebugging = false
    /// How often the watcher looks while ADB over network is on: the address
    /// every time, the USB debugging setting every fifth. A test shortens it.
    var adbWatchInterval = Duration.seconds(2)

    // MARK: Statistics state

    /// The views that show the statistics. Nothing is read while there are
    /// none.
    private(set) var statisticsViewers: Set<StatisticsViewer> = []
    /// Whether the application is the active one. The readings stop when it
    /// is not, and start again with a new baseline.
    var applicationActive = true {
        didSet {
            if applicationActive != oldValue {
                refreshStatistics()
                refreshGraphicsNotice()
            }
        }
    }
    /// The figures behind the screens, from the driver's readings.
    private(set) var statisticsMeter = StatsMeter()
    #if !APP_STORE
    /// A launch for automation prints each reading.
    var printsStatistics = false
    #endif
    /// Waits between readings; a test paces them by hand.
    @ObservationIgnored var statisticsSleep: @MainActor (Duration) async -> Void = { duration in
        try? await Task.sleep(for: duration)
    }
    @ObservationIgnored private var statisticsTask: Task<Void, Never>?
    /// Tells a loop that ended from the one that replaced it.
    @ObservationIgnored private var statisticsGeneration = 0

    // MARK: Graphics notice state

    /// Whether the session says Android ran out of graphics memory, from the
    /// runtime's count of the refusals the guest was answered with.
    private(set) var graphicsNotice = GraphicsNotice()
    /// Waits between readings of that count; a test paces them by hand.
    @ObservationIgnored var graphicsNoticeSleep: @MainActor (Duration) async -> Void = { duration in
        try? await Task.sleep(for: duration)
    }
    /// The moment a reading is taken at; a test sets its own.
    @ObservationIgnored var graphicsNoticeClock: @MainActor () -> ContinuousClock.Instant = { .now }
    @ObservationIgnored private var graphicsNoticeTask: Task<Void, Never>?
    @ObservationIgnored private var graphicsNoticeGeneration = 0
    /// When to end the cached app that holds the most graphics memory, from
    /// the same readings; nothing of it shows.
    @ObservationIgnored private(set) var graphicsReclaim = GraphicsReclaim()

    init(
        guest: Guest?, host: HostDevice, system: SystemInfo, capabilities: Capabilities,
        createRequirementBytes: UInt64
    ) {
        lifecycle = Lifecycle(guest: guest)
        self.host = host
        self.system = system
        self.capabilities = capabilities
        self.createRequirementBytes = createRequirementBytes
    }

    var guest: Guest? {
        get { lifecycle.guest }
        set {
            lifecycle.guest = newValue
            persistSoon()
        }
    }

    var phase: Phase {
        get { lifecycle.phase }
        set { lifecycle.phase = newValue }
    }

    var notice: HomeNotice? {
        get { lifecycle.notice }
        set { lifecycle.notice = newValue }
    }

    /// Where the session records and MetricKit's reports are kept: a bug
    /// report carries them (`BugReportAttachments`).
    var diagnosticsDirectory: URL?
    /// The application's container paths, which never leave in a bug report.
    var diagnosticsContainers: [String] = []

    /// At launch: keeps `diagnostics` for bug reports and reads how the
    /// previous session ended (`PreviousSession`), before the next boot writes
    /// its own record. A bad end of a guest that still exists says so on Home.
    func adoptDiagnostics(in diagnostics: URL, containers: [String], endedOutOfForeground: Bool) {
        diagnosticsDirectory = diagnostics
        diagnosticsContainers = containers
        guard let previous = PreviousSession.consume(in: diagnostics, endedOutOfForeground: endedOutOfForeground)
        else { return }
        print("Andarium: \(previous.record.summary)")
        if guest != nil, let notice = previous.notice { self.notice = notice }
    }

    var canCreate: Bool { host.hasRoom(for: createRequirementBytes) }
    /// Less free space than Android's first start wants: Home says so before
    /// a start would fail.
    var lowSpace: Bool { !host.hasRoom(for: Limits.firstStartReserveBytes) }

    /// What a start of the guest would be, for the words on Start.
    func bootKind(_ mode: StartMode) -> BootKind {
        guest == nil ? .normal : plan.bootKind(mode)
    }

    /// Reads the plan from the guest's files again: after the guest is made,
    /// erased or has run, which change what a start is.
    func refreshPlan() {
        guard let driver else { return }
        // A record that cannot be read has no plan; the start then fails
        // with the reason.
        plan = driver.startPlan() ?? .normal
    }

    /// Records the guest's choices a moment after the last change, so a
    /// drag on a ruler writes once.
    private func persistSoon() {
        guard driver != nil else { return }
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.persistNow()
        }
    }

    func persistNow() {
        persistTask?.cancel()
        guard let driver, let guest else { return }
        do {
            try driver.save(guest)
        } catch {
            alert = AppAlert(title: "Settings not saved", message: error.localizedDescription)
        }
    }

    func create(_ guest: Guest) {
        guard let driver else {
            lifecycle.create(guest)
            plan = .firstStart
            return
        }
        runBusy(
            BusyState(
                title: "Creating guest",
                detail: "Setting up Andarium with \(Formats.size(gib: guest.effectiveCapacityGiB)).", progress: 0
            ),
            failure: "The guest could not be created"
        ) { progress in
            let made = try await driver.create(guest, progress: progress)
            self.lifecycle.create(made)
            self.refreshPlan()
        }
    }

    /// Restore: the data goes back to what the update that did not finish
    /// started from, and the guest does not start. Home then shows the
    /// ordinary pending update.
    func restoreUpdate() {
        guard let driver else {
            if let planAfterRestore { plan = planAfterRestore }
            return
        }
        do {
            try driver.restoreUpdate()
        } catch {
            alert = AppAlert(title: "The guest could not be restored", message: error.localizedDescription)
        }
        refreshPlan()
    }

    /// Erase guest: everything the guest stored is deleted, its choices
    /// included, and Andarium returns to the first-launch screen.
    func erase() {
        guard let driver, guest != nil else {
            lifecycle.erase()
            plan = .firstStart
            return
        }
        runBusy(
            BusyState(title: "Erasing guest", detail: "Deleting everything the guest stored.", progress: 0),
            failure: "The guest could not be erased"
        ) { progress in
            // A choice saved a moment after the last change must not come
            // back after the files are gone.
            self.persistTask?.cancel()
            try await driver.erase(progress: progress)
            self.lifecycle.erase()
            self.resizePreset = nil
            self.sheet = nil
            self.refreshPlan()
        }
    }

    /// Runs `work` behind the busy overlay, with a failure alert if it throws.
    private func runBusy(
        _ state: BusyState, failure: String,
        _ work: @escaping @MainActor (@escaping @Sendable (Double) -> Void) async throws -> Void
    ) {
        guard busy == nil else { return }
        busy = state
        Task { [weak self] in
            guard let self else { return }
            do {
                try await work { fraction in
                    Task { @MainActor in self.busy?.progress = fraction }
                }
            } catch {
                alert = AppAlert(title: failure, message: error.localizedDescription)
            }
            busy = nil
        }
    }

    // MARK: Low space

    /// The device is down to `freeBytes` and the runtime is pausing the guest.
    /// What needs the guest is let go (an operation, ADB over network), the
    /// session closes its Settings, and the screen over it says Android is
    /// being paused, offering nothing until it is.
    func guestPausingForSpace(freeBytes: UInt64) {
        host.freeStorageBytes = freeBytes
        abandonOperation()
        stopAdbOverNetwork()
        spacePause = SpacePause(freeBytes: freeBytes, stage: .pausing)
    }

    /// The guest holds still: the screen offers Resume and Shut down.
    func guestPausedForSpace() {
        guard var pause = spacePause, pause.stage == .pausing else { return }
        pause.stage = .paused
        pause.freeBytes = host.freeStorageBytes
        spacePause = pause
    }

    /// The guest did not hold still after every attempt and runs on: the
    /// screen says so, and offers Shut down and a new attempt.
    func guestNotPausedForSpace() {
        guard var pause = spacePause, pause.stage == .pausing else { return }
        pause.stage = .notPaused
        pause.freeBytes = host.freeStorageBytes
        spacePause = pause
    }

    /// Check again, over a guest that did not pause: the driver reads the
    /// space and pauses the guest again, or lets the screen go when there is
    /// room for the guest to run on.
    func checkSpaceAfterPauseFailed() {
        guard var pause = spacePause, pause.stage == .notPaused, pause.working == nil else { return }
        guard let driver else {
            spacePause = nil
            return
        }
        pause.stage = .pausing
        spacePause = pause
        Task { [weak self] in
            let enough = await driver.checkSpaceAfterPauseFailed()
            guard let self, self.spacePause?.stage == .pausing, enough else { return }
            self.spacePause = nil
        }
    }

    /// Resume: the driver reads the space again and wakes the guest when
    /// there is enough; otherwise the screen says what is free now.
    func resumeAfterSpacePause() {
        guard var pause = spacePause, pause.stage == .paused, pause.working == nil else { return }
        guard let driver else {
            // The preview plays the pause away.
            spacePause = nil
            return
        }
        pause.working = .resuming
        spacePause = pause
        Task { [weak self] in
            let resumed = await driver.resumeAfterSpacePause()
            // A guest that paused again meanwhile has a screen of its own.
            guard let self, var pause = self.spacePause, pause.working == .resuming else { return }
            if resumed {
                self.spacePause = nil
            } else {
                pause.freeBytes = self.host.freeStorageBytes
                pause.stillShort = true
                pause.working = nil
                self.spacePause = pause
            }
        }
    }

    /// Shut down: Android is woken and asked to power off, which writes what
    /// it has and ends the run. The run ending takes the screen away.
    func shutDownAfterSpacePause() {
        guard var pause = spacePause, pause.stage != .pausing, pause.working == nil else { return }
        guard let driver else {
            powerOff()
            return
        }
        pause.working = .shuttingDown
        spacePause = pause
        Task { [weak self] in
            do {
                try await driver.shutDownAfterSpacePause()
            } catch {
                guard let self, self.spacePause?.working == .shuttingDown else { return }
                // The guest runs on, and its space is watched again: the
                // screen comes back with the new figure if it is still short.
                self.spacePause = nil
                self.alert = AppAlert(
                    title: "Android could not be shut down",
                    message: "It could not be asked to power off. Try again, or close Andarium and open it again.")
            }
        }
    }

    // MARK: ADB over network

    /// ADB over network may be switched on: the guest's USB debugging is on.
    /// The preview has no guest to ask and says yes unless a screen says no.
    var adbOverNetworkAvailable: Bool {
        driver == nil ? session.usbDebugging != false : session.usbDebugging == true
    }

    /// The toggle in Settings. Turning it on opens the listener on the
    /// device's network addresses, which the guest's USB debugging being on
    /// allows; turning it off, USB debugging going off, or the run ending
    /// closes it. It lasts for this run only.
    func setAdbOverNetwork(_ on: Bool) {
        guard capabilities.adbOverNetwork else { return }
        guard on else {
            stopAdbOverNetwork()
            return
        }
        guard !session.adb, case .running(.normal) = phase, adbOverNetworkAvailable else { return }
        do {
            try driver?.startAdbOverNetwork()
        } catch {
            session.adbProblem = AdbNetworkMessages.cannotStart(error)
            return
        }
        withAnimation(.snappy) {
            session.adb = true
            session.adbProblem = nil
            session.adbAddress = driver?.localNetworkAddress() ?? (driver == nil ? SessionState.previewAddress : nil)
        }
        watchAdbOverNetwork()
    }

    /// Closes the listener and switches the toggle off.
    func stopAdbOverNetwork() {
        adbWatcher?.cancel()
        adbWatcher = nil
        driver?.stopAdbOverNetwork()
        guard session.adb || session.adbAddress != nil else { return }
        withAnimation(.snappy) {
            session.adb = false
            session.adbAddress = nil
        }
    }

    /// The run is over or starts again: nothing about the guest's settings
    /// holds for the next one.
    private func endAdbOverNetwork() {
        stopAdbOverNetwork()
        session.usbDebugging = nil
        session.adbProblem = nil
    }

    /// The address a computer connects to, which changes with the network.
    /// The preview keeps the one it was given.
    func refreshAdbAddress() {
        guard session.adb, let driver else { return }
        let address = driver.localNetworkAddress()
        if session.adbAddress != address { session.adbAddress = address }
    }

    /// Reads the guest's USB debugging setting. ADB over network ends when
    /// it is off.
    func refreshUsbDebugging() async {
        // A guest paused for space is not asked: a connection waits for it.
        guard capabilities.adbOverNetwork, let driver, case .running(.normal) = phase,
              spacePause == nil, !readingUsbDebugging else { return }
        readingUsbDebugging = true
        defer { readingUsbDebugging = false }
        let current = session
        let value = await driver.usbDebugging()
        guard session === current, case .running(.normal) = phase, let value else { return }
        if current.usbDebugging != value { current.usbDebugging = value }
        if !value, current.adb { stopAdbOverNetwork() }
    }

    /// While Settings is open: the address and the setting, read again every
    /// few seconds until the sheet goes and the task is cancelled.
    func watchSettings() async {
        while !Task.isCancelled {
            refreshAdbAddress()
            await refreshUsbDebugging()
            try? await Task.sleep(for: .seconds(3))
        }
    }

    /// While ADB over network is on and Settings is closed, the address is
    /// read every few seconds and the setting every ten, so that turning
    /// USB debugging off in the guest turns this off too.
    private func watchAdbOverNetwork() {
        adbWatcher?.cancel()
        guard driver != nil else { return }
        adbWatcher = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.adbWatchInterval ?? .seconds(2))
                guard let self, !Task.isCancelled else { return }
                tick += 1
                refreshAdbAddress()
                if tick % 5 == 0 { await refreshUsbDebugging() }
            }
        }
    }

    // MARK: Android operations

    /// Runs one of Android's operations behind the busy overlay: Settings
    /// has dismissed, the overlay covers the screens, and a Cancel button
    /// stops it. `work` reports through the update closure and throws
    /// `CancellationError` when the person cancelled; any other error is an
    /// alert. `finished` runs once the overlay has gone. With `ending`, the
    /// overlay stays up instead and says how the operation ended (its words
    /// on success; `failure` and the error's on failure) until the person
    /// closes it; cancelling still takes the overlay away.
    private func runOperation<Output: Sendable>(
        _ state: BusyState, failure: String,
        ending: ((Output) -> (title: String, detail: String))? = nil,
        _ work: @escaping @MainActor (@escaping @Sendable (BusyUpdate) -> Void) async throws -> Output,
        finished: @escaping @MainActor (Output) -> Void = { _ in }
    ) {
        guard busy == nil else { return }
        operationEpoch += 1
        let epoch = operationEpoch
        operationCancelled = false
        var state = state
        state.cancel = BusyCancel { [weak self] in self?.cancelOperation() }
        busy = state
        operation = Task { [weak self] in
            guard let self else { return }
            var result: Output?
            var failureWords: String?
            do {
                result = try await work { update in
                    Task { @MainActor in self.apply(update, epoch: epoch) }
                }
            } catch is CancellationError {
            } catch {
                if operationEpoch == epoch {
                    if ending == nil {
                        alert = AppAlert(title: failure, message: error.localizedDescription)
                    } else {
                        failureWords = error.localizedDescription
                    }
                }
            }
            // The run ending, or a restart, took the operation over already.
            guard operationEpoch == epoch else { return }
            operation = nil
            operationSurvivesRestart = false
            if let ending, let result {
                let words = ending(result)
                busy = ended(title: words.title, detail: words.detail, failed: false)
            } else if ending != nil, let failureWords {
                busy = ended(title: failure, detail: failureWords, failed: true)
            } else {
                busy = nil
            }
            if ending == nil, let result { finished(result) }
        }
    }

    /// The overlay of an operation that is over: how it ended, and the button
    /// that closes it.
    private func ended(title: String, detail: String, failed: Bool) -> BusyState {
        BusyState(
            title: title, detail: detail,
            result: BusyResult(failed: failed, dismiss: BusyCancel { [weak self] in self?.busy = nil })
        )
    }

    private func apply(_ update: BusyUpdate, epoch: Int) {
        guard epoch == operationEpoch, !operationCancelled, busy != nil else { return }
        // The new value is worked out before the write: reading `busy` while
        // writing through it is an overlapping access.
        if let progress = update.progress, let current = busy {
            busy?.progress = max(current.progress ?? 0, progress)
        }
        if let detail = update.detail { busy?.detail = detail }
        if update.cancellable == false { busy?.cancel = nil }
    }

    /// The overlay's Cancel: the operation stops and cleans up while the
    /// overlay stays, so the session returns with nothing left behind.
    private func cancelOperation() {
        guard operation != nil, !operationCancelled else { return }
        operationCancelled = true
        busy?.cancel = nil
        busy?.detail = "Cancelling\u{2026}"
        operation?.cancel()
    }

    /// The guest ended or restarted under an operation: its stream is gone
    /// with the boot, so the overlay goes and no alert is raised over the
    /// screen that says the guest stopped.
    private func abandonOperation() {
        // The words of a finished operation belong to the run that ended.
        if operation == nil, busy?.result != nil { busy = nil }
        operationSurvivesRestart = false
        guard operation != nil else { return }
        operationEpoch += 1
        operation?.cancel()
        operation = nil
        busy = nil
    }

    /// Create bug report: Settings has dismissed. Android collects its report
    /// (minutes, under emulation) and the finished zip goes to the share
    /// sheet, where Save to Files is one of the actions.
    func createBugReport() {
        guard capabilities.bugReport, case .running(.normal) = phase else { return }
        runOperation(
            BusyState(
                title: "Creating bug report",
                detail: "The guest is collecting its logs and state. This can take several minutes.", progress: 0
            ),
            failure: "Bug report not created",
            { [driver, diagnosticsDirectory, diagnosticsContainers] update in
                let file = if let driver {
                    try await driver.createBugReport(update: update)
                } else {
                    try await Self.playBugReport(update)
                }
                // The host's records travel inside Android's own report.
                if let diagnosticsDirectory {
                    _ = await Task.detached(priority: .userInitiated) {
                        BugReportAttachments.attach(
                            to: file, from: diagnosticsDirectory, containers: diagnosticsContainers)
                    }.value
                }
                return file
            },
            finished: { [weak self] file in self?.share(file) }
        )
    }

    /// Opens the share sheet on a finished report; false when there is no
    /// window to show it. A test puts its own here.
    var presentShare: (URL, @escaping @MainActor () -> Void) -> Bool = { file, finished in
        BugReportSharing.present(file, finished: finished)
    }

    /// The report is deleted on every outcome of the sheet.
    private func share(_ file: URL) {
        let shown = presentShare(file) { try? FileManager.default.removeItem(at: file) }
        if !shown { try? FileManager.default.removeItem(at: file) }
    }

    /// The preview's report: the same steps on the same overlay, ending in
    /// the share sheet with a small file.
    private static func playBugReport(_ update: @Sendable (BusyUpdate) -> Void) async throws -> URL {
        for step in 1...36 {
            try await Task.sleep(for: .milliseconds(100))
            update(BusyUpdate(progress: Double(step) / 36 * 0.9))
        }
        update(BusyUpdate(progress: 0.9, detail: "Copying the report\u{2026}"))
        for step in 1...8 {
            try await Task.sleep(for: .milliseconds(100))
            update(BusyUpdate(progress: 0.9 + 0.1 * Double(step) / 8))
        }
        try FileManager.default.createDirectory(at: BugReportStaging.directory, withIntermediateDirectories: true)
        let file = BugReportStaging.directory.appendingPathComponent("bugreport-preview.zip")
        // An empty zip: its end-of-central-directory record.
        try Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18)).write(to: file)
        return file
    }

    /// Install APK: `url` is what the Files picker returned. Settings has
    /// dismissed and the install runs behind the overlay, which stays up at the
    /// end with how it went until the person closes it. A file that is not a
    /// single .apk is refused on the same overlay, at once. The file's security
    /// scope is held to the end of the install.
    func installPicked(_ url: URL) {
        guard busy == nil else { return }
        let name = url.lastPathComponent
        if let refusal = InstallRefusal(fileName: name) {
            busy = ended(title: Self.installFailure, detail: refusal.message, failed: true)
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let size = UInt64(max(bytes, 0))
        runOperation(
            BusyState(
                title: "Installing app",
                detail: "\(name) \u{00B7} \(Formats.size(bytes: size))", progress: 0
            ),
            failure: Self.installFailure,
            ending: { _ in (title: "App installed", detail: "\(name) is installed in the guest.") },
            { [driver] update in
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let driver {
                    try await driver.installApk(at: url, sizeBytes: bytes, update: update)
                } else {
                    try await Self.playInstall(update)
                }
                // 100% for a moment, then the result.
                update(BusyUpdate(progress: 1))
                try? await Task.sleep(for: .milliseconds(500))
            }
        )
    }

    /// Flash ZIP: `url` is what the Files picker returned. Android restarts
    /// into recovery, which reads the package behind the overlay; the overlay
    /// then says what recovery asks on its own screen, where the install
    /// itself is confirmed and shown. The file's security scope is held until
    /// recovery no longer reads the package.
    func flashPicked(_ url: URL) {
        guard busy == nil, case .running(.normal) = phase else { return }
        let name = url.lastPathComponent
        guard name.lowercased().hasSuffix(".zip") else {
            busy = ended(title: Self.flashFailure, detail: "Choose a file that ends in .zip.", failed: true)
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        let release: @Sendable () -> Void = { if scoped { url.stopAccessingSecurityScopedResource() } }
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        operationSurvivesRestart = true
        runOperation(
            BusyState(
                title: "Flashing package",
                detail: "\(name) \u{00B7} \(Formats.size(bytes: UInt64(max(bytes, 0))))", progress: 0
            ),
            failure: Self.flashFailure,
            ending: { _ in
                (title: "Package sent",
                 detail: "Recovery installs it now. Answer what it asks on its screen and, when it has finished, "
                    + "choose Reboot system now.")
            },
            { [driver] update in
                if let driver {
                    try await driver.flashZip(at: url, sizeBytes: bytes, update: update, finished: release)
                } else {
                    release()
                    try await Self.playInstall(update)
                }
            }
        )
    }

    /// The title of a flash that did not happen.
    static let flashFailure = "Package not flashed"

    /// The title of an install that did not happen.
    static let installFailure = "App not installed"

    /// The preview's install: the file goes over, the guest takes its time.
    private static func playInstall(_ update: @Sendable (BusyUpdate) -> Void) async throws {
        for step in 1...20 {
            try await Task.sleep(for: .milliseconds(100))
            update(BusyUpdate(progress: Double(step) / 20 * 0.8))
        }
        update(BusyUpdate(detail: "The guest is installing the app\u{2026}", cancellable: false))
        try await Task.sleep(for: .milliseconds(1200))
    }

    /// Starts the guest in `mode`. Start on an update that did not finish
    /// tries the update again.
    func start(_ mode: StartMode) {
        switch lifecycle.start(mode, host: host, plan: plan) {
        case let .allowed(kind):
            frozenBootStage = nil
            bootTracker = BootTracker()
            preparingDisk = false
            diskProgress = nil
            if case let .update(from, _) = plan { bootFrom = from } else { bootFrom = nil }
            if let driver, let guest {
                persistNow()
                driver.begin(guest: guest, mode: mode, kind: kind)
            }
        case .lowSpace: startBlocked = true
        // The screens offer no start the plan refuses (`StartPlan.allowsStart`),
        // so one that arrives anyway, from a keyboard or a launch, is ignored
        // without a message: Home already says what the guest waits for.
        case .unfinishedUpdate, .blocked: break
        case .needsNewerChip:
            alert = AppAlert(title: DeviceRequirement.title, message: DeviceRequirement.explanation(deviceName: host.name))
        case .noGuest: break
        case .relaunchRequired: break
        }
    }

    func finishBoot(_ kind: BootKind) {
        let firstStart = plan == .firstStart
        lifecycle.finishBoot(kind)
        if driver != nil {
            persistNow()
        } else if kind != .recovery {
            // The preview plays the instance too: the first start sets
            // Android up, and an update or a retry ends.
            plan = .normal
            if firstStart {
                sessionPreset.guestScreen = .setup
                guest?.usedBytes = UInt64(2.1 * Double(Limits.bytesPerGiB))
            }
        }
    }

    func powerOff() {
        runEnded(RunEnd(result: 0), uptimeSeconds: nil)
    }

    func fail(_ end: RunEnd = RunEnd(result: -11), uptimeSeconds: Int? = 2530) {
        runEnd = end
        runUptimeSeconds = uptimeSeconds
        lifecycle.fail()
    }

    /// The runtime's run returned: the guest powered off, or stopped for a
    /// reason the failure screen reports.
    func runEnded(_ end: RunEnd, uptimeSeconds: Int?) {
        abandonOperation()
        endAdbOverNetwork()
        spacePause = nil
        graphicsNotice = GraphicsNotice()
        graphicsReclaim.reset()
        runEnd = end
        runUptimeSeconds = uptimeSeconds
        if end.poweredOff {
            sheet = nil
            sessionPreset = SessionPreset()
            let showStats = session.showStats
            session = SessionState()
            session.showStats = showStats
        }
        lifecycle.phase = end.phase
        // The run changed the data disk: what Home states of the storage is
        // what the disk holds now, not what it held when the guest loaded.
        if let driver { lifecycle.guest?.usedBytes = driver.measuredUsedBytes() }
        persistNow()
        refreshPlan()
    }

    /// Android's own Restart boots the guest again in place. ADB and the
    /// install list belong to the run that ended.
    func restart() {
        // A flash asks for this restart itself and goes on in recovery.
        if !operationSurvivesRestart { abandonOperation() }
        endAdbOverNetwork()
        spacePause = nil
        graphicsNotice = GraphicsNotice()
        graphicsReclaim.reset()
        frozenBootStage = nil
        sessionPreset = SessionPreset()
        let showStats = session.showStats
        session = SessionState()
        session.showStats = showStats
        statisticsMeter = StatsMeter()
        bootTracker = BootTracker()
        lifecycle.restart()
    }

    func factoryReset() {
        lifecycle.factoryReset()
        // Only the preview knows the data is empty; on a device the data
        // disk stays and Android sets itself up again by itself.
        if driver == nil { plan = .firstStart }
        persistNow()
    }

    /// The Gyroscope switch as the screens show it: the guest's choice, which
    /// is on until the person turns it off, and only where the device has
    /// sensors to share.
    var motionSensorsOn: Bool { guest?.motionSensorsOn(available: motionSensorsAvailable) == true }

    /// The Gyroscope switch. It asks for nothing and is kept as chosen; on a
    /// device without sensors there is nothing to turn on.
    func setMotionSensors(_ on: Bool) {
        guard guest != nil, !on || motionSensorsAvailable else { return }
        guest?.motionChoice = on
        persistNow()
        driver?.setMotionSensors(on)
    }

    /// The Microphone switch as the screens show it: the guest's choice is on
    /// and iOS lets Andarium record. Access that was refused or taken away
    /// shows it off, and the guest hears nothing then.
    var microphoneShownOn: Bool { guest?.microphone == true && microphoneState != .denied }

    /// The Microphone switch. Turning it on asks iOS for access at once, the
    /// first time. After a refusal there is nothing to ask: the person is told
    /// and offered Andarium's page in Settings.
    func setMicrophone(_ on: Bool) {
        guard guest != nil else { return }
        guard on else {
            microphoneAwaitsSettings = false
            guest?.microphone = false
            persistNow()
            microphone?.setOn(false)
            return
        }
        switch microphoneState {
        case .denied:
            permissionPrompt = .microphone
        case .notAsked:
            guest?.microphone = true
            persistNow()
            // The controller asks iOS and reports the answer to
            // `microphoneAccessChanged`. A preview without one has no system
            // prompt to show and takes it as given.
            if let microphone { microphone.setOn(true) } else { microphoneAccessChanged(.granted) }
        case .granted:
            guest?.microphone = true
            persistNow()
            microphone?.setOn(true)
        }
    }

    /// iOS answered the microphone question, or the person changed Andarium's
    /// access in Settings. A refusal takes the choice back with it; access the
    /// person went to Settings to give turns the switch they tapped on.
    func microphoneAccessChanged(_ state: MicrophoneState) {
        microphoneState = state
        switch state {
        case .denied:
            if guest?.microphone == true {
                guest?.microphone = false
                persistNow()
            }
        case .granted:
            if microphoneAwaitsSettings, guest != nil, guest?.microphone != true {
                guest?.microphone = true
                persistNow()
            }
        case .notAsked:
            break
        }
        if state != .notAsked { microphoneAwaitsSettings = false }
    }

    /// The alert's Open Settings.
    func openMicrophoneSettings() {
        microphoneAwaitsSettings = true
        openSettings()
    }

    // MARK: Statistics

    /// A view that shows the statistics appears or goes. The readings run
    /// while some view shows them and everything else allows
    /// (`StatsSampling.isWanted`), and one loop serves every view.
    func statistics(_ viewer: StatisticsViewer, visible: Bool) {
        if visible {
            statisticsViewers.insert(viewer)
        } else {
            statisticsViewers.remove(viewer)
        }
        refreshStatistics()
    }

    private var statisticsWanted: Bool {
        var running = false
        if case .running = phase { running = true }
        return StatsSampling.isWanted(
            viewers: statisticsViewers.count, applicationActive: applicationActive,
            capable: capabilities.statistics, hasDriver: driver != nil, running: running
        )
    }

    /// Starts the loop when the readings are wanted and none runs, and stops
    /// it when they are not.
    func refreshStatistics() {
        if statisticsWanted {
            guard statisticsTask == nil else { return }
            statisticsGeneration += 1
            let generation = statisticsGeneration
            statisticsTask = Task { [weak self] in
                await self?.runStatisticsLoop()
                if let self, self.statisticsGeneration == generation { self.statisticsTask = nil }
            }
        } else if let task = statisticsTask {
            task.cancel()
            statisticsTask = nil
            statisticsGeneration += 1
        }
    }

    /// Two readings a moment apart, so figures show within about a third of
    /// a second, and the guest's memory after the second. Then a reading
    /// every second and the memory with every other one. A result that
    /// arrives after the loop was stopped is dropped.
    private func runStatisticsLoop() async {
        guard let driver else { return }
        statisticsMeter.pause()
        var readings = 0
        while !Task.isCancelled, statisticsWanted {
            if let sample = await driver.readStatistics(), !Task.isCancelled {
                statisticsMeter.record(sample)
                readings += 1
                if readings.isMultiple(of: StatsSampling.memoryEvery) {
                    if let memory = await driver.readGuestMemory(), !Task.isCancelled {
                        statisticsMeter.record(memory: memory)
                    }
                }
                publishStatistics()
            }
            guard !Task.isCancelled else { return }
            await statisticsSleep(readings == 1 ? StatsSampling.firstGap : StatsSampling.interval)
        }
    }

    private func publishStatistics() {
        session.readout = Readout(statisticsMeter)
        #if !APP_STORE
        if printsStatistics {
            print(ConsoleReport.statistics(statisticsMeter, guestMemoryMiB: guest?.memoryMiB ?? 0))
        }
        #endif
    }

    // MARK: Graphics notice

    /// The count is read while a normal session runs in the foreground, with
    /// or without a view of the statistics: the notice is for a person who
    /// is using the guest. Recovery runs no app that could lose its
    /// graphics.
    private var graphicsNoticeWanted: Bool {
        guard case .running(.normal) = phase else { return false }
        return applicationActive && capabilities.statistics && driver != nil
    }

    /// Starts reading the refusal count when it is wanted and stops when it
    /// is not. The count is the runtime's for the whole launch, so a reading
    /// after a pause finds what was refused meanwhile.
    func refreshGraphicsNotice() {
        if graphicsNoticeWanted {
            guard graphicsNoticeTask == nil else { return }
            graphicsNoticeGeneration += 1
            let generation = graphicsNoticeGeneration
            graphicsNoticeTask = Task { [weak self] in
                await self?.runGraphicsNoticeLoop()
                if let self, self.graphicsNoticeGeneration == generation { self.graphicsNoticeTask = nil }
            }
        } else if let task = graphicsNoticeTask {
            task.cancel()
            graphicsNoticeTask = nil
            graphicsNoticeGeneration += 1
        }
    }

    private func runGraphicsNoticeLoop() async {
        guard let driver else { return }
        while !Task.isCancelled, graphicsNoticeWanted {
            if let refusals = await driver.readGraphicsRefusals(), !Task.isCancelled {
                graphicsNotice.record(refusals: refusals, at: graphicsNoticeClock())
            }
            guard !Task.isCancelled else { return }
            await reclaimGraphicsMemory(with: driver)
            guard !Task.isCancelled else { return }
            await graphicsNoticeSleep(GraphicsNotice.pollInterval)
        }
    }

    /// One look at the graphics memory budget: when it stays nearly full or
    /// the guest was refused, ends the cached app that holds the most of it.
    /// Silent, and nothing at all while the kernel names no process.
    private func reclaimGraphicsMemory(with driver: RuntimeDriver) async {
        guard
            let reading = await driver.readGraphicsMemory(
                minimumIdle: GraphicsReclaim.minimumIdle, minimumBytes: GraphicsReclaim.minimumHolderBytes),
            !Task.isCancelled
        else { return }
        guard graphicsReclaim.observe(reading, at: graphicsNoticeClock()) else { return }
        let result = await driver.reclaimGraphicsMemory(reading, using: graphicsReclaim)
        graphicsReclaim.record(result, at: graphicsNoticeClock())
    }

    /// The person dismisses the notice.
    func dismissGraphicsNotice() {
        graphicsNotice.dismiss()
    }

    /// The Simulator preview plays a refusal: it has no runtime to count one.
    func previewGraphicsNotice() {
        let now = graphicsNoticeClock()
        graphicsNotice.record(refusals: 0, at: now)
        graphicsNotice.record(refusals: 1, at: now)
    }

    /// The step of the boot under way, from the runtime's milestones.
    func liveBootStage() -> Int {
        BootSteps.current(preparingDisk: preparingDisk, milestone: bootTracker.milestone)
    }

    /// The failure screen's copyable report.
    var runReport: String {
        runEnd.report(
            appVersion: system.appVersion, system: system, guest: guest, uptimeSeconds: runUptimeSeconds
        )
    }
}
