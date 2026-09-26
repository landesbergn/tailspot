//
//  PushTokenClientTests.swift
//  TailspotTests
//
//  `PushTokenClient` against a `URLProtocol` stub — method, path, auth
//  header, body shape, the 204 contract, the error mapping, and the
//  idempotence rule that keeps a launch-time re-register from POSTing once
//  per app open. Plus `PushEnvironment`'s provisioning-profile parser,
//  which is pure and needs no bundle.
//
//  `.serialized`: the stub's queue is process-global static state (a real
//  `URLProtocol` subclass has no instance the session hands back), so tests
//  in this suite must not interleave. Its own stub class rather than
//  `ChallengesStubProtocol` for the same reason — two suites sharing one
//  global queue could interleave across suites.
//

import Foundation
import Testing
@testable import Tailspot

final class PushTokenStubProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 204
    nonisolated(unsafe) static var transportError: Error?
    nonisolated(unsafe) static var recorded: [URLRequest] = []

    static func reset() {
        status = 204
        transportError = nil
        recorded = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession rewrites `httpBody` into `httpBodyStream` before it
        // reaches a registered URLProtocol — read it back or every POST
        // records a nil body.
        var recordedRequest = request
        if recordedRequest.httpBody == nil, let stream = request.httpBodyStream {
            recordedRequest.httpBody = Self.drain(stream)
        }
        Self.recorded.append(recordedRequest)
        if let error = Self.transportError {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

@Suite("Push token client", .serialized)
struct PushTokenClientTests {

    init() {
        PushTokenStubProtocol.reset()
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PushTokenStubProtocol.self]
        return URLSession(configuration: config)
    }

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "PushTokenClientTests.\(UUID().uuidString)")!
    }

    private func makeClient(defaults: UserDefaults, build: Int = 120) -> PushTokenClient {
        PushTokenClient(
            baseURL: URL(string: "https://api.example.test")!,
            session: makeSession(),
            defaults: defaults,
            build: build,
            tokenProvider: { "device-token-abc" })
    }

    private func body(_ request: URLRequest) -> [String: Any] {
        guard let data = request.httpBody,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }

    // MARK: - the request

    @Test func postsTheContractedShape() async throws {
        let client = makeClient(defaults: freshDefaults())
        try await client.register(token: "a1b2c3", environment: PushEnvironment.sandbox)

        let request = try #require(PushTokenStubProtocol.recorded.last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.example.test/v1/devices/push-token")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer device-token-abc")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(abs(request.timeoutInterval - 15) < 0.001)

        let json = body(request)
        #expect(json["token"] as? String == "a1b2c3")
        #expect(json["environment"] as? String == "sandbox")
        #expect(json["build"] as? Int == 120)
    }

    @Test func aTwoHundredIsAlsoAccepted() async throws {
        PushTokenStubProtocol.status = 200
        try await makeClient(defaults: freshDefaults())
            .register(token: "a1b2c3", environment: PushEnvironment.production)
    }

    @Test func unauthorizedIsTyped() async {
        PushTokenStubProtocol.status = 401
        await #expect(throws: PushTokenError.unauthorized) {
            try await makeClient(defaults: freshDefaults())
                .register(token: "a1b2c3", environment: PushEnvironment.sandbox)
        }
    }

    @Test func otherStatusesCarryTheirCode() async {
        PushTokenStubProtocol.status = 500
        await #expect(throws: PushTokenError.http(500)) {
            try await makeClient(defaults: freshDefaults())
                .register(token: "a1b2c3", environment: PushEnvironment.sandbox)
        }
    }

    @Test func aTransportFailureIsTyped() async {
        PushTokenStubProtocol.transportError = URLError(.notConnectedToInternet)
        await #expect(throws: PushTokenError.self) {
            try await makeClient(defaults: freshDefaults())
                .register(token: "a1b2c3", environment: PushEnvironment.sandbox)
        }
    }

    // MARK: - idempotence

    @Test func theSameTokenIsNotUploadedTwice() async {
        let defaults = freshDefaults()
        let client = makeClient(defaults: defaults)

        await client.registerIfChanged(token: "a1b2c3", environment: PushEnvironment.sandbox)
        #expect(PushTokenStubProtocol.recorded.count == 1)

        // Every launch re-registers and iOS hands back the same token.
        await client.registerIfChanged(token: "a1b2c3", environment: PushEnvironment.sandbox)
        #expect(PushTokenStubProtocol.recorded.count == 1, "an unchanged token must not re-POST")
    }

    @Test func aChangedTokenOrEnvironmentUploadsAgain() async {
        let defaults = freshDefaults()
        let client = makeClient(defaults: defaults)

        await client.registerIfChanged(token: "a1b2c3", environment: PushEnvironment.sandbox)
        await client.registerIfChanged(token: "ffffff", environment: PushEnvironment.sandbox)
        #expect(PushTokenStubProtocol.recorded.count == 2)

        // Same token, archived for the App Store: a sandbox token sent to
        // the production gateway is silently dropped, so this must re-upload.
        await client.registerIfChanged(token: "ffffff", environment: PushEnvironment.production)
        #expect(PushTokenStubProtocol.recorded.count == 3)
    }

    /// A failed upload must not latch: the next launch has to try again.
    @Test func aFailedUploadIsRetriedOnTheNextLaunch() async {
        PushTokenStubProtocol.status = 500
        let defaults = freshDefaults()
        let client = makeClient(defaults: defaults)

        await client.registerIfChanged(token: "a1b2c3", environment: PushEnvironment.sandbox)
        #expect(PushTokenStubProtocol.recorded.count == 1)
        #expect(client.lastUploaded == nil, "a failure must remember nothing")

        PushTokenStubProtocol.status = 204
        await client.registerIfChanged(token: "a1b2c3", environment: PushEnvironment.sandbox)
        #expect(PushTokenStubProtocol.recorded.count == 2)
        #expect(client.lastUploaded == "sandbox:a1b2c3:120")
    }

    /// `build` is in the request body, so the server's row records which
    /// client version a token came from. With the build left out of the
    /// stamp, an app update never re-sent it and every upgraded device
    /// stayed recorded at the build it first registered on.
    @Test func anAppUpdateReUploadsTheSameToken() async {
        let defaults = freshDefaults()
        await makeClient(defaults: defaults, build: 120)
            .registerIfChanged(token: "a1b2c3", environment: PushEnvironment.sandbox)
        #expect(PushTokenStubProtocol.recorded.count == 1)

        // Same device, same token, same environment — new build.
        await makeClient(defaults: defaults, build: 121)
            .registerIfChanged(token: "a1b2c3", environment: PushEnvironment.sandbox)
        #expect(PushTokenStubProtocol.recorded.count == 2)
        #expect(body(PushTokenStubProtocol.recorded[1])["build"] as? Int == 121)

        // And that new build is now the one remembered.
        await makeClient(defaults: defaults, build: 121)
            .registerIfChanged(token: "a1b2c3", environment: PushEnvironment.sandbox)
        #expect(PushTokenStubProtocol.recorded.count == 2)
    }

    @Test func theSkipRuleIsPure() {
        #expect(PushTokenClient.shouldUpload(token: "a1", environment: "sandbox",
                                             build: 1, lastUploaded: nil))
        #expect(!PushTokenClient.shouldUpload(token: "a1", environment: "sandbox",
                                              build: 1, lastUploaded: "sandbox:a1:1"))
        #expect(PushTokenClient.shouldUpload(token: "a1", environment: "production",
                                             build: 1, lastUploaded: "sandbox:a1:1"))
        #expect(PushTokenClient.shouldUpload(token: "a2", environment: "sandbox",
                                             build: 1, lastUploaded: "sandbox:a1:1"))
        // A new build re-sends the same token.
        #expect(PushTokenClient.shouldUpload(token: "a1", environment: "sandbox",
                                             build: 2, lastUploaded: "sandbox:a1:1"))
        // An empty token is not a token.
        #expect(!PushTokenClient.shouldUpload(token: "", environment: "sandbox",
                                              build: 1, lastUploaded: nil))
    }

    @Test func anEmptyTokenIsNeverPosted() async {
        let client = makeClient(defaults: freshDefaults())
        await client.registerIfChanged(token: "", environment: PushEnvironment.sandbox)
        #expect(PushTokenStubProtocol.recorded.isEmpty)
    }
}

