// SPDX-License-Identifier: GPL-2.0-or-later

import AndariumCore
import Foundation

/// Opens connections to the guest's adbd through the runtime: a connected
/// stream socket to the guest's vsock port, which only this process holds.
nonisolated struct VsockConnector: AdbConnector, GuestStreamOpener {
    static let adbPort: UInt32 = 5555
    /// How long one attempt waits for the guest to answer; the session asks
    /// again until its connect limit.
    static let attemptTimeoutMilliseconds: UInt32 = 3000
    /// How long a computer's connection waits for the guest: it asks again
    /// itself when this one fails.
    static let networkAttemptTimeoutMilliseconds: UInt32 = 5000

    func connect() throws -> any AdbTransport {
        DescriptorTransport(descriptor: try Self.open(timeout: Self.attemptTimeoutMilliseconds))
    }

    /// A stream for a computer on the network; the bridge owns it.
    func openStream() throws -> Int32 {
        try Self.open(timeout: Self.networkAttemptTimeoutMilliseconds)
    }

    private static func open(timeout: UInt32) throws -> Int32 {
        let result = kernarium_runtime_loader_connect_vsock(adbPort, timeout)
        if result >= 0 { return result }
        switch -result {
        case ECONNREFUSED: throw AdbError.refused
        case ETIMEDOUT: throw AdbError.notAnswering
        case ENODEV, ECONNRESET: throw AdbError.guestGone
        default: throw AdbError.io(-result)
        }
    }
}

