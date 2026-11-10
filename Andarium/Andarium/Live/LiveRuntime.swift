// SPDX-License-Identifier: GPL-2.0-or-later

import AndariumCore
import Foundation
import Observation
import UIKit

/// The guest console, read on the runtime's thread for the boot's milestones.
nonisolated final class ConsoleSink: @unchecked Sendable {
    private let lock = NSLock()
    private var scanner = ConsoleScanner()
    private let report: @Sendable ([BootMilestone], Bool) -> Void

    /// `report` gets the milestones a chunk completes and whether Android
    /// reported `sys.boot_completed` in it.
    init(report: @escaping @Sendable ([BootMilestone], Bool) -> Void) {
        self.report = report
    }

    func feed(_ data: Data) {
        let (found, completed) = lock.withLock { () -> ([BootMilestone], Bool) in
            let before = scanner.bootCompletedCount
            let found = scanner.feed(data)
            return (found, scanner.bootCompletedCount > before)
        }
        if !found.isEmpty || completed { report(found, completed) }
    }
}

/// A run the model asked for, waiting for the disk and the display.
private struct PendingRun {
    var guest: Guest
    var mode: StartMode
    var kind: BootKind
}

/// The device application behind the screens: the guest's storage, and the
/// runtime that runs it. Each run has a thread of its own,
/// into the display view the screens keep alive.
@MainActor
final class LiveRuntime: RuntimeDriver {
    /// The loader's flavour for the Android runtime.
    private static let androidFlavor: UInt32 = 1
    /// Android's power key held this long raises its power menu.
    nonisolated private static let powerMenuHold = 0.8

    private weak var model: AppModel?
    private let storage: TwoDiskStorage
    /// Android reached `sys.boot_completed` in the boot under way, which a
    /// clean end records. Recovery never does.
    private var reachedBootCompleted = false
    private let pause: PauseController
    /// Counts the time the guest runs, for the limits of adb operations: it
    /// stops while the application holds the guest paused.
    private let clock = GuestRunClock()
    private let keyStore: AdbKeyStore
    /// Where the runtime records how each session ends, for the next launch.
    private let sessionRecord: URL?
    /// The guest's adb key, made before the start that boots with it.
    private var adbIdentity: AdbKeyStore.Identity?
    private let motion = MotionSensors()
    /// The interface orientation the sensors' axes are mounted to.
    private var motionMount = MotionMount()
    private lazy var rotation = GuestRotationController(
        apply: { [weak self] policy in
            guard let self else { throw CancellationError() }
            let result = try await operations.shell(policy.command, limit: .seconds(15))
            guard result.exitCode == 0 else {
                print("Andarium: display rotation command failed: \(result.text)")
                throw AdbFailure(message: "The guest’s screen could not follow this window. Close and reopen Andarium to try again.")
            }
        }, changed: { [weak self] in
            self?.updateMotionSensors()
        }, failure: { [weak self] error in
            print("Andarium: display rotation unavailable: \(error)")
            guard let model = self?.model, model.alert == nil else { return }
            model.alert = AppAlert(
                title: "Display rotation unavailable",
                message: "The guest’s screen could not follow this window. Close and reopen Andarium to try again.")
        })
    private var normalRun = false
    /// The runtime runs a guest, from its start until its run returns.
    private var runActive = false
    private var active = UIApplication.shared.applicationState == .active
    /// The device's free space, which the run watches. The application's
    /// own reading unless a test supplies another.
    private let freeSpace: @Sendable () -> UInt64
    private var spaceWatchTask: Task<Void, Never>?
    /// Tells a watch that ended from the one that replaced it.
    private var spaceWatchGeneration = 0
    /// The person asked to shut a guest paused for space down: Android is
    /// not asked anything else, and the space is not watched, as it goes.
    private var shuttingDown = false
    /// The screen over the session says the space is short, whether Android
    /// is paused or still runs behind it: the space is not watched, and the
    /// guest is asked nothing, until the person answers it.
    private var spaceAlertOpen = false
    private var observers: [NSObjectProtocol] = []
    /// Writes what the person sets, for the next launch.
    private let preferences: PreferenceKeeper

    private var pending: PendingRun?
    private var launching = false
    private var preparing = false
    private var view: GuestMetalView?
    private var geometry: GuestDisplayGeometry?
    private var bootStartedAt = Date()
    private var runStartedAt: Date?
    private var thermalObserver: NSObjectProtocol?
    private var console: ConsoleSink?

