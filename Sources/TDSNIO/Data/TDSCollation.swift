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

/// The 5-byte collation in a char, varchar or text column's TYPE_INFO (MS-TDS 2.2.5.1.2), and
/// the code page its bytes are in.
///
/// SQL Server sends char, varchar and text values as raw bytes in the column's code page, not
/// as UTF-8. The first four bytes are a little-endian word: the LCID in bits 0-19, comparison
/// flags in bits 20-25, `fUTF8` in bit 26 and the collation version in bits 28-31. The fifth
/// byte is the SQL sort ID, which is zero for Windows collations.
struct TDSCollation: Hashable, Sendable {
    static let utf8CodePage: UInt16 = 65001

    let bytes: [UInt8]

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    var lcid: UInt32? {
        self.word.map { $0 & 0xF_FFFF }
    }

    var isUTF8: Bool {
        self.word.map { $0 >> 26 & 1 == 1 } ?? false
    }

    var sortID: UInt8? {
        self.bytes.count == 5 ? self.bytes[4] : nil
    }

    /// `nil` when the collation is missing or unknown.
    ///
    /// A `_UTF8` collation is UTF-8. A SQL collation's code page follows from its sort ID, and a
    /// Windows collation's from its LCID.
    var codePage: UInt16? {
        guard let lcid = self.lcid, let sortID = self.sortID else {
            return nil
        }
        if self.isUTF8 {
            return Self.utf8CodePage
        }
        if sortID != 0 {
            return Self.codePageBySortID[sortID]
        }
        return Self.codePageByLCID[lcid]
    }

    private var word: UInt32? {
        guard self.bytes.count == 5 else {
            return nil
        }
        return UInt32(self.bytes[0]) | UInt32(self.bytes[1]) << 8 | UInt32(self.bytes[2]) << 16
            | UInt32(self.bytes[3]) << 24
    }

    // Both tables were read from SQL Server 2022 (16.0.4305.5): for every collation in
    // `sys.fn_helpcollations()` whose `COLLATIONPROPERTY(name, 'CodePage')` is not 0, the
    // collation bytes the server sends in COLMETADATA for a varchar column with that collation.
    // Every sort ID and every LCID mapped to exactly one code page.

    /// SQL collations (`SQL_*`).
    static let codePageBySortID: [UInt8: UInt16] = [
        30: 437, 31: 437, 32: 437, 33: 437, 34: 437, 40: 850, 41: 850, 42: 850, 43: 850, 44: 850, 49: 850,
        51: 1252, 52: 1252, 53: 1252, 54: 1252, 55: 850, 56: 850, 57: 850, 58: 850, 59: 850, 60: 850, 61: 850,
        81: 1250, 82: 1250, 83: 1250, 84: 1250, 85: 1250, 86: 1250, 87: 1250, 88: 1250, 89: 1250, 90: 1250,
        91: 1250, 92: 1250, 93: 1250, 94: 1250, 95: 1250, 96: 1250, 105: 1251, 106: 1251, 107: 1251, 108: 1251,
        113: 1253, 114: 1253, 120: 1253, 122: 1253, 124: 1253, 129: 1254, 130: 1254, 137: 1255, 138: 1255,
        145: 1256, 146: 1256, 153: 1257, 154: 1257, 155: 1257, 156: 1257, 157: 1257, 158: 1257, 159: 1257,
        160: 1257, 183: 1252, 184: 1252, 185: 1252, 186: 1252, 210: 1252, 211: 1252, 212: 1252, 213: 1252,
        214: 1252, 215: 1252, 216: 1252, 217: 1252,
    ]

