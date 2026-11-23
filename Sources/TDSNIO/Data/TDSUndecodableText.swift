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

/// A char, varchar or text value that TDSNIO received but could not turn into a `String`.
///
/// SQL Server sends these types as bytes in the column collation's code page. TDSNIO decodes
/// UTF-8 (`_UTF8` collations), Windows-1252, and plain ASCII in any code page. Anything else
/// arrives as ``TDSData/undecodableText(_:)`` instead of failing the whole response, so the rest
/// of the row and the connection stay usable. Decoding the value as `String` throws
/// ``TDSDecodingError/Code/undecodableText(_:)``.
///
/// ``description`` names the code page and the byte count, never the bytes: they are row data.
public struct TDSUndecodableText: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    public enum Reason: Sendable, Hashable {
        /// The collation's code page is one TDSNIO does not decode, or is unknown.
        case unsupportedCodePage
        /// The collation is `_UTF8`, but the bytes are not valid UTF-8.
        case invalidUTF8
    }

    /// The value as SQL Server sent it, in the collation's code page.
    public var bytes: [UInt8]
    /// The 5-byte collation from the column's TYPE_INFO (MS-TDS 2.2.5.1.2). Empty when the type
    /// carries none.
    public var collation: [UInt8]
    /// The collation's code page, or `nil` when TDSNIO does not know it.
    public var codePage: UInt16?
    public var reason: Reason

    public init(bytes: [UInt8], collation: [UInt8], codePage: UInt16?, reason: Reason) {
        self.bytes = bytes
        self.collation = collation
        self.codePage = codePage
        self.reason = reason
    }

    public var description: String {
        let collation = self.collation.map { byte in
            let hex = String(byte, radix: 16, uppercase: true)
            return byte < 0x10 ? "0" + hex : hex
        }.joined(separator: " ")
        switch self.reason {
        case .invalidUTF8:
            return "Cannot decode char/varchar/text (\(self.bytes.count) bytes): "
                + "invalid UTF-8 in a _UTF8 collation [\(collation)]."
        case .unsupportedCodePage:
            let codePage = self.codePage.map { "code page \($0)" } ?? "an unknown code page"
            return """
                Cannot decode char/varchar/text (\(self.bytes.count) bytes): its collation [\(collation)] \
                is \(codePage). TDSNIO decodes only UTF-8 and Windows-1252 text that is not plain ASCII. \
                Cast the column to nvarchar, or use a _UTF8 or Latin1 collation.
                """
        }
    }

    public var debugDescription: String {
        "TDSUndecodableText(\(self.description))"
    }
}