    init(
        model: AppModel, storage: TwoDiskStorage, marker: PauseMarker, keyStore: AdbKeyStore = AdbKeyStore(),
        sessionRecord: URL? = nil,
        freeSpace: @escaping @Sendable () -> UInt64 = { AppEntry.freeStorageBytes() }
    ) {
        self.model = model
        self.preferences = PreferenceKeeper(model: model)
        self.storage = storage
        self.keyStore = keyStore
        self.sessionRecord = sessionRecord
        self.freeSpace = freeSpace
        let effects = LivePauseEffects()
        pause = PauseController(effects: effects, marker: marker, runClock: clock)
        effects.statistics = { [weak self] in await self?.readStatistics() }
        model.microphone = MicrophoneController(model: model, source: SystemMicrophoneSource()) {
            // The runtime is told the setting and never asks the system
            // itself; a guest records silence while access is out of reach.
            _ = kernarium_runtime_loader_set_microphone($0 ? 1 : 0)
        }
        model.motionSensorsAvailable = motion.available
        motion.problem = { [weak model] in model?.motionSensorsProblem = $0 }
        observeLifecycle()
        observeRotationPolicy()
        preferences.start()
    }

    // MARK: Storage

    func create(_ guest: Guest, progress: @escaping @Sendable (Double) -> Void) async throws -> Guest {
        defer { model?.host.freeStorageBytes = AppEntry.freeStorageBytes() }
        return try await storage.create(guest, progress: progress)
    }

    func erase(progress: @escaping @Sendable (Double) -> Void) async throws {
        defer { model?.host.freeStorageBytes = AppEntry.freeStorageBytes() }
        try await storage.erase(progress: progress)
        // The next guest is a new one: it boots with a key of its own.
        keyStore.delete()
        adbIdentity = nil
    }

    func save(_ guest: Guest) throws {
        try storage.save(guest)
    }

    // MARK: Starting

    func startPlan() -> StartPlan? {
        storage.startPlan()
    }

    func measuredUsedBytes() -> UInt64 {
        storage.measuredUsedBytes()
    }

    func restoreUpdate() throws {
        defer { model?.host.freeStorageBytes = AppEntry.freeStorageBytes() }
        try storage.restoreUpdate()
    }

    func begin(guest: Guest, mode: StartMode, kind: BootKind) {
        // The previous display is removed on return to Home. Wait for the
        // new boot's view to lay out before starting another runtime.
        view = nil
        geometry = nil
        pending = PendingRun(guest: guest, mode: mode, kind: kind)
        launching = false
        startIfReady()
    }

    /// The display view has a size. The first layout after a run is wanted
    /// starts it.
    func viewDidLayout(_ view: GuestMetalView, _ geometry: GuestDisplayGeometry) {
        // Removing the guest screen can lay it out once more. A completed
        // run must not take ownership of that retired view again.
        guard pending != nil || launching else { return }
        self.view = view
        self.geometry = geometry
        startIfReady()
    }

    private func startIfReady() {
        guard let run = pending, !launching, view != nil, geometry != nil else { return }
        pending = nil
        launching = true
        Task { await prepareAndLaunch(run) }
    }

    private func prepareAndLaunch(_ run: PendingRun) async {
        preparing = true
        do {
            try await storage.prepareStart(run.guest) { fraction in
                Task { @MainActor in self.preparingDisk(fraction) }
            }
        } catch {
            preparing = false
            end(startFailure: "the disk could not be prepared: \(error.localizedDescription)")
            return
        }
        // The guest's adb key, made here when there is none: generating it
        // takes a moment and the main thread does not wait for it. Without
        // one the guest still boots; its adb features then say why they fail.
        let store = keyStore
        adbIdentity = await Task.detached(priority: .userInitiated) { () -> AdbKeyStore.Identity? in
            do {
                return try store.loadOrCreate()
            } catch {
                print("Andarium: the adb key could not be made: \(error)")
                return nil
            }
        }.value
        preparing = false
        model?.preparingDisk = false
        guard let view, let geometry else {
            end(startFailure: "the display is not ready")
            return
        }
        launch(run, view: view, geometry: geometry)
    }

    private func preparingDisk(_ fraction: Double) {
        guard preparing, let model else { return }
        model.preparingDisk = true
        model.diskProgress = fraction
    }

    private func end(startFailure: String) {
        print("Andarium: cannot start the guest: \(startFailure)")
        model?.runEnded(RunEnd(result: -1, startFailure: startFailure), uptimeSeconds: nil)
    }

