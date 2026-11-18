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
import Foundation
import Logging
import NIOCore
import NIOEmbedded
import NIOSSL
import Testing

@testable import TDSNIO

extension TDSTests {
    /// With full encryption, only the TLS handshake travels inside PRELOGIN packets. LOGIN7 and
    /// everything after it must be written as raw TLS records, or the server never answers.
    @Test(arguments: [
        TDSFrontendMessageEncoder.PreloginEncryption.encryptOn,
        .encryptReq,
    ])
    func fullEncryptionSendsLoginAsRawTLSAfterHandshake(
        serverEncryption: TDSFrontendMessageEncoder.PreloginEncryption
    ) throws {
        var clientTLS = TLSConfiguration.makeClientConfiguration()
        clientTLS.certificateVerification = .none
        clientTLS.maximumTLSVersion = .tlsv12

        let logger = Logger(label: "tds-nio-tests")
        let configuration = TDSConnection.Configuration(
            host: "sql.example.test",
            username: "sa",
            password: "Secret123!",
            database: "master",
            tls: .require(try NIOSSLContext(configuration: clientTLS)),
            clientHostName: "client"
        )
        let client = EmbeddedChannel()
        let eventHandler = TDSEventsHandler(logger: logger)
        let channelHandler = TDSChannelHandler(configuration: configuration, logger: logger)
        try client.pipeline.syncOperations.addHandler(eventHandler)
        try client.pipeline.syncOperations.addHandler(channelHandler, position: .before(eventHandler))
        try client.pipeline.syncOperations.addHandler(
            TDSFrontendMessagePostProcessor(packetLength: configuration.packetSize),
            position: .before(channelHandler)
        )

        let server = EmbeddedChannel()
        try server.pipeline.syncOperations.addHandler(
            NIOSSLServerHandler(context: try Self.tlsServerContext())
        )

        // connect(to:) rather than fireChannelActive(): NIOSSL only starts a handshake on a
        // channel whose isActive is true.
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 1433)
        try client.connect(to: address).wait()
        try server.connect(to: address).wait()

        _ = try client.readOutbound(as: ByteBuffer.self)  // PRELOGIN request
        try client.writeInbound(
            Self.packet(
                type: .preloginLoginOrTablularResponse,
                payload: Self.preloginResponsePayload(encryption: serverEncryption)
            ))

        // Relay bytes the way SQL Server frames them: the server's handshake flight goes out
        // wrapped in PRELOGIN packets until the client starts sending raw TLS records.
        var clientSentRawTLS = false
        try Self.relay(
            client: client, server: server, until: { clientSentRawTLS },
            step: {
                if var chunk = try client.readOutbound(as: ByteBuffer.self) {
                    if chunk.getInteger(at: chunk.readerIndex, as: UInt8.self)
                        == TDSPacket.MessageType.prelogin.rawValue
                    {
                        #expect(!clientSentRawTLS, "PRELOGIN framing after raw TLS records")
                        chunk.moveReaderIndex(forwardBy: TDSPacket.headerLength)
                    } else {
                        clientSentRawTLS = true
                    }
                    try server.writeInbound(chunk)
                    return true
                }
                if let chunk = try server.readOutbound(as: ByteBuffer.self) {
                    try client.writeInbound(
                        clientSentRawTLS ? chunk : Self.packet(type: .prelogin, payload: chunk)
                    )
                    return true
                }
                return false
            })

        #expect(clientSentRawTLS, "LOGIN7 was never sent as a raw TLS record")
        guard let login = try server.readInbound(as: ByteBuffer.self) else {
            Issue.record("Server did not decrypt a LOGIN7 packet")
            return
        }
        expectEqual(
            login.getInteger(at: login.readerIndex, as: UInt8.self),
            TDSPacket.MessageType.tds7Login.rawValue
        )

