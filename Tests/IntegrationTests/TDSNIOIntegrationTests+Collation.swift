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
import NIOPosix
import TDSNIO
import Testing


/// char, varchar and text arrive as bytes in the column's code page, not as UTF-8.
extension TDSNIOIntegrationTests {
    @Test func varcharDecodesFromTheColumnCollation() async throws {
        try await withTDSConnection(on: NIOSingletons.posixEventLoopGroup.next()) { connection in
            let rows = try await connection.execute(
                """
                SELECT
                    CAST(N'José' COLLATE SQL_Latin1_General_CP1_CI_AS AS varchar(20)) AS sqlLatin1,
                    CAST(N'José' COLLATE Latin1_General_CI_AS AS char(6)) AS windowsLatin1,
                    CAST(N'José €' COLLATE SQL_Latin1_General_CP1_CI_AS AS varchar(max)) AS maxText,
                    CAST(CAST(N'José' COLLATE SQL_Latin1_General_CP1_CI_AS AS varchar(20)) AS text) AS legacyText,
                    CAST(CAST(N'José' COLLATE SQL_Latin1_General_CP1_CI_AS AS varchar(20)) AS sql_variant) AS variant,
                    CAST(N'José ✓ 日本' COLLATE Latin1_General_100_CI_AS_SC_UTF8 AS varchar(40)) AS utf8,
                    CAST(N'plain' COLLATE Japanese_CI_AS AS varchar(20)) AS asciiInJapanese,
                    CHAR(129) COLLATE SQL_Latin1_General_CP1_CI_AS AS undefinedIn1252
                """
            ).rows

            expectEqual(rows.count, 1)
            let row = rows[0]
            expectEqual(try row.decode(column: "sqlLatin1", as: String.self), "José")
            expectEqual(try row.decode(column: "windowsLatin1", as: String.self), "José  ")
            expectEqual(try row.decode(column: "maxText", as: String.self), "José €")
            expectEqual(try row.decode(column: "legacyText", as: String.self), "José")
            expectEqual(try row.decode(column: "variant", as: String.self), "José")
            expectEqual(try row.decode(column: "utf8", as: String.self), "José ✓ 日本")
            expectEqual(try row.decode(column: "asciiInJapanese", as: String.self), "plain")
            expectEqual(try row.decode(column: "undefinedIn1252", as: String.self), "\u{81}")
        }
    }

    /// Non-ASCII text in a code page TDSNIO does not decode is a per-value error: the row still
    /// arrives, decoding the value as `String` throws, and the connection stays usable.
    @Test func nonASCIIVarcharInAnUnsupportedCodePageIsAPerValueError() async throws {
        try await withTDSConnection(on: NIOSingletons.posixEventLoopGroup.next()) { connection in
            let rows = try await connection.execute(
                """
                SELECT
                    CAST(N'Zażółć' COLLATE Polish_CI_AS AS varchar(20)) AS cp1250,
                    CAST(N'Привет' COLLATE Cyrillic_General_CI_AS AS varchar(20)) AS cp1251,
                    CAST(N'Γειά' COLLATE Greek_CI_AS AS varchar(20)) AS cp1253,
                    CAST(N'日本' COLLATE Japanese_CI_AS AS varchar(20)) AS cp932,
                    CAST(N'plain' COLLATE Greek_CI_AS AS varchar(20)) AS asciiInGreek
                """
            ).rows
            expectEqual(rows.count, 1)
            let row = rows[0]
            for (column, codePage, bytes) in [
                ("cp1250", 1250, [0x5A, 0x61, 0xBF, 0xF3, 0xB3, 0xE6]),
                ("cp1251", 1251, [0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2]),
                ("cp1253", 1253, [0xC3, 0xE5, 0xE9, 0xDC]),
                ("cp932", 932, [0x93, 0xFA, 0x96, 0x7B]),
            ] as [(String, UInt16, [UInt8])] {
                guard case .undecodableText(let text) = row[column] else {
                    Issue.record("\(column): expected .undecodableText, got \(String(describing: row[column]))")
                    continue
                }
                expectEqual(text.codePage, codePage)
                expectEqual(text.bytes, bytes)
                let error = #expect(throws: TDSDecodingError.self) {
                    try row.decode(column: column, as: String.self)
                }
                #expect(error?.columnName == column)
                #expect(error.map { String(reflecting: $0) }?.contains("code page \(codePage)") == true)
            }
            expectEqual(try row.decode(column: "asciiInGreek", as: String.self), "plain")

            // The same connection still works.
            let one = try await connection.execute("SELECT 1 AS one").rows
            expectEqual(try one[0].decode(column: "one", as: Int.self), 1)
        }
    }

    /// Undecodable text sent back as a parameter goes in its own collation, so SQL Server converts
    /// it without loss.
    @Test func undecodableTextRoundTripsAsAParameter() async throws {
        try await withTDSConnection(on: NIOSingletons.posixEventLoopGroup.next()) { connection in
            let value = try await connection.execute(
                "SELECT CAST(N'Zażółć' COLLATE Polish_CI_AS AS varchar(20)) AS v"
            ).rows[0]["v"]
            guard let value, case .undecodableText = value else {
                Issue.record("expected .undecodableText, got \(String(describing: value))")
                return
            }
            let rows = try await connection.execute(
                "SELECT CAST(\(value) AS nvarchar(20)) AS asUnicode"
            ).rows
            expectEqual(try rows[0].decode(column: "asUnicode", as: String.self), "Zażółć")
        }
    }
}