/// Runs an adb operation on a thread of its own, behind `async`: the I/O
/// blocks, and a task cancelling ends the connection, which wakes the thread.
nonisolated enum AdbOperationRunner {
    static func run<Output: Sendable>(
        identity: AdbKeyStore.Identity?, clock: GuestRunClock, cancellable: Bool = true,
        connector: any AdbConnector = VsockConnector(), connectLimit: Duration = AdbSession.defaultConnectLimit,
        onCancel: @escaping @Sendable () -> Void = {},
        _ body: @escaping @Sendable (AdbSession) throws -> Output
    ) async throws -> Output {
        let session = AdbSession(
            connector: connector, signer: identity?.signer, clock: clock, connectLimit: connectLimit)
        let operation: () async throws -> Output = {
            try await withCheckedThrowingContinuation { continuation in
                let thread = Thread {
                    defer { session.watchdog.stop() }
                    do {
                        continuation.resume(returning: try body(session))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                thread.name = "andarium-adb"
                thread.qualityOfService = .userInitiated
                thread.start()
            }
        }
        guard cancellable else { return try await operation() }
        return try await withTaskCancellationHandler(operation: operation) {
            session.cancel()
            onCancel()
        }
    }

    /// An operation's error in the form the model shows: a cancel is a
    /// `CancellationError`, an adb failure has its words, and anything else
    /// (no room for the report) says what it says.
    static func presented(_ error: Error, activity: AdbActivity) -> Error {
        if error is CancellationError { return error }
        if let cocoa = error as? CocoaError, cocoa.code == .userCancelled { return CancellationError() }
        guard let adb = error as? AdbError else { return error }
        return adb == .cancelled ? CancellationError() : AdbFailure(adb, activity: activity)
    }
}

/// Runs the short commands the graphics reclaim sends, each on a connection
/// of its own.
nonisolated struct AdbGuestShell: GuestShell {
    var operations: AdbGuestOperations

    func run(_ command: String, limit: Duration) async throws -> GuestShellOutput {
        let result = try await operations.shell(command, limit: limit)
        return GuestShellOutput(text: result.text, exitCode: result.exitCode)
    }
}

/// What a bug report has left in the guest, shared between the operation's
/// thread and the cleanup that follows a cancel.
nonisolated final class BugReportTrail: @unchecked Sendable {
    private let lock = NSLock()
    private var remote: String?

    /// The report's path in the guest, once Android has said it.
    var remotePath: String? {
        get { lock.withLock { remote } }
        set { lock.withLock { remote = newValue } }
    }
}

nonisolated enum BugReportOperation {
    /// Android's own collecting is nine tenths of the bar, the copy the rest.
    static let generatingShare = 0.9
    /// Silence from `bugreportz` for this long, in the guest's running time,
    /// ends the report; so does the whole taking this long.
    static let idleLimit = Duration.seconds(5 * 60)
    static let overallLimit = Duration.seconds(45 * 60)
    static let pullIdleLimit = Duration.seconds(60)
    static let cleanupLimit = Duration.seconds(15)

    /// Makes the report and returns the staged file. The staged partial file
    /// goes on any failure; the guest's copy goes after a good pull.
    static func run(
        session: AdbSession, device: String, trail: BugReportTrail,
        update: @escaping @Sendable (BusyUpdate) -> Void
    ) throws -> URL {
        let watchdog = session.watchdog
        var sink: StagedFileSink?
        do {
            return try session.run { connection in
                watchdog.arm(idle: idleLimit, overall: overallLimit)
                let path = try BugReport.generate(
                    on: connection,
                    progress: { update(BusyUpdate(progress: $0 * generatingShare)) },
                    alive: { watchdog.touch() }
                )
                trail.remotePath = path
                update(BusyUpdate(progress: generatingShare, detail: "Copying the report\u{2026}"))
                watchdog.arm(idle: pullIdleLimit)
                var hooks = BugReport.Hooks()
                hooks.alive = { watchdog.touch() }
                hooks.stage = { remote, size in
                    let made = try BugReportStaging.makeSink(remotePath: remote, size: size, device: device)
                    sink = made
                    return made
                }
                hooks.pulling = { received, total in
                    let fraction = total == 0 ? 1 : Double(received) / Double(total)
                    update(BusyUpdate(progress: generatingShare + (1 - generatingShare) * fraction))
                }
                let pulled = try BugReport.pull(on: connection, remotePath: path, hooks: hooks)
                sink?.close()
                // The guest's copy and any an earlier run left: best effort.
                watchdog.arm(idle: cleanupLimit)
                _ = try? connection.runShell(BugReport.cleanupCommand(afterPulling: pulled.remotePath))
                trail.remotePath = nil
                guard let url = sink?.url else { throw AdbError.protocolViolation("no report was staged") }
                return url
            }
        } catch {
            sink?.close()
            if let url = sink?.url { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    /// Whether the guest's dump may still run when the operation ended with
    /// `error`: it does when only the stream ended (a cancel, a limit, the
    /// service restarting), and a second report would be refused meanwhile.
    static func dumpMayGoOn(after error: Error) -> Bool {
        if error is CancellationError { return true }
        switch error as? AdbError {
        case .cancelled, .timedOut, .guestGone, .streamClosed: return true
        default: return false
        }
    }

    /// After a cancel or a failure: ends a dump still running and removes
    /// what it left, on a connection of its own, within a bound. The report's
    /// stream is already closed, which is the fallback if this cannot run.
    static func stopInGuest(session: AdbSession, trail: BugReportTrail) {
        _ = try? session.run { connection in
            session.watchdog.arm(idle: cleanupLimit, overall: cleanupLimit)
            if let path = trail.remotePath {
                _ = try? connection.runShell(BugReport.cleanupCommand(afterPulling: path))
            } else {
                _ = try? connection.runShell(BugReport.stopCommand)
            }
        }
    }
}

/// The operations the screens ask of Android over adb, with the key this boot
/// carries and the clock of the guest's running time. The application builds
/// one for each call; the hosted tests build their own and drive a real guest
/// through the same code.
nonisolated struct AdbGuestOperations: Sendable {
    var identity: AdbKeyStore.Identity?
    var clock: GuestRunClock
    /// "iPad", "iPhone" or "Mac", for the words of a failure.
    var device: String
    var connector: any AdbConnector = VsockConnector()

    /// Asks Android for a bug report and stages it for the share sheet.
    /// Cancelling the task stops the dump in the guest and removes what it
    /// left, then throws `CancellationError`.
    func createBugReport(update: @escaping @Sendable (BusyUpdate) -> Void) async throws -> URL {
        guard let identity else { throw AdbFailure(.keyRejected, activity: .bugReport) }
        let trail = BugReportTrail()
        let device = device
        do {
            let file = try await AdbOperationRunner.run(identity: identity, clock: clock, connector: connector) { session in
                try BugReportOperation.run(session: session, device: device, trail: trail, update: update)
            }
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: file)
                throw CancellationError()
            }
            return file
        } catch {
            let shown = AdbOperationRunner.presented(error, activity: .bugReport)
            // The guest's dump goes on by itself when only the stream ended.
            if BugReportOperation.dumpMayGoOn(after: error) {
                await stopBugReport(identity: identity, trail: trail)
            }
            throw shown
        }
    }

    /// Stops a dump the guest may still run and removes what it left, on a
    /// connection of its own that a cancelled task cannot end.
    private func stopBugReport(identity: AdbKeyStore.Identity, trail: BugReportTrail) async {
        _ = try? await AdbOperationRunner.run(
            identity: identity, clock: clock, cancellable: false, connector: connector
        ) { session in
            BugReportOperation.stopInGuest(session: session, trail: trail)
        }
    }

    /// Whether the guest's USB debugging setting is on; nil when it cannot be
    /// read now (the guest is starting, or stopped). Each call opens a
    /// connection, which wakes a guest that suspended itself.
    func usbDebugging() async -> Bool? {
        guard let result = try? await shell(UsbDebugging.command, limit: .seconds(15)) else { return nil }
        return UsbDebugging.parse(result)
    }

    /// Runs a command in the guest's shell and returns what it printed.
    func shell(_ command: String, limit: Duration = .seconds(60)) async throws -> ShellResult {
        guard let identity else { throw AdbFailure(.keyRejected, activity: .bugReport) }
        return try await AdbOperationRunner.run(identity: identity, clock: clock, connector: connector) { session in
            try session.run { connection in
                session.watchdog.arm(idle: limit, overall: limit)
                return try connection.runShell(command)
            }
        }
    }

    /// Installs the APK at `url` (readable by the caller), cancellable while
    /// the file is being sent.
    func installApk(at url: URL, sizeBytes: Int, update: @escaping @Sendable (BusyUpdate) -> Void) async throws {
        guard let identity else { throw AdbFailure(.keyRejected, activity: .installApp) }
        let coordinator = FileCoordinatorBox()
        let info = "\(url.lastPathComponent) \u{00B7} \(Formats.size(bytes: UInt64(max(sizeBytes, 0))))"
        do {
            try await AdbOperationRunner.run(
                identity: identity, clock: clock, connector: connector, onCancel: { coordinator.cancel() }
            ) { session in
                try ApkInstallOperation.run(
                    session: session, coordinator: coordinator, url: url, size: sizeBytes, fileInfo: info,
                    update: update)
            }
        } catch {
            throw AdbOperationRunner.presented(error, activity: .installApp)
        }
    }

    /// Flashes the ZIP at `url` (readable by the caller): restarts the guest
    /// into recovery's sideload and serves the package to it. Returns once
    /// recovery has read the whole package, which is when it asks the person
    /// to confirm and installs; the package is served on until recovery ends
    /// the sideload, and `finished` is called then, on every outcome.
    func flashZip(
        at url: URL, sizeBytes: Int, update: @escaping @Sendable (BusyUpdate) -> Void,
        finished: @escaping @Sendable () -> Void
    ) async throws {
        guard let identity else {
            finished()
            throw AdbFailure(.keyRejected, activity: .flashZip)
        }
        do {
            try await AdbOperationRunner.run(identity: identity, clock: clock, connector: connector) { session in
                try ZipFlashOperation.restartIntoSideload(session: session)
            }
        } catch {
            finished()
            throw AdbOperationRunner.presented(error, activity: .flashZip)
        }
        update(BusyUpdate(detail: "Waiting for recovery\u{2026}"))
        let (verified, verification) = AsyncThrowingStream<Never, Error>.makeStream()
        let clock = clock
        let connector = connector
        let serving = Task.detached(priority: .userInitiated) {
            defer { finished() }
            do {
                try await ZipFlashOperation.serve(
                    url: url, size: sizeBytes, clock: clock, connector: connector, update: update
                ) { verification.finish() }
                verification.finish()
            } catch {
                verification.finish(throwing: AdbOperationRunner.presented(error, activity: .flashZip))
            }
        }
        try await withTaskCancellationHandler {
            for try await _ in verified {}
        } onCancel: {
            serving.cancel()
        }
    }
}