    private func launch(_ run: PendingRun, view: GuestMetalView, geometry: GuestDisplayGeometry) {
        guard kernarium_runtime_loader_select(Self.androidFlavor) == 0 else {
            end(startFailure: "the runtime could not be loaded")
            return
        }
        // The runtime boots a guest that restarts itself again inside the
        // run, and says when. The loader delivers each event on the main
        // queue.
        kernarium_runtime_loader_set_restart_handler { @Sendable [weak self] event, restartCount in
            guard let restart = GuestRestartEvent(event: event, restartCount: restartCount) else { return }
            MainActor.assumeIsolated { self?.guestRestarted(restart) }
        }
        let sink = ConsoleSink { milestones, bootCompleted in
            Task { @MainActor in self.reached(milestones, bootCompleted: bootCompleted) }
        }
        console = sink
        kernarium_runtime_loader_set_console_output_handler { data in sink.feed(data) }
        // A Microphone setting the person turned on earlier follows the
        // guest while iOS still allows it; otherwise the guest hears nothing.
        model?.microphone?.guestStarting()

        pause.guestDidStart()
        runActive = true
        shuttingDown = false
        bootStartedAt = Date()
        runStartedAt = Date()
        startThermalObservation()
        let size = GuestInputCoordinateSpace.boundedDisplaySize(geometry.pixelSize)
        let width = UInt32(size.width.rounded(.down))
        let height = UInt32(size.height.rounded(.down))
        view.setGuestDisplay(width: width, height: height)
        UIApplication.shared.isIdleTimerDisabled = true

        let dataDiskPath = storage.dataDiskPath
        let releasePath = storage.releaseDirectory.path
        let dataGiB = storage.dataGiB(for: run.guest)
        reachedBootCompleted = false
        normalRun = run.mode == .normal
        motionMount.begin(interface: interfaceMotionAxes)
        let bootMode: UInt32 = run.mode == .recovery ? 2 : 1
        let memoryMiB = UInt32(run.guest.memoryMiB)
        let processorCount = UInt32(run.guest.cores)
        let dotsPerInch = geometry.dotsPerInch
        let adbKeyLine = adbIdentity?.publicKeyLine
        // The zone the host is in now, read at every start: the guest follows
        // it while its own automatic time zone is on.
        let timeZone = GuestTimeZone.current()
        let sessionRecordPath = sessionRecord?.path
        // The run occupies its thread for the guest's whole life and the GPU
        // service reaches the main queue while it starts, so it must not be
        // the main thread. It owns a thread outright rather than a place on
        // the cooperative pool it would block for hours.
        let worker = Thread {
            let result = Self.runGuest(
                view: view, dataDiskPath: dataDiskPath, releasePath: releasePath, dataGiB: dataGiB, bootMode: bootMode,
                width: width, height: height, dotsPerInch: dotsPerInch, memoryMiB: memoryMiB,
                processorCount: processorCount, adbKeyLine: adbKeyLine, timeZone: timeZone,
                sessionRecordPath: sessionRecordPath
            )
            Task { @MainActor in self.finished(result: result) }
        }
        worker.name = "andarium-runtime"
        worker.start()
    }

    private nonisolated static func runGuest(
        view: GuestMetalView, dataDiskPath: String, releasePath: String, dataGiB: UInt32, bootMode: UInt32,
        width: UInt32, height: UInt32, dotsPerInch: UInt32, memoryMiB: UInt32,
        processorCount: UInt32, adbKeyLine: String?, timeZone: String?, sessionRecordPath: String?
    ) -> Int32 {
        dataDiskPath.withCString { dataDisk in
            releasePath.withCString { release in
                withOptionalCString(adbKeyLine) { adbKey in
                    withOptionalCString(timeZone) { zone in
                        withOptionalCString(sessionRecordPath) { record in
                            var request = kernarium_runtime_boot()
                            request.struct_size = UInt32(MemoryLayout<kernarium_runtime_boot>.size)
                            request.width = width
                            request.height = height
                            request.dots_per_inch = dotsPerInch
                            request.guest_memory_mib = memoryMiB
                            request.guest_processor_count = processorCount
                            request.android_boot_mode = bootMode
                            // The guest's display always follows the window.
                            request.auto_resize_guest = 1
                            request.android_data_disk_path = dataDisk
                            request.android_release_path = release
                            request.android_data_gib = dataGiB
                            // The conservative launch parameters the default memory was computed with.
                            let parameters = kernarium_runtime_loader_launch_memory_set()
                            request.gpu_budget_application_mib = parameters.application_mib
                            request.gpu_budget_engine_mib = parameters.engine_mib
                            request.gpu_budget_headroom_mib = parameters.headroom_mib
                            // The key adbd authorizes for this boot, or none.
                            request.android_adb_public_key = adbKey
                            // The host's time zone, which the guest applies while its
                            // own automatic time zone is on, or none.
                            request.android_time_zone = zone
                            // Where the runtime records how the session ends.
                            request.session_record_path = record
                            return withUnsafePointer(to: &request) { kernarium_runtime_loader_run(view, $0) }
                        }
                    }
                }
            }
        }
    }

