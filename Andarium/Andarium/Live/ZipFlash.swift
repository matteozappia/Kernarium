// SPDX-License-Identifier: GPL-2.0-or-later

import AndariumCore
import Foundation

/// Flashes one ZIP through recovery, as `adb sideload` does from a computer:
/// Android restarts into recovery's sideload, whose minadbd answers on the
/// same vsock port, and recovery reads the package block by block, never
/// whole in memory. Recovery reads all of it once to check its signature,
/// then asks the person on its own screen and runs the package's installer.
nonisolated enum ZipFlashOperation {
    /// How long recovery may take to come up and start its sideload.
    static let recoveryLimit = Duration.seconds(300)
    /// How long one connection attempt waits before the next.
    static let attemptLimit = Duration.seconds(10)
    static let restartLimit = Duration.seconds(30)

    /// The serving ended after recovery began to read the package: it is not
    /// tried again.
    private struct Interrupted: Error {
        let underlying: Error
    }

    /// Asks Android to restart into recovery's sideload, as `adb reboot
    /// sideload` does. The guest ends the connection as it goes down.
    static func restartIntoSideload(session: AdbSession) throws {
        do {
            try session.run { connection in
                session.watchdog.arm(idle: restartLimit, overall: restartLimit)
                _ = try connection.open("reboot:sideload").readToEnd(limit: 4096)
            }
        } catch AdbError.guestGone {
        } catch AdbError.streamClosed {
        }
    }

    /// Waits for recovery's sideload and serves the package to its end.
    /// `verified` is called once recovery has read every block.
    static func serve(
        url: URL, size: Int, clock: GuestRunClock, connector: any AdbConnector,
        update: @escaping @Sendable (BusyUpdate) -> Void, verified: @escaping @Sendable () -> Void
    ) async throws {
        let deadline = ContinuousClock.now + recoveryLimit
        while true {
            try Task.checkCancellation()
            let coordinator = FileCoordinatorBox()
            do {
                try await AdbOperationRunner.run(
                    identity: nil, clock: clock, connector: connector, connectLimit: attemptLimit,
                    onCancel: { coordinator.cancel() }
                ) { session in
                    try send(session: session, coordinator: coordinator, url: url, update: update, verified: verified)
                }
                return
            } catch let interrupted as Interrupted {
                throw interrupted.underlying
            } catch let error as AdbError where [.refused, .notAnswering, .guestGone].contains(error) {
                // Android is still going down, or recovery is not up yet.
                guard ContinuousClock.now < deadline else { throw error }
                try await Task.sleep(for: .seconds(1))
            }
        }
    }

    private static func send(
        session: AdbSession, coordinator: FileCoordinatorBox, url: URL,
        update: @escaping @Sendable (BusyUpdate) -> Void, verified: @escaping @Sendable () -> Void
    ) throws {
        var started = false
        var result: Result<Void, Error> = .success(())
        var coordinationError: NSError?
        // The read is coordinated, which brings an iCloud file down first.
        coordinator.current.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            result = Result {
                try session.run { connection in
                    // Android's adbd answers until the guest has gone down.
                    guard connection.banner.text.hasPrefix("sideload") else { throw AdbError.refused }
                    started = true
                    update(BusyUpdate(detail: "Recovery is checking the package\u{2026}"))
                    try AdbSideload.send(file: readable, on: connection) { share in
                        update(BusyUpdate(progress: share))
                        if share >= 1 { verified() }
                    }
                }
            }
        }
        if let coordinationError { throw coordinationError }
        do {
            try result.get()
        } catch {
            throw started ? Interrupted(underlying: error) : error
        }
    }
}
