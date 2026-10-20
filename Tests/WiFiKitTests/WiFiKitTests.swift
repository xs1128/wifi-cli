import Darwin
import Foundation
import XCTest
@testable import WiFiKit

final class RecordingBackend: WiFiBackend {
    var calls: [String] = []
    var joinFailure: Failure?
    func status(interface: String?) throws -> WiFiStatus {
        calls.append("status")
        return WiFiStatus(interface: interface ?? "en0", poweredOn: true, association: "associated",
                          ssid: nil, bssid: nil, rssiDBm: -60, noiseDBm: -90, transmitRateMbps: 400,
                          channel: 36, band: "5 GHz", addresses: [], router: nil, dnsServers: [])
    }
    func scan(interface: String?) throws -> [Network] { calls.append("scan"); return [] }
    func join(interface: String?, ssid: String, password: String?, open: Bool) throws {
        calls.append("join")
        if let joinFailure { throw joinFailure }
    }
    func disconnect(interface: String?) throws { calls.append("disconnect") }
    func setPower(interface: String?, on: Bool) throws { calls.append("power:\(on)") }
}

final class WiFiKitTests: XCTestCase {
    func testDryRunsNeverCallAnyBackendMethod() throws {
        let backend = RecordingBackend()
        for args in [["join", "example", "--dry-run"], ["disconnect", "--dry-run"], ["power", "off", "--dry-run"]] {
            let request = try XCTUnwrap(Command.parse(args).request)
            let response = try Engine.execute(request, backend: backend)
            XCTAssertTrue(response.ok)
            XCTAssertTrue(response.message!.contains("no backend operation"))
        }
        XCTAssertTrue(backend.calls.isEmpty)
    }

    func testInvalidJoinDoesNotTouchBackend() {
        var request = Request(.join)
        request.ssid = "example"
        let backend = RecordingBackend()
        XCTAssertThrowsError(try Engine.execute(request, backend: backend))
        XCTAssertTrue(backend.calls.isEmpty)
    }

    func testStatusDoesNotScanAndPreservesAssociationWithoutSSID() throws {
        let backend = RecordingBackend()
        let response = try Engine.execute(Request(.status), backend: backend)
        XCTAssertEqual(backend.calls, ["status"])
        XCTAssertEqual(response.status?.association, "associated")
        XCTAssertNil(response.status?.ssid)
    }

    func testHiddenIdentityIsNotDisconnected() {
        XCTAssertEqual(WiFiStatus.association(poweredOn: true, ssid: nil, phy: 6, mode: 1), "associated")
        XCTAssertEqual(WiFiStatus.association(poweredOn: false, ssid: nil, phy: 0, mode: 0), "poweredOff")
        XCTAssertEqual(WiFiStatus.association(poweredOn: true, ssid: nil, phy: 0, mode: 0), "disconnected")
        XCTAssertEqual(WiFiStatus.association(poweredOn: true, ssid: nil, phy: 0, mode: 3), "unknown")
    }

    func testFailedJoinNeverRetriesOrTogglesPower() {
        let backend = RecordingBackend()
        backend.joinFailure = Failure("authentication", "Rejected")
        var request = Request(.join)
        request.ssid = "example"; request.password = "private-password"
        XCTAssertThrowsError(try Engine.execute(request, backend: backend))
        XCTAssertEqual(backend.calls, ["join"])
    }

    func testPasswordsNeverAppearInResponses() throws {
        var request = Request(.join)
        request.ssid = "example"; request.password = "unique-test-secret-123"
        let response = try Engine.execute(request, backend: RecordingBackend())
        let encoded = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
        XCTAssertFalse(encoded.contains("unique-test-secret-123"))
        XCTAssertFalse(encoded.contains("password"))
    }

    func testPositionalPasswordsAreRejectedWithoutEchoingThem() {
        XCTAssertThrowsError(try Command.parse(["join", "example", "unique-test-secret-123"])) { error in
            XCTAssertFalse((error as! Failure).message.contains("unique-test-secret-123"))
        }
    }

    func testMistypedPasswordOptionsAreNotReflectedInErrors() {
        XCTAssertThrowsError(try Command.parse(["join", "example", "--unique-test-secret"])) { error in
            XCTAssertFalse((error as! Failure).message.contains("unique-test-secret"))
        }
    }

