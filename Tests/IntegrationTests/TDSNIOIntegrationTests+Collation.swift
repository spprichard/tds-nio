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

    @Test func nonASCIIVarcharInAnUnsupportedCodePageFailsInsteadOfAlteringText() async throws {
        // The failed decode closes the connection, so this does not use `withTDSConnection`.
        let connection = try await TDSConnection.test(on: NIOSingletons.posixEventLoopGroup.next())
        await #expect {
            _ = try await connection.execute(
                "SELECT CAST(N'日本' COLLATE Japanese_CI_AS AS varchar(20)) AS japanese"
            )
        } throws: { error in
            String(reflecting: error).contains("code page 932")
        }
        try? await connection.close()
    }
}