// MARK: - PushEnvironment

@Suite("Push environment")
struct PushEnvironmentTests {

    /// A provisioning profile as the parser sees it: an XML plist buried in
    /// a binary CMS blob. The bytes either side stand in for the signature.
    private func profile(apsEnvironment: String?) -> Data {
        var plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Name</key>
            <string>Tailspot Development</string>
            <key>Entitlements</key>
            <dict>
                <key>application-identifier</key>
                <string>ABCDE12345.com.landesberg.tailspot</string>
        """
        if let apsEnvironment {
            plist += """

                    <key>aps-environment</key>
                    <string>\(apsEnvironment)</string>
            """
        }
        plist += """

            </dict>
        </dict>
        </plist>
        """
        var data = Data([0x30, 0x82, 0x0A, 0xBC, 0x06, 0x09])   // CMS header noise
        data.append(Data(plist.utf8))
        data.append(Data([0x00, 0x01, 0x02, 0x03]))             // signature noise
        return data
    }

    @Test func developmentMapsToSandbox() {
        #expect(PushEnvironment.environment(fromProvisioningProfile: profile(apsEnvironment: "development"))
                == "sandbox")
    }

    @Test func productionStaysProduction() {
        #expect(PushEnvironment.environment(fromProvisioningProfile: profile(apsEnvironment: "production"))
                == "production")
    }

    @Test func aProfileWithoutTheEntitlementHasNoEnvironment() {
        #expect(PushEnvironment.environment(fromProvisioningProfile: profile(apsEnvironment: nil)) == nil)
    }

    @Test func rubbishBytesAreNotAProfile() {
        #expect(PushEnvironment.environment(fromProvisioningProfile: Data([0x00, 0xFF, 0x10])) == nil)
        #expect(PushEnvironment.environment(fromProvisioningProfile: Data()) == nil)
        // An opening tag with no closing tag must not be read as a plist.
        #expect(PushEnvironment.environment(
            fromProvisioningProfile: Data("<plist version=\"1.0\"><dict>".utf8)) == nil)
    }

    @Test func theEmbeddedPlistIsFoundInsideTheBlob() throws {
        let plist = try #require(PushEnvironment.embeddedPlist(in: profile(apsEnvironment: "development")))
        #expect(plist["Name"] as? String == "Tailspot Development")
    }

    /// An unrecognized Apple value passes through rather than being guessed
    /// into the wrong gateway.
    @Test func mappingIsExplicit() {
        #expect(PushEnvironment.mapped(apsEnvironment: "development") == "sandbox")
        #expect(PushEnvironment.mapped(apsEnvironment: "production") == "production")
        #expect(PushEnvironment.mapped(apsEnvironment: "") == nil)
        #expect(PushEnvironment.mapped(apsEnvironment: "something-new") == "something-new")
    }

    /// Unit tests run on the simulator, which has no APNs and no embedded
    /// profile — so the app must never try to register there.
    @Test func theSimulatorHasNoEnvironment() {
        #expect(PushEnvironment.current() == nil)
    }
}