        // The login response comes back as raw TLS too, and must complete startup. Any
        // post-login batch (the startup SET options) is answered with DONE.
        var startupCompleted = false
        eventHandler.startupDoneFuture.whenSuccess { _ in startupCompleted = true }
        try server.writeAndFlush(
            Self.packet(
                type: .preloginLoginOrTablularResponse,
                payload: Self.loginAckAndDonePayload()
            )
        ).wait()
        try Self.relay(
            client: client, server: server, until: { startupCompleted },
            step: {
                if let chunk = try client.readOutbound(as: ByteBuffer.self) {
                    try server.writeInbound(chunk)
                    return true
                }
                if try server.readInbound(as: ByteBuffer.self) != nil {
                    try server.writeAndFlush(
                        Self.packet(type: .preloginLoginOrTablularResponse, payload: Self.donePayload())
                    ).wait()
                    return true
                }
                if let chunk = try server.readOutbound(as: ByteBuffer.self) {
                    try client.writeInbound(chunk)
                    return true
                }
                return false
            })
        #expect(startupCompleted, "Startup did not complete over TLS")
    }

    /// Runs `step` until `done` holds. On Apple platforms NIOSSL validates the peer certificate
    /// on a Dispatch queue and resumes the handshake asynchronously, so an idle step is retried
    /// until a deadline instead of ending the relay.
    private static func relay(
        client: EmbeddedChannel,
        server: EmbeddedChannel,
        until done: () -> Bool,
        step: () throws -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(5)
        while !done(), Date() < deadline {
            client.embeddedEventLoop.run()
            server.embeddedEventLoop.run()
            if try !step() {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
    }

    private static func tlsServerContext() throws -> NIOSSLContext {
        var tls = TLSConfiguration.makeServerConfiguration(
            certificateChain: [
                .certificate(try NIOSSLCertificate(bytes: Array(testCertificatePEM.utf8), format: .pem))
            ],
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(testPrivateKeyPEM.utf8), format: .pem))
        )
        tls.maximumTLSVersion = .tlsv12
        return try NIOSSLContext(configuration: tls)
    }

    // Self-signed, test-only, CN=sql.example.test.
    private static let testCertificatePEM = """
        -----BEGIN CERTIFICATE-----
        MIIBjjCCATOgAwIBAgIUPNpmJSi0cJe4JwCDzxzkWj5zcfQwCgYIKoZIzj0EAwIw
        GzEZMBcGA1UEAwwQc3FsLmV4YW1wbGUudGVzdDAgFw0yNjA5MjQwMTUwNDRaGA8y
        MTI2MDgzMTAxNTA0NFowGzEZMBcGA1UEAwwQc3FsLmV4YW1wbGUudGVzdDBZMBMG
        ByqGSM49AgEGCCqGSM49AwEHA0IABNEtFMPFZhBkmRQlA6CM8CRCEMcXDmINQJrc
        aT4TKBE2ZufJbNf+DxB0dUhqVr/MWI9WqJe8oeUW1OMR5Rz3ww+jUzBRMB0GA1Ud
        DgQWBBR6w9gU2QyRm7vXWDBNsWv4S8N8qDAfBgNVHSMEGDAWgBR6w9gU2QyRm7vX
        WDBNsWv4S8N8qDAPBgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA0kAMEYCIQDQ
        /23ggO8mlZ23m0TiALNwlLo35YiwnlF3Ibv3VNHNaAIhAIAcccb7sBj26O3yHSvR
        nbC69TcCRAehsAcOPsWReMGJ
        -----END CERTIFICATE-----
        """

    private static let testPrivateKeyPEM = """
        -----BEGIN PRIVATE KEY-----
        MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg6BjiH0ao0FfdP00n
        eGlgIGvev8VPz5Nva/t+6BfYYbahRANCAATRLRTDxWYQZJkUJQOgjPAkQhDHFw5i
        DUCa3Gk+EygRNmbnyWzX/g8QdHVIala/zFiPVqiXvKHlFtTjEeUc98MP
        -----END PRIVATE KEY-----
        """
}
