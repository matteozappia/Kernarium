// SPDX-License-Identifier: GPL-2.0-or-later
import AndariumCore
import Foundation
import Testing
@testable import Andarium

/// A driver that answers with a fixed plan and records what the model asks.
@MainActor
final class StubDriver: RuntimeDriver {
    var plan: StartPlan?
    var begun: [(mode: StartMode, kind: BootKind)] = []
    var restored = 0
    var restoreFails = false

    init(plan: StartPlan?) { self.plan = plan }

    func create(_ guest: Guest, progress: @escaping @Sendable (Double) -> Void) async throws -> Guest { guest }
    private(set) var erased = 0
    var eraseFails = false
    func erase(progress: @escaping @Sendable (Double) -> Void) async throws {
        if eraseFails { throw InstanceError.refused("Nothing could be deleted.") }
        erased += 1
    }
    func save(_ guest: Guest) throws { savedGuest = guest }
    func startPlan() -> StartPlan? { plan }
    /// What the data disk holds now; a test sets it as a run would.
    var diskUsedBytes: UInt64 = 0
    func measuredUsedBytes() -> UInt64 { diskUsedBytes }
    func begin(guest: Guest, mode: StartMode, kind: BootKind) {
        begun.append((mode, kind))
    }
    func restoreUpdate() throws {
        if restoreFails { throw InstanceError.refused("No update is pending.") }
        restored += 1
        // The files now say the update waits for the next start.
        plan = .update(from: "r1", to: "r2")
    }
    var motionSensors = false
    var savedGuest: Guest?
    func setMotionSensors(_ on: Bool) { motionSensors = on }
    private(set) var geometryChanges = 0
    func sceneGeometryDidChange() { geometryChanges += 1 }

    /// What the statistics readings answer, in turn, the last one repeating;
    /// nothing until a test scripts them.
    var samples: [StatsSample?] = []
    var memories: [GuestMemorySample?] = []
    private(set) var statisticsAsked = 0
    private(set) var memoryAsked = 0
    func readStatistics() async -> StatsSample? {
        defer { statisticsAsked += 1 }
        guard !samples.isEmpty else { return nil }
        return samples[min(statisticsAsked, samples.count - 1)]
    }
    func readGuestMemory() async -> GuestMemorySample? {
        defer { memoryAsked += 1 }
        guard !memories.isEmpty else { return nil }
        return memories[min(memoryAsked, memories.count - 1)]
    }

    /// What the refusal-count readings answer, in turn, the last one
    /// repeating; nothing until a test scripts them.
    var refusalCounts: [UInt64?] = []
    private(set) var refusalsAsked = 0
    func readGraphicsRefusals() async -> UInt64? {
        defer { refusalsAsked += 1 }
        guard !refusalCounts.isEmpty else { return nil }
        return refusalCounts[min(refusalsAsked, refusalCounts.count - 1)]
    }

    /// What the graphics memory readings answer, in turn, the last one
    /// repeating; nothing until a test scripts them. A try to free memory
    /// records the reading it was given and answers `reclaimAnswer`.
    var graphicsMemories: [GraphicsMemoryReading?] = []
    private(set) var graphicsMemoryAsked = 0
    private(set) var graphicsMemoryFilters: [(idle: Duration, bytes: UInt64)] = []
    func readGraphicsMemory(minimumIdle: Duration, minimumBytes: UInt64) async -> GraphicsMemoryReading? {
        defer { graphicsMemoryAsked += 1 }
        graphicsMemoryFilters.append((minimumIdle, minimumBytes))
        guard !graphicsMemories.isEmpty else { return nil }
        return graphicsMemories[min(graphicsMemoryAsked, graphicsMemories.count - 1)]
    }
    var reclaimAnswer = GraphicsReclaimResult.nothingToEnd
    private(set) var reclaims: [GraphicsMemoryReading] = []
    func reclaimGraphicsMemory(_ reading: GraphicsMemoryReading, using policy: GraphicsReclaim) async
        -> GraphicsReclaimResult
    {
        reclaims.append(reading)
        return reclaimAnswer
    }

