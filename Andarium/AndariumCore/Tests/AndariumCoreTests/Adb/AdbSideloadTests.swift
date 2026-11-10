// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AndariumCore

@Suite(.timeLimit(.minutes(1)))
struct AdbSideloadTests {
    @Test func servesOutOfOrderBlocksAndPartialLastBlock() throws {
        let contents = Data((0..<(AdbSideload.blockSize + 17)).map { UInt8(truncatingIfNeeded: $0) })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try contents.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let adbd = FakeAdbd(services: ["sideload-host:*": { stream in
            try stream.send(Data("0000".utf8))
            try stream.send(Data("0001".utf8))
            #expect(try stream.receive(exactly: 17) == contents.suffix(17))
            try stream.send(Data("00000000".utf8))
            #expect(try stream.receive(exactly: AdbSideload.blockSize) == contents.prefix(AdbSideload.blockSize))
            try stream.send(Data("DONEDONE".utf8))
        }])
        defer { adbd.shutdown() }
        let connection = AdbConnection(transport: adbd.client)
        try connection.handshake(signer: nil)
        try AdbSideload.send(file: url, on: connection)
        #expect(adbd.servicesOpened == ["sideload-host:\(contents.count):65536"])
    }

    @Test func rejectsAnOutOfRangeBlock() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let adbd = FakeAdbd(services: ["sideload-host:*": { stream in
            try stream.send(Data("00000001".utf8))
        }])
        defer { adbd.shutdown() }
        let connection = AdbConnection(transport: adbd.client)
        try connection.handshake(signer: nil)
        #expect(throws: AdbError.protocolViolation("a sideload block beyond the package")) {
            try AdbSideload.send(file: url, on: connection)
        }
    }

    @Test func reportsRecoveryFailure() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let adbd = FakeAdbd(services: ["sideload-host:*": { stream in
            try stream.send(Data("FAILFAIL".utf8))
        }])
        defer { adbd.shutdown() }
        let connection = AdbConnection(transport: adbd.client)
        try connection.handshake(signer: nil)
        #expect(throws: AdbError.protocolViolation("recovery reported a sideload failure")) {
            try AdbSideload.send(file: url, on: connection)
        }
    }
}