    private nonisolated static func withOptionalCString<Output>(
        _ text: String?, _ body: (UnsafePointer<CChar>?) -> Output
    ) -> Output {
        guard let text else { return body(nil) }
        return text.withCString(body)
    }

    // MARK: Android operations

    /// What adb does for the screens, with the key this boot carries.
    private var operations: AdbGuestOperations {
        AdbGuestOperations(identity: adbIdentity, clock: clock, device: model?.host.name ?? "device")
    }

    func createBugReport(update: @escaping @Sendable (BusyUpdate) -> Void) async throws -> URL {
        try await operations.createBugReport(update: update)
    }

    func installApk(at url: URL, sizeBytes: Int, update: @escaping @Sendable (BusyUpdate) -> Void) async throws {
        try await operations.installApk(at: url, sizeBytes: sizeBytes, update: update)
    }

    func flashZip(
        at url: URL, sizeBytes: Int, update: @escaping @Sendable (BusyUpdate) -> Void,
        finished: @escaping @Sendable () -> Void
    ) async throws {
        try await operations.flashZip(at: url, sizeBytes: sizeBytes, update: update, finished: finished)
    }

    func usbDebugging() async -> Bool? {
        await operations.usbDebugging()
    }

    // MARK: ADB over network

    /// The listener on the network addresses, whose every connection is
    /// joined to a fresh stream to the guest's adbd.
    private let network = AdbNetworkBridge(opener: VsockConnector())

    func startAdbOverNetwork() throws {
        try network.start()
    }

    func stopAdbOverNetwork() {
        network.stop()
    }

    func localNetworkAddress() -> String? {
        LanAddress.current()
    }

    // MARK: Events

    private func reached(_ milestones: [BootMilestone], bootCompleted: Bool) {
        guard let model else { return }
        let seconds = Int(Date().timeIntervalSince(bootStartedAt))
        if bootCompleted {
            reachedBootCompleted = true
            updateGuestRotation()
            updateSpaceWatch()
            // An update counts as applied once its start has booted, whatever
            // happens to the application after that.
            do { try storage.bootCompleted() } catch { print("Andarium: the guest's record was not updated: \(error.localizedDescription)") }
        }
        for milestone in milestones where model.bootTracker.reach(milestone, atSeconds: seconds) {
            print("Andarium: boot reached \(milestone) at \(seconds) s")
        }
    }

    private func guestRestarted(_ event: GuestRestartEvent) {
        print("Andarium: \(event)")
        guard case .began = event, let model else { return }
        // The boot that follows is another one: it ends an update only by
        // reaching sys.boot_completed itself.
        reachedBootCompleted = false
        spaceAlertOpen = false
        motion.stop()
        updateGuestRotation()
        updateSpaceWatch()
        switch model.phase {
        case .running, .booting:
            bootStartedAt = Date()
            model.restart()
        default:
            break
        }
    }

    private func finished(result: Int32) {
        normalRun = false
        runActive = false
        shuttingDown = false
        spaceAlertOpen = false
        motion.stop()
        updateGuestRotation()
        updateSpaceWatch()
        stopThermalObservation()
        kernarium_runtime_loader_set_restart_handler(nil)
        kernarium_runtime_loader_set_console_output_handler(nil)
        console = nil
        pause.guestDidEnd()
        view = nil
        geometry = nil
        launching = false
        UIApplication.shared.isIdleTimerDisabled = false
        #if !APP_STORE
        print(ConsoleReport.runtimeReturned(result))
        #endif
        // A start that reached sys.boot_completed and ended with Android's own
        // power-off is a completed one (`lastCompleted`); the pending update it
        // may have started ended when the start booted.
        if result == 0, reachedBootCompleted {
            do { try storage.completeRun() } catch { print("Andarium: the guest's record was not updated: \(error.localizedDescription)") }
        }
        let uptime = runStartedAt.map { Int(Date().timeIntervalSince($0)) }
        runStartedAt = nil
        // The run wrote to the data disk, so the device has less free space
        // than before it.
        model?.host.freeStorageBytes = freeSpace()
        let loop = result == Int32(KERNARIUM_RUNTIME_RESULT_RESTART_LOOP)
        model?.runEnded(RunEnd(result: result, restartedInALoop: loop), uptimeSeconds: uptime)
    }

    // MARK: Keys