    func testSSIDUsesByteLimitAndPreservesWhitespace() throws {
        XCTAssertThrowsError(try Command.parse(["join", String(repeating: "🛜", count: 9), "--dry-run"]))
        let request = try XCTUnwrap(Command.parse(["join", " example ", "--dry-run"]).request)
        XCTAssertEqual(request.ssid, " example ")
    }

    func testLiteralSSIDAndExplicitInterface() throws {
        let command = try Command.parse(["--interface", "en3", "join", "--dry-run", "--", "--strange-name"])
        XCTAssertEqual(command.request?.ssid, "--strange-name")
        XCTAssertEqual(command.request?.interface, "en3")
    }

    func testUnsafeOrConflictingArguments() {
        let cases = [
            ["status", "--request"], ["status", "--dry-run"], ["status", "--password-stdin"],
            ["join", "example", "--open", "--password-stdin"], ["status", "--timeout", "nan"],
            ["status", "--timeout", "0"], ["status", "--timeout", "121"],
            ["status", "--interface", "en0;whoami"], ["power", "toggle"],
            ["status", "--json", "--json"], ["join", "bad\0ssid", "--dry-run"],
        ]
        for args in cases { XCTAssertThrowsError(try Command.parse(args), "\(args)") }
    }

    func testOpenRequestCannotCarryCredentials() {
        var request = Request(.join)
        request.ssid = "example"; request.openNetwork = true; request.password = "secret"
        XCTAssertThrowsError(try request.validate())
    }

    func testTerminalControlCharactersAreEscaped() {
        XCTAssertEqual(terminalSafe("safe\u{1B}[2J\n\u{202E}"), "safe\\u{001B}[2J\\u{000A}\\u{202E}")
        XCTAssertEqual(terminalSafe("清華 Wi-Fi"), "清華 Wi-Fi")
    }

    func testErrorExitCodesAreUsefulToScripts() {
        XCTAssertEqual(Failure("arguments", "").exitCode, 2)
        XCTAssertEqual(Failure("permission", "").exitCode, 3)
        XCTAssertEqual(Failure("timeout", "").exitCode, 4)
        XCTAssertEqual(Failure("authentication", "").exitCode, 5)
    }

    func pair(timeout: TimeInterval = 1) throws -> (Channel, Channel) {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        let deadline = Deadline(seconds: timeout)
        return try (Channel(fd: descriptors[0], deadline: deadline), Channel(fd: descriptors[1], deadline: deadline))
    }

    func testLocalFramingRoundTrip() throws {
        let (sender, receiver) = try pair()
        var request = Request(.join)
        request.ssid = "清華 Wi-Fi"; request.password = "test-only-password"
        try sender.send(request)
        let received = try receiver.receive(Request.self)
        XCTAssertEqual(received.ssid, request.ssid)
        XCTAssertEqual(received.password, request.password)
    }

    func testMalformedAndOversizedFramesAreRejected() throws {
        for bytes: [UInt8] in [[0, 16, 0, 1], [0, 0, 0, 0], [0, 0, 0, 1, 0x7B]] {
            let (sender, receiver) = try pair()
            _ = bytes.withUnsafeBytes { Darwin.send(sender.fd, $0.baseAddress, $0.count, 0) }
            XCTAssertThrowsError(try receiver.receive(Request.self)) { error in
                XCTAssertEqual((error as? Failure)?.code, "protocol")
            }
        }
    }

    func testReadDeadlineIsBounded() throws {
        let (sender, receiver) = try pair(timeout: 0.03)
        let start = ProcessInfo.processInfo.systemUptime
        try withExtendedLifetime(sender) {
            XCTAssertThrowsError(try receiver.receive(Request.self)) { error in
                XCTAssertEqual((error as? Failure)?.code, "timeout")
            }
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.5)
    }

    func testPrivateSocketModesAndCleanup() throws {
        var listener: Listener? = try Listener()
        let directory = listener!.directory, path = listener!.path
        var info = stat()
        XCTAssertEqual(lstat(directory, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
        XCTAssertEqual(lstat(path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        listener = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory))
    }

    func testHelperRejectsAnInsecureSocketDirectory() throws {
        let listener = try Listener()
        XCTAssertEqual(chmod(listener.directory, 0o755), 0)
        defer { chmod(listener.directory, 0o700) }
        XCTAssertThrowsError(try Channel.connect(path: listener.path, deadline: Deadline(seconds: 1)))
    }
}