    /// Windows collations (sort ID 0) that are not `_UTF8`.
    static let codePageByLCID: [UInt32: UInt16] = [
        0x00401: 1256, 0x00404: 950, 0x00405: 1250, 0x00406: 1252, 0x00408: 1253, 0x00409: 1252, 0x0040A: 1252,
        0x0040B: 1252, 0x0040C: 1252, 0x0040D: 1255, 0x0040E: 1250, 0x0040F: 1252, 0x00411: 932, 0x00412: 949,
        0x00414: 1252, 0x00415: 1250, 0x00417: 1252, 0x00418: 1250, 0x00419: 1251, 0x0041A: 1250, 0x0041B: 1250,
        0x0041C: 1250, 0x0041E: 874, 0x0041F: 1254, 0x00420: 1256, 0x00422: 1251, 0x00424: 1250, 0x00425: 1257,
        0x00426: 1257, 0x00427: 1257, 0x00429: 1256, 0x0042A: 1258, 0x0042C: 1254, 0x0042E: 1252, 0x0042F: 1251,
        0x0043B: 1252, 0x0043F: 1251, 0x00442: 1250, 0x00443: 1254, 0x00444: 1251, 0x00452: 1252, 0x00462: 1252,
        0x0046D: 1251, 0x0047A: 1252, 0x0047C: 1252, 0x0047E: 1252, 0x00480: 1256, 0x00483: 1252, 0x00485: 1251,
        0x0048C: 1256, 0x00804: 936, 0x0081A: 1250, 0x0082C: 1251, 0x0083B: 1252, 0x0085F: 1252, 0x00C04: 950,
        0x00C0A: 1252, 0x00C1A: 1251, 0x01404: 950, 0x0141A: 1250, 0x0201A: 1251, 0x10407: 1252, 0x1040E: 1250,
        0x10411: 932, 0x10437: 1252, 0x20804: 936, 0x21404: 950, 0x30404: 950, 0x40411: 932,
    ]
}

extension TDSCollation {
    /// Decodes a char, varchar or text value from this collation's code page.
    ///
    /// Supported: UTF-8 (`_UTF8` collations) and Windows-1252. Bytes below 0x80 mean the same
    /// in every code page SQL Server stores varchar in, so an all-ASCII value decodes whatever
    /// the collation. Any other value in an unsupported, unknown or missing code page, and
    /// invalid UTF-8, comes back as ``TDSData/undecodableText(_:)`` with its bytes: guessing
    /// would silently change the text, and failing the message would close the connection.
    func decodeText(_ bytes: [UInt8]) -> TDSData {
        if bytes.allSatisfy({ $0 < 0x80 }) {
            return .string(String(decoding: bytes, as: UTF8.self))
        }
        switch self.codePage {
        case Self.utf8CodePage:
            // Not `String(bytes:encoding: .utf8)`: Foundation drops a leading U+FEFF, which
            // SQL Server keeps. Decoding replaces invalid sequences, so compare to catch them.
            let string = String(decoding: bytes, as: UTF8.self)
            guard string.utf8.elementsEqual(bytes) else {
                return .undecodableText(
                    .init(bytes: bytes, collation: self.bytes, codePage: Self.utf8CodePage, reason: .invalidUTF8)
                )
            }
            return .string(string)
        case 1252:
            return .string(String(decoding: bytes.map { Self.windows1252[Int($0)] }, as: UTF16.self))
        case let codePage:
            return .undecodableText(
                .init(bytes: bytes, collation: self.bytes, codePage: codePage, reason: .unsupportedCodePage)
            )
        }
    }

    /// Windows-1252 as SQL Server converts it to Unicode. It differs from ISO-8859-1 only in
    /// 0x80-0x9F. The five bytes 1252 leaves undefined (0x81, 0x8D, 0x8F, 0x90, 0x9D) map to the
    /// C1 control with the same value, as SQL Server and Windows map them. Foundation's
    /// `.windowsCP1252` rejects them instead, so a value holding one would not decode at all.
    static let windows1252: [UInt16] = {
        let block80: [UInt16] = [
            0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
            0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
            0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
            0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
        ]
        return (0..<256).map { byte in
            (0x80..<0xA0).contains(byte) ? block80[byte - 0x80] : UInt16(byte)
        }
    }()
}