    func press(_ key: GuestKey) {
        guard !holdsGuestStill else { return }
        kernarium_runtime_loader_send_key(key.rawValue, 1)
        kernarium_runtime_loader_send_key(key.rawValue, 0)
    }

    /// Holds the key down for `seconds`, as Power is for Android's power menu.
    func hold(_ key: GuestKey, seconds: Double = LiveRuntime.powerMenuHold) {
        guard !holdsGuestStill else { return }
        kernarium_runtime_loader_send_key(key.rawValue, 1)
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            kernarium_runtime_loader_send_key(key.rawValue, 0)
        }
    }

    // MARK: Motion sensors

    /// The interface orientation of the guest's window; nil while the display
    /// is not in a scene, which leaves the mount as it is.
    private var interfaceMotionAxes: MotionSample.Axes? {
        guard let scene = view?.window?.windowScene else { return nil }
        return switch scene.effectiveGeometry.interfaceOrientation {
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        case .portraitUpsideDown: .portraitUpsideDown
        default: .portrait
        }
    }

    private var rotationPolicy: GuestRotationPolicy {
        model?.hostDrivesGuestRotation == true ? .host : .guest
    }

    /// The scene's geometry changed, which may include its interface
    /// orientation. The hosting controller coalesces its triggers into one call
    /// per turn, and the mount restarts the sensors only when it moves.
    func sceneGeometryDidChange() {
        guard normalRun else { return }
        updateGuestRotation()
    }

    private func updateGuestRotation() {
        let policy = rotationPolicy
        // A new full-screen session mounts the virtual device to the
        // orientation now locked by UIKit and keeps that frame until the host
        // owns rotation; while the host does, the guest is drawn upright in
        // the window and the mount follows the window's orientation. Never
        // remap per sensor sample.
        if motionMount.update(policy: policy, interface: interfaceMotionAxes) { motion.restart() }
        rotation.update(policy: policy, ready: normalRun && reachedBootCompleted && active && !holdsGuestStill)
        updateMotionSensors()
    }

    func setMotionSensors(_ on: Bool) {
        model?.motionSensorsProblem = nil
        updateMotionSensors()
    }

    private func updateMotionSensors() {
        motion.update(
            enabled: model?.motionSensorsOn == true,
            foreground: normalRun && reachedBootCompleted && active && !holdsGuestStill
                && rotation.applied == rotationPolicy,
            axes: motionMount.axes
        )
    }

    // MARK: Microphone

    // MARK: Statistics

    /// Both readings are made on one serial queue of their own: the memory
    /// request waits for the guest and neither runs on the main thread or on
    /// the cooperative pool, and two never overlap.
    private let statsQueue = DispatchQueue(label: "com.imxieyi.andarium.stats", qos: .utility)

    func readStatistics() async -> StatsSample? {
        await withCheckedContinuation { continuation in
            statsQueue.async { continuation.resume(returning: Self.statisticsReading()) }
        }
    }

    func readGraphicsRefusals() async -> UInt64? {
        await withCheckedContinuation { continuation in
            statsQueue.async { continuation.resume(returning: Self.graphicsRefusalsReading()) }
        }
    }

    func readGraphicsMemory(minimumIdle: Duration, minimumBytes: UInt64) async -> GraphicsMemoryReading? {
        let (seconds, attoseconds) = minimumIdle.components
        let idle = UInt32(clamping: max(seconds, 0) * 1000 + max(attoseconds, 0) / 1_000_000_000_000_000)
        return await withCheckedContinuation { continuation in
            statsQueue.async {
                continuation.resume(
                    returning: Self.graphicsMemoryReading(minimumIdleMilliseconds: idle, minimumBytes: minimumBytes))
            }
        }
    }

    func reclaimGraphicsMemory(_ reading: GraphicsMemoryReading, using policy: GraphicsReclaim) async
        -> GraphicsReclaimResult
    {
        await policy.reclaim(from: reading, shell: AdbGuestShell(operations: operations))
    }

    func readGuestMemory() async -> GuestMemorySample? {
        await withCheckedContinuation { continuation in
            statsQueue.async { continuation.resume(returning: Self.guestMemoryReading()) }
        }
    }

    private nonisolated static func graphicsMemoryReading(
        minimumIdleMilliseconds: UInt32, minimumBytes: UInt64
    ) -> GraphicsMemoryReading? {
        var reading = kernarium_runtime_graphics_memory()
        reading.struct_size = UInt32(MemoryLayout<kernarium_runtime_graphics_memory>.size)
        reading.minimum_idle_ms = minimumIdleMilliseconds
        reading.minimum_holder_bytes = minimumBytes
        guard kernarium_runtime_loader_read_graphics_memory(&reading) == 0 else { return nil }
        let count = Int(min(reading.holder_count, UInt32(KERNARIUM_RUNTIME_GRAPHICS_HOLDERS)))
        let holders = withUnsafeBytes(of: &reading.holders) { raw -> [GraphicsHolder] in
            let table = raw.bindMemory(to: kernarium_runtime_graphics_holder.self)
            return (0..<count).map { index in
                var entry = table[index]
                let name = withUnsafeBytes(of: &entry.name) { bytes in
                    String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
                }
                return GraphicsHolder(
                    pid: entry.pid, contexts: entry.context_count, bytes: entry.bytes,
                    idle: .milliseconds(entry.idle_ms), name: name)
            }
        }
        return GraphicsMemoryReading(
            budgetBytes: reading.budget_bytes, usageBytes: reading.usage_bytes, contextBytes: reading.context_bytes,
            refusals: reading.memory_refusals, guestReclaims: reading.guest_reclaims != 0, holders: holders)
    }

    private nonisolated static func graphicsRefusalsReading() -> UInt64? {
        var reading = kernarium_runtime_statistics()
        reading.struct_size = UInt32(MemoryLayout<kernarium_runtime_statistics>.size)
        guard kernarium_runtime_loader_read_statistics(&reading) == 0 else { return nil }
        return reading.gpu_memory_refusals
    }

    private nonisolated static func statisticsReading() -> StatsSample? {
        var reading = kernarium_runtime_statistics()
        reading.struct_size = UInt32(MemoryLayout<kernarium_runtime_statistics>.size)
        guard kernarium_runtime_loader_read_statistics(&reading) == 0 else { return nil }
        return StatsSample(
            bootIndex: reading.boot_index, processorCount: reading.processor_count,
            timestampNanoseconds: reading.timestamp_ns, processorTimeNanoseconds: reading.processor_time_ns,
            presentedFrames: reading.presented_frames, ramBytes: reading.memory_bytes,
            ramHeldBytes: reading.memory_held_bytes, gpuMemoryBudgetBytes: reading.gpu_memory_budget_bytes,
            gpuMemoryUsedBytes: reading.gpu_memory_used_bytes
        )
    }

    private nonisolated static func guestMemoryReading() -> GuestMemorySample? {
        var reading = kernarium_runtime_guest_memory()
        reading.struct_size = UInt32(MemoryLayout<kernarium_runtime_guest_memory>.size)
        guard kernarium_runtime_loader_read_guest_memory(&reading) == 0 else { return nil }
        return GuestMemorySample(totalBytes: reading.total_bytes, availableBytes: reading.available_bytes)
    }

    // MARK: Thermal state

    // The thermal state and uptime go to the console for the iPad harness
    // (`Shared/ConsoleReport.swift`); an App Store build prints neither and
    // reads neither the system uptime nor the thermal state.

    #if !APP_STORE
    private func reportThermalState(_ phase: ConsoleReport.ThermalPhase) {
        print(ConsoleReport.thermal(
            phase: phase, state: ProcessInfo.processInfo.thermalState,
            uptime: ProcessInfo.processInfo.systemUptime
        ))
    }
    #endif

    private func startThermalObservation() {
        #if !APP_STORE
        reportThermalState(.start)
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportThermalState(.change) }
        }
        #endif
    }

    private func stopThermalObservation() {
        #if !APP_STORE
        reportThermalState(.finish)
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
            self.thermalObserver = nil
        }
        #endif
    }

    // MARK: Free space

    /// A guest paused for space, or going down after it, is asked nothing: a
    /// request to it would wait, or fail as it goes. Nor is one the screen
    /// says the space is short for: the person decides what happens to it.
    private var holdsGuestStill: Bool { pause.isPausedForSpace || shuttingDown || spaceAlertOpen }

    /// The space is watched while Android runs a normal start it has booted
    /// and the application holds it in the foreground: before it has booted
    /// the start check stands for the space, and a guest the application
    /// paused for the background or for space needs no watching.
    private var wantsSpaceWatch: Bool {
        runActive && normalRun && reachedBootCompleted && !holdsGuestStill && pause.phase == .foreground
    }

    private func updateSpaceWatch() {
        guard wantsSpaceWatch else {
            spaceWatchTask?.cancel()
            spaceWatchTask = nil
            return
        }
        guard spaceWatchTask == nil else { return }
        spaceWatchGeneration += 1
        let generation = spaceWatchGeneration
        spaceWatchTask = Task { [weak self] in
            await self?.watchSpace()
            if let self, self.spaceWatchGeneration == generation { self.spaceWatchTask = nil }
        }
    }

    /// Reads the space now and then, as often as the guest could write what
    /// is left before the pause (`RunSpace.nextCheck`), and stops once it
    /// has paused the guest.
    private func watchSpace() async {
        while !Task.isCancelled {
            let free = await readFreeSpace()
            guard !Task.isCancelled, wantsSpaceWatch else { return }
            model?.host.freeStorageBytes = free
            if RunSpace.verdict(freeBytes: free) == .pause {
                pauseForSpace(freeBytes: free)
                return
            }
            try? await Task.sleep(for: RunSpace.nextCheck(freeBytes: free))
        }
    }

    private func pauseForSpace(freeBytes: UInt64) {
        guard pause.beginSpacePause() else { return }
        print("Andarium: the guest is pausing: \(Formats.size(bytes: freeBytes)) of the device's space is free")
        spaceAlertOpen = true
        motion.stop()
        updateGuestRotation()
        model?.guestPausingForSpace(freeBytes: freeBytes)
        Task { [weak self] in await self?.settleSpacePause() }
    }

    /// Suspends the guest and says what came of it: the screen offers Resume
    /// over a guest that holds still, and Shut down over one that did not.
    private func settleSpacePause() async {
        guard let outcome = await pause.settleSpacePause() else { return }
        switch outcome {
        case .held:
            print("Andarium: the guest is paused")
            model?.guestPausedForSpace()
        case .running:
            print("Andarium: the guest could not be paused")
            model?.guestNotPausedForSpace()
        }
    }

    /// The person asks to check the space and pause again, over a guest that
    /// did not pause. Returns whether there is enough space for it to run on,
    /// which takes the screen away; otherwise the guest is paused again.
    func checkSpaceAfterPauseFailed() async -> Bool {
        let free = await readFreeSpace()
        model?.host.freeStorageBytes = free
        guard !RunSpace.allowsResume(freeBytes: free) else {
            spaceAlertOpen = false
            updateGuestRotation()
            updateSpaceWatch()
            return true
        }
        guard pause.beginSpacePause() else { return false }
        await settleSpacePause()
        return false
    }

    /// One reading, off the main thread: the system works the figure out
    /// from the volume.
    private func readFreeSpace() async -> UInt64 {
        let source = freeSpace
        return await Task.detached(priority: .utility) { source() }.value
    }

    func resumeAfterSpacePause() async -> Bool {
        let free = await readFreeSpace()
        model?.host.freeStorageBytes = free
        guard RunSpace.allowsResume(freeBytes: free) else { return false }
        await wakeGuest()
        guard !pause.isPausedForSpace else { return false }
        print("Andarium: the guest resumes: \(Formats.size(bytes: free)) of the device's space is free")
        spaceAlertOpen = false
        updateGuestRotation()
        updateSpaceWatch()
        return true
    }

    func shutDownAfterSpacePause() async throws {
        shuttingDown = true
        await wakeGuest()
        guard !pause.isPausedForSpace else {
            shuttingDown = false
            throw AdbFailure(message: "Android is still paused.")
        }
        do {
            let result = try await operations.shell("reboot -p", limit: .seconds(30))
            if let code = result.exitCode, code != 0 {
                throw AdbFailure(message: "Android refused to power off (\(code)).")
            }
            // Android powers off after the command returns, which ends the
            // run; the screen goes with it. Until it has, it is going down.
            try await waitForRunToEnd(.seconds(120))
        } catch {
            // The shell's stream can end because the guest is already going
            // down: the run ending says so.
            if runActive { try? await waitForRunToEnd(.seconds(5)) }
            guard runActive else { return }
            shuttingDown = false
            spaceAlertOpen = false
            updateGuestRotation()
            updateSpaceWatch()
            throw error
        }
    }

    private func waitForRunToEnd(_ limit: Duration) async throws {
        let deadline = ContinuousClock.now + limit
        while runActive {
            guard ContinuousClock.now < deadline else {
                throw AdbFailure(message: "Android did not power off.")
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Wakes the guest the pause holds and returns once it is back.
    private func wakeGuest() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if !pause.resumeFromSpacePause(finished: { continuation.resume() }) { continuation.resume() }
        }
    }

    // MARK: Lifecycle

    private func observeLifecycle() {
        let edges: [(Notification.Name, @MainActor (LiveRuntime) -> Void)] = [
            (UIApplication.willResignActiveNotification, {
                #if !APP_STORE
                print(ConsoleReport.application(active: false))
                #endif
                $0.active = false
                $0.model?.applicationActive = false
                $0.motion.stop()
                $0.updateGuestRotation()
                $0.pause.willResignActive()
            }),
            (UIApplication.didEnterBackgroundNotification, {
                $0.pause.didEnterBackground()
                $0.updateSpaceWatch()
            }),
            (UIApplication.willEnterForegroundNotification, {
                $0.pause.willEnterForeground()
                $0.updateSpaceWatch()
            }),
            (UIApplication.willTerminateNotification, { $0.pause.willTerminate() }),
            (UIApplication.didBecomeActiveNotification, { $0.didBecomeActive() }),
        ]
        observers = edges.map { name, edge in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let self { edge(self) }
                }
            }
        }
    }

    /// The person may have changed the permissions or the storage while
    /// Andarium was away.
    private func didBecomeActive() {
        #if !APP_STORE
        print(ConsoleReport.application(active: true))
        #endif
        active = true
        updateGuestRotation()
        guard let model else { return }
        model.applicationActive = true
        let free = freeSpace()
        model.host.freeStorageBytes = free
        // A guest paused for space waits for the person, who may have made
        // room while Andarium was away: the screen says what is free now.
        if model.spacePause != nil { model.spacePause?.freeBytes = free }
        model.microphone?.refresh()
    }

    private func observeRotationPolicy() {
        guard let model else { return }
        withObservationTracking {
            _ = model.hostDrivesGuestRotation
        } onChange: {
            Task { @MainActor in
                guard self.model != nil else { return }
                self.updateGuestRotation()
                self.observeRotationPolicy()
            }
        }
    }
}