    /// What a bug report or an install does when the model asks.
    var bugReport: (@Sendable (@Sendable (BusyUpdate) -> Void) async throws -> URL) = { _ in
        throw CancellationError()
    }
    func createBugReport(update: @escaping @Sendable (BusyUpdate) -> Void) async throws -> URL {
        try await bugReport(update)
    }
    var install: (@Sendable (@Sendable (BusyUpdate) -> Void) async throws -> Void) = { _ in }
    private(set) var installed = 0
    func installApk(at url: URL, sizeBytes: Int, update: @escaping @Sendable (BusyUpdate) -> Void) async throws {
        installed += 1
        try await install(update)
    }

    private(set) var flashed = 0
    func flashZip(
        at url: URL, sizeBytes: Int, update: @escaping @Sendable (BusyUpdate) -> Void,
        finished: @escaping @Sendable () -> Void
    ) async throws {
        flashed += 1
        finished()
    }

    /// What the resume of a guest paused for space answers, and what Shut
    /// down does; a test sets them as the runtime would behave.
    var resumeAnswers = true
    private(set) var spaceResumes = 0
    func resumeAfterSpacePause() async -> Bool {
        spaceResumes += 1
        return resumeAnswers
    }
    /// What checking again over a guest that did not pause answers: whether
    /// the space is enough now.
    var checkAnswers = false
    private(set) var spaceChecks = 0
    func checkSpaceAfterPauseFailed() async -> Bool {
        spaceChecks += 1
        return checkAnswers
    }
    var shutDownError: Error?
    private(set) var spaceShutDowns = 0
    func shutDownAfterSpacePause() async throws {
        spaceShutDowns += 1
        if let shutDownError { throw shutDownError }
    }

    /// ADB over the network as the stub plays it.
    var debugging: Bool? = true
    var address: String? = "192.0.2.23"
    var startError: Error?
    private(set) var listening = false
    private(set) var starts = 0
    private(set) var stops = 0
    /// Computers connected through the listener, which a stop closes.
    var connectedComputers = 0
    private(set) var closedComputers = 0
    func usbDebugging() async -> Bool? { debugging }
    func startAdbOverNetwork() throws {
        if let startError { throw startError }
        listening = true
        starts += 1
    }
    func stopAdbOverNetwork() {
        listening = false
        stops += 1
        closedComputers += connectedComputers
        connectedComputers = 0
    }
    func localNetworkAddress() -> String? { address }
}

/// The update, interrupted-update (Start retries, Restore, Erase) and
/// blocked-start flows against a stub runtime, including a clean shutdown
/// returning Home with a fresh session and a failed run refusing another
/// Start.
@MainActor
struct UpdateFlowTests {
    private let host = HostDevice(
        name: "iPad", processorCount: 6, memory: MemoryPolicy(maximumsMiB: [4096]), freeStorageBytes: 40_000_000_000
    )

    private func model(plan: StartPlan) -> (AppModel, StubDriver) {
        let system = SystemInfo(
            version: "17", release: "r2", kernel: "Linux 6.18",
            architecture: "arm64, 4 KiB pages", appVersion: "1"
        )
        let model = AppModel(
            guest: Guest.fresh(on: host), host: host, system: system, capabilities: .device,
            createRequirementBytes: 1
        )
        let driver = StubDriver(plan: plan)
        model.driver = driver
        model.refreshPlan()
        return (model, driver)
    }

    @Test func anUpdateStartsAsAnUpgradeAndRemembersWhereFrom() {
        let (model, driver) = model(plan: .update(from: "r1", to: "r2"))
        #expect(model.bootKind(.normal) == .upgrade)
        model.start(.normal)
        #expect(model.phase == .booting(.upgrade))
        #expect(model.bootFrom == "r1")
        #expect(driver.begun.map(\.kind) == [.upgrade])
    }

