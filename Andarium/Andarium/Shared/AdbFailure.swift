// SPDX-License-Identifier: GPL-2.0-or-later

import AndariumCore
import Foundation

/// What the guest's operations are for, which the words of a failure follow.
nonisolated enum AdbActivity {
    case installApp
    case bugReport
    case flashZip

    fileprivate var notReady: String {
        switch self {
        case .installApp: "install apps"
        case .bugReport: "make a bug report"
        case .flashZip: "flash a package"
        }
    }

    fileprivate var stoppedBefore: String {
        switch self {
        case .installApp: "the app was installed"
        case .bugReport: "the bug report was finished"
        case .flashZip: "the package was sent"
        }
    }

    fileprivate var whileDoing: String {
        switch self {
        case .installApp: "installing the app"
        case .bugReport: "making the bug report"
        case .flashZip: "sending the package"
        }
    }

    fileprivate var couldNot: String {
        switch self {
        case .installApp: "install the app"
        case .bugReport: "make the bug report"
        case .flashZip: "flash the package"
        }
    }
}

/// An adb failure in the words an alert shows.
nonisolated struct AdbFailure: LocalizedError, Equatable {
    var message: String

    var errorDescription: String? { message }

    init(message: String) {
        self.message = message
    }

    init(_ error: AdbError, activity: AdbActivity) {
        switch error {
        case .refused:
            message = "The guest isn\u{2019}t ready to \(activity.notReady). Try again in a moment."
        case .notAnswering:
            message = "The guest isn\u{2019}t answering yet. Try again once it has started."
        case .keyRejected:
            message = "The guest didn\u{2019}t accept Andarium\u{2019}s key. Restart the guest and try again."
        case .guestGone, .streamClosed:
            // adbd restarts when the guest's USB debugging turns off, which
            // ends a connection in use; the next try reaches the new one.
            message = "The guest\u{2019}s debugging service restarted before \(activity.stoppedBefore). Try again."
        case .timedOut:
            message = "The guest stopped responding while \(activity.whileDoing)."
        case let .remote(text):
            message = Self.remote(text, activity: activity)
        case .serviceRefused, .protocolViolation, .io, .cancelled:
            message = "The guest couldn\u{2019}t \(activity.couldNot)."
        }
    }

    /// The text of a `FAIL` from the guest, with the one it sends for a
    /// report under way in plain words.
    private static func remote(_ text: String, activity: AdbActivity) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if activity == .bugReport, trimmed.lowercased().contains("in progress") {
            return "The guest is already making a bug report."
        }
        return trimmed.isEmpty ? "The guest couldn\u{2019}t \(activity.couldNot)." : trimmed
    }
}

/// Why ADB over network did not start, and what its row says without an
/// address.
nonisolated enum AdbNetworkMessages {
    static func cannotStart(_ error: Error) -> String {
        if let adb = error as? AdbError, adb == .io(EADDRINUSE) {
            return "Port \(AdbNetworkBridge.defaultPort) is already in use on this device."
        }
        return "ADB over network could not start."
    }

    static let noAddress = "This device has no Wi-Fi address. Connect to Wi-Fi to use ADB over network."
}