/// Pausing the guest on the real runtime. The runtime calls run on one serial
/// queue, in the order asked, so a quick return to the app resumes behind a
/// quiesce still in flight.
@MainActor
final class LivePauseEffects: PauseEffects {
    private let queue = DispatchQueue(label: "com.imxieyi.andarium.guest-sync", qos: .userInitiated)

    func holdGuestGPU() {
        let result = kernarium_runtime_loader_set_gpu_hold(1)
        print("Andarium: guest GPU requests held on background (\(result))")
    }

    func releaseGuestGPU() {
        let result = kernarium_runtime_loader_set_gpu_hold(0)
        print("Andarium: guest GPU requests released (\(result))")
    }

    func flushGuest(until deadline: DispatchTime?) {
        settle(reason: "inactive", quiesce: false, until: deadline)
    }

    func quiesceGuest(reason: String, until deadline: DispatchTime?) {
        settle(reason: reason, quiesce: true, until: deadline)
    }

    func resumeGuest(finished: @escaping @MainActor () -> Void) {
        queue.async {
            kernarium_runtime_loader_resume()
            Task { @MainActor in finished() }
        }
    }

    /// Writes the guest's storage back and suspends it with its RAM left in
    /// the process: the device is short of the space an image of it takes.
    func suspendGuestResident(reason: String, finished: @escaping @MainActor () -> Void) {
        let assertion = PauseTaskAssertion(named: "guest-sync")
        queue.async {
            let unflushed = kernarium_runtime_loader_quiesce_resident()
            Task { @MainActor in
                print("Andarium: guest storage settled on \(reason), RAM kept (\(unflushed) unflushed)")
                assertion.end()
                finished()
            }
        }
    }