    @Test func startOnAnUnfinishedUpdateTriesItAgain() {
        let (model, driver) = model(plan: .unfinishedUpdate(to: "r2", canRetry: true, canRestore: true))
        #expect(model.bootKind(.normal) == .upgrade)
        model.start(.normal)
        #expect(model.phase == .booting(.upgrade))
        #expect(driver.begun.map(\.kind) == [.upgrade])
        #expect(driver.restored == 0)
    }

    @Test func restoreOnlyPutsTheDataBackAndHomeShowsThePendingUpdate() {
        let (model, driver) = model(plan: .unfinishedUpdate(to: "r2", canRetry: true, canRestore: true))
        model.restoreUpdate()
        #expect(driver.restored == 1)
        #expect(model.phase == .home)
        #expect(driver.begun.isEmpty)
        #expect(model.plan == .update(from: "r1", to: "r2"))
        #expect(model.alert == nil)
        // The next start runs the update again.
        model.start(.normal)
        #expect(model.phase == .booting(.upgrade))
        #expect(model.bootFrom == "r1")
    }

    @Test func aRestoreThatFailsSaysSoAndStaysAtHome() {
        let (model, driver) = model(plan: .unfinishedUpdate(to: "r2", canRetry: true, canRestore: true))
        driver.restoreFails = true
        model.restoreUpdate()
        #expect(model.alert?.title == "The guest could not be restored")
        #expect(model.phase == .home)
        #expect(model.plan == .unfinishedUpdate(to: "r2", canRetry: true, canRestore: true))
    }

    @Test func anAndroidThatCannotRetryWaitsForRestoreOrEraseWithoutAMessage() {
        let (model, driver) = model(plan: .unfinishedUpdate(to: "r2", canRetry: false, canRestore: true))
        #expect(!model.plan.allowsStart)
        for mode in [StartMode.normal, .recovery] {
            #expect(!model.plan.allowsStart(mode))
            model.start(mode)
        }
        #expect(model.phase == .home)
        #expect(driver.begun.isEmpty)
        #expect(model.alert == nil)
    }

    @Test func recoveryWaitsForTheUpdateToFinishWithoutAMessage() {
        let (model, driver) = model(plan: .unfinishedUpdate(to: "r2", canRetry: true, canRestore: true))
        #expect(model.plan.allowsStart(.normal) && !model.plan.allowsStart(.recovery))
        model.start(.recovery)
        #expect(model.phase == .home)
        #expect(driver.begun.isEmpty)
        #expect(model.alert == nil)
    }

    @Test func aBlockedGuestIsNotStartedAndNothingIsSaid() {
        let (model, driver) = model(plan: .blocked(.olderAndroid))
        for mode in [StartMode.normal, .recovery] {
            #expect(!model.plan.allowsStart(mode))
            model.start(mode)
        }
        #expect(model.phase == .home)
        #expect(driver.begun.isEmpty)
        #expect(model.alert == nil && !model.startBlocked)
    }

    @Test func lowSpaceStillAsksBeforeAStart() {
        let (model, driver) = model(plan: .normal)
        model.host.freeStorageBytes = 1_000_000
        model.start(.normal)
        #expect(model.startBlocked)
        #expect(driver.begun.isEmpty)
    }

    // MARK: Erase

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func eraseDeletesTheGuestAndReturnsToTheFirstLaunchScreen() async {
        let (model, driver) = model(plan: .normal)
        model.notice = .closedInBackground
        model.resizePreset = 24
        model.erase()
        #expect(model.busy?.title == "Erasing guest")
        #expect(await eventually { model.busy == nil })
        #expect(driver.erased == 1)
        // No guest: Home shows the first-launch screen, with no notice that
        // the guest was erased.
        #expect(model.guest == nil)
        #expect(model.notice == nil)
        #expect(model.resizePreset == nil)
        #expect(model.phase == .home)
        #expect(model.alert == nil)
        #expect(model.plan == .normal)
    }

