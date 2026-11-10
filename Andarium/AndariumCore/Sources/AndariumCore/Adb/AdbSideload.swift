// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Serves a recovery sideload request without loading the ZIP into memory.
public enum AdbSideload {
    public static let blockSize = 65_536

    /// Serves the blocks recovery asks for until it reports how the install
    /// ended. `served` gets the share of the package's blocks recovery has
    /// read at least once: it reads them all to verify the package before it
    /// installs anything, so 1 means the install itself is under way.
    public static func send(
        file: URL, on connection: AdbConnection, served: (Double) -> Void = { _ in }
    ) throws {
        let file = try FileHandle(forReadingFrom: file)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        guard size > 0 else { throw AdbError.protocolViolation("an empty sideload package") }
        let blockCount = Int((size + UInt64(blockSize) - 1) / UInt64(blockSize))
        var read = [Bool](repeating: false, count: blockCount)
        var readCount = 0
        let stream = try connection.open("sideload-host:\(size):\(blockSize)")
        defer { stream.close() }
        var pending = Data()
        while let data = try stream.read() {
            pending.append(data)
            while pending.count >= 8 {
                let request = pending.prefix(8)
                pending.removeFirst(8)
                if request == Data("DONEDONE".utf8) { return }
                if request == Data("FAILFAIL".utf8) {
                    throw AdbError.protocolViolation("recovery reported a sideload failure")
                }
                guard request.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                      let block = UInt64(String(decoding: request, as: UTF8.self)) else {
                    throw AdbError.protocolViolation("an invalid sideload block request")
                }
                let offset = block * UInt64(blockSize)
                guard offset < size else { throw AdbError.protocolViolation("a sideload block beyond the package") }
                try file.seek(toOffset: offset)
                let count = Int(min(UInt64(blockSize), size - offset))
                guard let bytes = try file.read(upToCount: count), bytes.count == count else {
                    throw AdbError.protocolViolation("a truncated sideload package")
                }
                try stream.write(bytes)
                if !read[Int(block)] {
                    read[Int(block)] = true
                    readCount += 1
                    served(Double(readCount) / Double(blockCount))
                }
            }
        }
        throw AdbError.protocolViolation("the sideload stream closed before completion")
    }
}
