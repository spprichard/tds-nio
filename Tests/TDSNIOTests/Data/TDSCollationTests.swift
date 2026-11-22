//===----------------------------------------------------------------------===//
//
// This source file is part of the TDSNIO open source project
//
// Copyright (c) 2026 Aaron Edwards and the TDSNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE for license information
// See CONTRIBUTORS.md for the list of TDSNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOEmbedded
import Testing

@testable import TDSNIO

/// Collation bytes and value bytes below were captured from SQL Server 2022 (16.0.4305.5).
@Suite struct TDSCollationTests {
    /// COLMETADATA collations, as the server sent them for a varchar column.
    enum Captured {
        static let sqlLatin1CP1CIAS: [UInt8] = [0x09, 0x04, 0xD0, 0x00, 0x34]  // SQL_Latin1_General_CP1_CI_AS
        static let latin1GeneralCIAS: [UInt8] = [0x09, 0x04, 0xD0, 0x00, 0x00]  // Latin1_General_CI_AS
        static let latin1UTF8: [UInt8] = [0x09, 0x04, 0xD0, 0x24, 0x00]  // Latin1_General_100_CI_AS_SC_UTF8
        static let japaneseCIAS: [UInt8] = [0x11, 0x04, 0xD0, 0x00, 0x00]  // Japanese_CI_AS (932)
        static let sqlCP850Bin: [UInt8] = [0x09, 0x04, 0x00, 0x01, 0x28]  // SQL_Latin1_General_CP850_BIN

        /// `CAST(CAST('José' AS varchar(10)) AS varbinary(10))` in a SQL_Latin1_General_CP1_CI_AS database.
        static let joseCP1252: [UInt8] = [0x4A, 0x6F, 0x73, 0xE9]
        static let joseUTF8: [UInt8] = [0x4A, 0x6F, 0x73, 0xC3, 0xA9]

        /// `UNICODE(CAST(CHAR(b) AS nvarchar(1)))` for b in 0x80...0x9F, under both 1252 collations
        /// above; they agree. Every other byte converts to the code point with the same value.
        static let windows1252From0x80: [UInt16] = [
            8364, 129, 8218, 402, 8222, 8230, 8224, 8225, 710, 8240, 352, 8249, 338, 141, 381, 143,
            144, 8216, 8217, 8220, 8221, 8226, 8211, 8212, 732, 8482, 353, 8250, 339, 157, 382, 376,
        ]
    }

    // MARK: - Code page

    @Test(arguments: [
        (Captured.sqlLatin1CP1CIAS, 1252),
        (Captured.latin1GeneralCIAS, 1252),
        (Captured.latin1UTF8, 65001),
        (Captured.japaneseCIAS, 932),
        (Captured.sqlCP850Bin, 850),
    ] as [([UInt8], UInt16)])
    func codePageFollowsTheCollation(collation: [UInt8], codePage: UInt16) {
        #expect(TDSCollation(bytes: collation).codePage == codePage)
    }

    @Test func fieldsAreReadFromTheCollationBytes() {
        let collation = TDSCollation(bytes: Captured.sqlLatin1CP1CIAS)
        #expect(collation.lcid == 0x0409)
        #expect(collation.sortID == 52)
        #expect(!collation.isUTF8)
        #expect(TDSCollation(bytes: Captured.latin1UTF8).isUTF8)
    }

    @Test func aMissingOrUnknownCollationHasNoCodePage() {
        #expect(TDSCollation(bytes: []).codePage == nil)
        #expect(TDSCollation(bytes: [0x00, 0x00, 0x00, 0x00, 0x00]).codePage == nil)
        #expect(TDSCollation(bytes: [0x09, 0x04, 0xD0, 0x00, 0xFE]).codePage == nil)
    }

    // MARK: - Decoding

    @Test func windows1252MatchesSQLServerForEveryByte() throws {
        let collation = TDSCollation(bytes: Captured.sqlLatin1CP1CIAS)
        for byte in UInt8.min...UInt8.max {
            let expected =
                (0x80..<0xA0).contains(byte) ? Captured.windows1252From0x80[Int(byte) - 0x80] : UInt16(byte)
            let decoded = try collation.decodeString([byte])
            #expect(Array(decoded.utf16) == [expected], "byte 0x\(String(byte, radix: 16))")
        }
    }

    @Test func accentedLatin1TextDecodesFromItsCodePage() throws {
        #expect(try TDSCollation(bytes: Captured.sqlLatin1CP1CIAS).decodeString(Captured.joseCP1252) == "José")
        #expect(try TDSCollation(bytes: Captured.latin1GeneralCIAS).decodeString(Captured.joseCP1252) == "José")
    }