    @Test func aFailedEraseKeepsTheGuestAndSaysSo() async {
        let (model, driver) = model(plan: .normal)
        driver.eraseFails = true
        model.erase()
        #expect(await eventually { model.alert != nil })
        #expect(model.alert?.title == "The guest could not be erased")
        #expect(model.guest != nil)
        #expect(await eventually { model.busy == nil })
    }

    @Test func aChoiceMadeJustBeforeEraseIsNotSavedBack() async {
        let (model, driver) = model(plan: .normal)
        model.guest?.cores = 2
        model.erase()
        #expect(await eventually { model.busy == nil })
        try? await Task.sleep(for: .milliseconds(500))
        #expect(driver.savedGuest == nil)
    }

    @Test func theEndOfARunReadsThePlanAgain() {
        let (model, driver) = model(plan: .update(from: "r1", to: "r2"))
        model.start(.normal)
        // The update completed: the files now say an ordinary start.
        driver.plan = .normal
        model.runEnded(RunEnd(result: 0), uptimeSeconds: 60)
        #expect(model.plan == .normal)
        // A record that cannot be read leaves the start to report why.
        driver.plan = nil
        model.refreshPlan()
        #expect(model.plan == .normal)
    }

    /// Home states the storage the guest holds. It is measured when the guest
    /// loads, so the end of a run measures it again, however the run ended.
    @Test func theEndOfARunMeasuresTheStorageAgain() {
        let (model, driver) = model(plan: .normal)
        model.guest?.usedBytes = 2 * Limits.bytesPerGiB
        model.start(.normal)
        model.finishBoot(.normal)
        // Android wrote to its data disk while the guest ran.
        driver.diskUsedBytes = 5 * Limits.bytesPerGiB + Limits.bytesPerGiB / 2
        model.runEnded(RunEnd(result: 0), uptimeSeconds: 60)
        #expect(model.phase == .home)
        #expect(model.guest?.usedBytes == driver.diskUsedBytes)
        #expect(model.guest?.freeBytes == 8 * Limits.bytesPerGiB - driver.diskUsedBytes)

        let (failed, other) = self.model(plan: .normal)
        failed.start(.normal)
        other.diskUsedBytes = 3 * Limits.bytesPerGiB
        failed.runEnded(RunEnd(result: -4), uptimeSeconds: 60)
        #expect(failed.phase == .failed)
        #expect(failed.guest?.usedBytes == 3 * Limits.bytesPerGiB)
    }

    @Test func homeOffersRecoveryOnceTheFirstStartHasHappened() {
        let (model, driver) = model(plan: .firstStart)
        #expect(!model.plan.offersRecovery)
        model.start(.normal)
        model.finishBoot(.firstStart)
        // The runtime created the data disk during the start.
        driver.plan = .normal
        model.runEnded(RunEnd(result: 0), uptimeSeconds: 60)
        #expect(model.plan.offersRecovery)
    }

    @Test func cleanShutdownReturnsHomeAndStartsANewSession() {
        let (model, driver) = model(plan: .normal)
        model.start(.normal)
        model.finishBoot(.normal)
        let guest = model.guest
        model.session.usbDebugging = true
        model.session.showStats = true
        model.sessionPreset.settings = true
        model.sheet = .info
        model.runEnded(RunEnd(result: 0), uptimeSeconds: 60)
        #expect(model.phase == .home)
        #expect(model.guest == guest)
        #expect(model.sheet == nil)
        #expect(model.session.usbDebugging == nil)
        #expect(model.session.showStats)
        #expect(model.sessionPreset == SessionPreset())
        model.start(.recovery)
        #expect(model.phase == .booting(.recovery))
        #expect(driver.begun.map(\.mode) == [.normal, .recovery])
    }

    @Test func uncleanShutdownCannotStartAgainInThisProcess() {
        let (model, driver) = model(plan: .normal)
        model.start(.normal)
        model.runEnded(RunEnd(result: -4), uptimeSeconds: 60)
        #expect(model.phase == .failed)
        model.start(.normal)
        #expect(model.phase == .failed)
        #expect(driver.begun.count == 1)
    }
}