    /// Set by the runtime that owns this: where the guest's statistics come
    /// from, on their own queue.
    var statistics: (@MainActor () async -> StatsSample?)?

    func guestProcessorTime() async -> UInt64? {
        await statistics?()?.processorTimeNanoseconds
    }

    /// Writes the guest's storage back, and suspends the guest when asked,
    /// under an assertion that keeps the process scheduled until it is done.
    private func settle(reason: String, quiesce: Bool, until deadline: DispatchTime?) {
        let assertion = PauseTaskAssertion(named: "guest-sync")
        let finished = DispatchSemaphore(value: 0)
        queue.async {
            let unflushed = quiesce ? kernarium_runtime_loader_quiesce() : kernarium_runtime_loader_sync()
            finished.signal()
            Task { @MainActor in
                if unflushed > 0 {
                    print("Andarium: \(reason) sync left \(unflushed) guest file(s) unflushed")
                } else if unflushed == 0 {
                    print("Andarium: guest storage settled on \(reason)")
                }
                assertion.end()
            }
        }
        if let deadline {
            _ = finished.wait(timeout: deadline)
        }
    }
}

/// A background-task assertion that keeps the process scheduled until it ends:
/// the caller ends it, or iOS expires it. Ending it twice is harmless.
@MainActor
final class PauseTaskAssertion {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(named name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
