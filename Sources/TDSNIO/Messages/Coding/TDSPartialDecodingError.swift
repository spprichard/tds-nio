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

struct TDSPartialDecodingError: Error {
    /// A textual description of the error.
    let description: String

    /// The file this error was thrown in.
    let file: String

    /// The line in ``file`` this error was thrown in.
    let line: Int

    static func expectedAtLeastNRemainingBytes(
        _ expected: Int, actual: Int,
        file: String = #fileID, line: Int = #line
    ) -> Self {
        TDSPartialDecodingError(
            description: "Expected at least '\(expected)' remaining bytes. But found \(actual).",
            file: file, line: line
        )
    }

    static func fieldNotDecodable(
        type: Any.Type, file: String = #fileID, line: Int = #line
    ) -> Self {
        TDSPartialDecodingError(
            description: "Could not read '\(type)' from ByteBuffer.", file: file, line: line)
    }

    static func unknownMessageIDReceived(
        messageID: UInt8,
        file: String = #fileID,
        line: Int = #line
    ) -> Self {
        TDSPartialDecodingError(
            description: """
                Received a message with messageID '\(messageID)'. There is no \
                message type associated with this message identifier.
                """,
            file: file,
            line: line
        )
    }

    static func unknownTokenReceived(
        token: UInt8,
        file: String = #fileID,
        line: Int = #line
    ) -> Self {
        TDSPartialDecodingError(
            description: """
                Received a token with type '\(token)'. There is no token type \
                associated with this token identifier.
                """,
            file: file,
            line: line
        )
    }

    static func invalidPacketLength(
        _ length: Int,
        minimum: Int,
        file: String = #fileID,
        line: Int = #line
    ) -> Self {
        TDSPartialDecodingError(
            description: "Received a packet length of '\(length)', expected at least '\(minimum)'.",
            file: file,
            line: line
        )
    }

    static func unsupportedCodePage(
        _ codePage: UInt16?,
        collation: TDSCollation,
        file: String = #fileID,
        line: Int = #line
    ) -> Self {
        let bytes = collation.bytes.map { String($0, radix: 16, uppercase: true) }.joined(separator: " ")
        let codePageDescription = codePage.map { "code page \($0)" } ?? "an unknown code page"
        return TDSPartialDecodingError(
            description: """
                Cannot decode char/varchar/text: its collation [\(bytes)] is \(codePageDescription). \
                TDSNIO decodes only UTF-8 and Windows-1252 text that is not plain ASCII. \
                Cast the column to nvarchar, or use a _UTF8 or Latin1 collation.
                """,
            file: file,
            line: line
        )
    }

    static func invalidUTF8Text(
        collation: TDSCollation,
        file: String = #fileID,
        line: Int = #line
    ) -> Self {
        let bytes = collation.bytes.map { String($0, radix: 16, uppercase: true) }.joined(separator: " ")
        return TDSPartialDecodingError(
            description: "Cannot decode char/varchar/text: invalid UTF-8 in a _UTF8 collation [\(bytes)].",
            file: file,
            line: line
        )
    }

    static func unsupportedRoutingProtocol(
        _ protocolByte: UInt8,
        file: String = #fileID,
        line: Int = #line
    ) -> Self {
        TDSPartialDecodingError(
            description: "Unsupported routing ENVCHANGE protocol byte '\(protocolByte)'.",
            file: file,
            line: line
        )
    }
}