    @Test func utf8CollationsDecodeAsUTF8() throws {
        #expect(try TDSCollation(bytes: Captured.latin1UTF8).decodeString(Captured.joseUTF8) == "José")
        #expect(throws: TDSDecodingError.self) {
            try TDSCollation(bytes: Captured.latin1UTF8).decodeString(Captured.joseCP1252)
        }
    }

    /// SQL Server converts `EF BB BF 41` in a _UTF8 varchar to U+FEFF U+0041. Foundation's
    /// `String(bytes:encoding: .utf8)` drops the U+FEFF.
    @Test func utf8KeepsALeadingByteOrderMark() throws {
        let decoded = try TDSCollation(bytes: Captured.latin1UTF8).decodeString([0xEF, 0xBB, 0xBF, 0x41])
        #expect(decoded.unicodeScalars.map(\.value) == [0xFEFF, 0x41])
    }

    @Test(arguments: [
        [0xC3] as [UInt8],  // truncated two-byte sequence
        [0x41, 0xC3, 0x28],  // invalid continuation byte
        [0xED, 0xA0, 0x80],  // encoded surrogate
        [0xC0, 0xAF],  // overlong encoding
        [0xFF, 0x41],  // byte never valid in UTF-8
    ])
    func invalidUTF8Throws(bytes: [UInt8]) {
        #expect(throws: TDSDecodingError.self) {
            try TDSCollation(bytes: Captured.latin1UTF8).decodeString(bytes)
        }
    }

    @Test func asciiDecodesWhateverTheCollation() throws {
        for collation in [Captured.japaneseCIAS, Captured.sqlCP850Bin, []] {
            #expect(try TDSCollation(bytes: collation).decodeString(Array("Jose 42".utf8)) == "Jose 42")
        }
    }

    @Test func nonASCIIInAnUnsupportedCodePageThrowsAndNamesIt() {
        let error = #expect(throws: TDSDecodingError.self) {
            try TDSCollation(bytes: Captured.japaneseCIAS).decodeString([0x82, 0xA0])
        }
        #expect(error?.undecodableText?.codePage == 932)
        #expect(error?.undecodableText?.description.contains("code page 932") == true)
    }

    @Test func nonASCIIWithoutAKnownCollationThrows() {
        for collation in [[], [0x09, 0x04, 0xD0, 0x00, 0xFE] as [UInt8]] {
            let error = #expect(throws: TDSDecodingError.self) {
                try TDSCollation(bytes: collation).decodeString(Captured.joseCP1252)
            }
            #expect(error?.undecodableText?.reason == .unsupportedCodePage)
            #expect(error?.undecodableText?.description.contains("unknown code page") == true)
        }
    }

    // MARK: - Token stream

    @Test func varcharRowsDecodeFromTheColumnCollation() throws {
        var payload = ByteBufferAllocator().buffer(capacity: 128)
        payload.writeInteger(0x81 as UInt8)
        payload.writeInteger(3 as UInt16, endianness: .little)
        payload.writeVarCharColumn(name: "name", maxLength: 50, collation: Captured.sqlLatin1CP1CIAS)
        payload.writeVarCharColumn(name: "notes", maxLength: 0xFFFF, collation: Captured.sqlLatin1CP1CIAS)
        payload.writeVarCharColumn(name: "utf8", maxLength: 50, collation: Captured.latin1UTF8)

        payload.writeInteger(0xD1 as UInt8)
        payload.writeInteger(UInt16(Captured.joseCP1252.count), endianness: .little)
        payload.writeBytes(Captured.joseCP1252)
        payload.writePLPBytes(Captured.joseCP1252 + Captured.joseCP1252, chunkSizes: [3])
        payload.writeInteger(UInt16(Captured.joseUTF8.count), endianness: .little)
        payload.writeBytes(Captured.joseUTF8)
        var done = TDSTests.donePayload()
        payload.writeBuffer(&done)

        let messages = try Self.decode(payload)
        guard case .row(let row) = messages[1] else {
            Issue.record("Expected ROW, got \(messages)")
            return
        }
        #expect(row.values == [.string("José"), .string("JoséJosé"), .string("José")])
    }

    @Test func varcharReturnValuesDecodeFromTheirCollation() throws {
        var payload = ByteBufferAllocator().buffer(capacity: 64)
        payload.writeInteger(0xAC as UInt8)
        payload.writeInteger(1 as UInt16, endianness: .little)
        payload.writeInteger(5 as UInt8)
        payload.writeUTF16("@name")
        payload.writeInteger(1 as UInt8)
        payload.writeInteger(0 as UInt32, endianness: .little)
        payload.writeInteger(0 as UInt16, endianness: .little)
        payload.writeInteger(TDSDataType.bigVarChar.rawValue)
        payload.writeInteger(50 as UInt16, endianness: .little)
        payload.writeBytes(Captured.sqlLatin1CP1CIAS)
        payload.writeInteger(UInt16(Captured.joseCP1252.count), endianness: .little)
        payload.writeBytes(Captured.joseCP1252)
        var done = TDSTests.donePayload()
        payload.writeBuffer(&done)

        let messages = try Self.decode(payload)
        guard case .returnValue(let value) = messages[0] else {
            Issue.record("Expected RETURNVALUE, got \(messages)")
            return
        }
        #expect(value.value == .string("José"))
    }

    @Test func varcharSQLVariantsDecodeFromTheirCollation() throws {
        var payload = ByteBufferAllocator().buffer(capacity: 64)
        payload.writeInteger(0x81 as UInt8)
        payload.writeInteger(1 as UInt16, endianness: .little)
        payload.writeInteger(0 as UInt32, endianness: .little)
        payload.writeInteger(0 as UInt16, endianness: .little)
        payload.writeInteger(TDSDataType.sqlVariant.rawValue)
        payload.writeInteger(8009 as UInt32, endianness: .little)
        payload.writeInteger(1 as UInt8)
        payload.writeUTF16("v")

        payload.writeInteger(0xD1 as UInt8)
        payload.writeSQLVariant(type: .bigVarChar, properties: Captured.sqlLatin1CP1CIAS + [50, 0]) { value in
            value.writeBytes(Captured.joseCP1252)
        }
        var done = TDSTests.donePayload()
        payload.writeBuffer(&done)

        let messages = try Self.decode(payload)
        guard case .row(let row) = messages[1] else {
            Issue.record("Expected ROW, got \(messages)")
            return
        }
        #expect(row.values == [.string("José")])
    }

    /// The value comes back undecoded, with its bytes, instead of failing the message: a failed
    /// message closes the connection.
    @Test func anUnsupportedCodePageIsAPerValueResultNotAMessageFailure() throws {
        var payload = ByteBufferAllocator().buffer(capacity: 64)
        payload.writeInteger(0x81 as UInt8)
        payload.writeInteger(2 as UInt16, endianness: .little)
        payload.writeVarCharColumn(name: "name", maxLength: 50, collation: Captured.japaneseCIAS)
        payload.writeVarCharColumn(name: "plain", maxLength: 50, collation: Captured.japaneseCIAS)
        payload.writeInteger(0xD1 as UInt8)
        payload.writeInteger(2 as UInt16, endianness: .little)
        payload.writeBytes([0x82, 0xA0])
        payload.writeInteger(2 as UInt16, endianness: .little)
        payload.writeBytes(Array("ok".utf8))
        var done = TDSTests.donePayload()
        payload.writeBuffer(&done)

        let messages = try Self.decode(payload)
        guard case .row(let row) = messages[1] else {
            Issue.record("Expected ROW, got \(messages)")
            return
        }
        let expected = TDSUndecodableText(
            bytes: [0x82, 0xA0], collation: Captured.japaneseCIAS, codePage: 932, reason: .unsupportedCodePage
        )
        #expect(row.values == [.undecodableText(expected), .string("ok")])
    }

    @Test func decodingUndecodableTextAsStringThrowsAndNamesTheCodePage() throws {
        let text = TDSUndecodableText(
            bytes: [0x82, 0xA0], collation: Captured.japaneseCIAS, codePage: 932, reason: .unsupportedCodePage
        )
        let row = TDSRow(
            columns: [TDSColumn(name: "name", dataType: .bigVarChar)],
            values: [.undecodableText(text)]
        )
        let error = #expect(throws: TDSDecodingError.self) {
            try row.decode(column: "name", as: String.self)
        }
        #expect(error?.code == .undecodableText(text))
        #expect(error?.columnName == "name")
        #expect(text.description.contains("code page 932"))
        #expect(try row.decode(column: "name", as: TDSData.self) == .undecodableText(text))
        // Not mistaken for NULL.
        #expect(throws: TDSDecodingError.self) {
            try row.decode(column: "name", as: String?.self)
        }
    }

    private static func decode(_ payload: ByteBuffer) throws -> [TDSBackendMessage] {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(TDSBackendMessageDecoder()))
        try channel.writeInbound(TDSTests.packet(type: .preloginLoginOrTablularResponse, payload: payload))
        var messages: [TDSBackendMessage] = []
        while let containers = try channel.readInbound(as: TinySequence<TDSBackendMessageDecoder.Container>.self) {
            for container in containers {
                messages.append(contentsOf: container.messages)
            }
        }
        return messages
    }
}

extension TDSCollation {
    /// The decoded string; throws what `String.decode` throws for undecodable text.
    fileprivate func decodeString(_ bytes: [UInt8]) throws -> String {
        try String.decode(from: self.decodeText(bytes))
    }
}

extension TDSDecodingError {
    fileprivate var undecodableText: TDSUndecodableText? {
        if case .undecodableText(let text) = self.code { text } else { nil }
    }
}

extension ByteBuffer {
    fileprivate mutating func writeVarCharColumn(name: String, maxLength: UInt16, collation: [UInt8]) {
        self.writeInteger(0 as UInt32, endianness: .little)
        self.writeInteger(0 as UInt16, endianness: .little)
        self.writeInteger(TDSDataType.bigVarChar.rawValue)
        self.writeInteger(maxLength, endianness: .little)
        self.writeBytes(collation)
        self.writeInteger(UInt8(name.utf16.count))
        self.writeUTF16(name)
    }
}
