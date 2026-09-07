#if os(macOS)
import XCTest
@testable import NanocodexRemote

private final class RecoveryCapture: RemoteCapture, @unchecked Sendable {
    var onFailure: @Sendable (Error) -> Void = { _ in }
    @MainActor var stops = 0
    @MainActor func stop() async { stops += 1 }
}

@MainActor private final class RecoveryInput: RemoteInputInjector {
    var controlAllowed = true
    var releases = 0
    var applied = 0
    func apply(_ event: RemoteInput) throws { applied += 1 }
    func releaseAll() { releases += 1 }
}

@MainActor private final class RecoverySocket: RemoteHostSignaling {
    var onMessage: (RemoteMessage) -> Void = { _ in }
    var onClose: (Error?) -> Void = { _ in }
    var messages: [RemoteMessage] = []
    var closed = false
    var connectError: Error?
    let generation = UUID().uuidString
    func connect(hand: RemoteHand?) throws {
        if let connectError { throw connectError }
        onMessage(.init(type: "ready"))
    }
    func send(_ message: RemoteMessage) {
        messages.append(message)
        if message.type == "catalog" {
            var reply = RemoteMessage(type: "published"); reply.generation = generation
            onMessage(reply)
        }
    }
    func close(error: Error?) { closed = true; onClose(error) }
}

final class RemoteHostRecoveryTests: XCTestCase {
    private func service() throws -> RemoteService {
        try RemoteService(origin: URL(string: "https://recovery.test")!) { _ in }
    }

    @MainActor private func publish(_ host: RemoteMacHost, service: RemoteService,
                                    capture: RecoveryCapture, input: RecoveryInput? = nil,
                                    kind: RemoteSurface.Kind = .desktop, machine: String = "owned-mac") async {
        let surface = RemoteSurface(id: "display-42", name: "Selected display", kind: kind,
            width: 1600, height: 900, controllable: true)
        let input = input ?? RecoveryInput()
        await host.publish(service: service, machineID: machine, name: "My Mac", surface: surface) { _ in (capture, input) }
    }

    @MainActor func testNetworkReconnectRetainsCaptureAndIdentityButReleasesInput() async throws {
        let service = try service(), host = RemoteMacHost(), capture = RecoveryCapture(), input = RecoveryInput()
        defer { service.close() }
        var sockets: [RecoverySocket] = [], checks = 0
        host.makeSignaling = { _ in let socket = RecoverySocket(); sockets.append(socket); return socket }
        host.checkAuthorization = { current in XCTAssertTrue(current === service); checks += 1 }
        host.recoveryDelay = { _ in .milliseconds(10) }
        await publish(host, service: service, capture: capture, input: input)
        XCTAssertTrue(host.sharing)
        let first = try XCTUnwrap(sockets.first), lateMessage = first.onMessage, lateClose = first.onClose
        var call = RemoteMessage(type: "agent_call")
        call.requestID = UUID().uuidString; call.agentID = "fixture"; call.surfaceID = "display-42"
        call.generation = first.generation; call.deadlineAt = Date().timeIntervalSince1970 * 1000 + 5_000
        call.input = RemoteAgentInput(action: "drag", x: 0.2, y: 0.2, endX: 0.8, endY: 0.8, durationMs: 1_000)
        first.onMessage(call)
        try await eventually { input.applied > 0 }
        let releases = input.releases
        first.onClose(NSError(domain: NSPOSIXErrorDomain, code: 57)) // Socket is not connected.
        XCTAssertTrue(host.reconnecting); XCTAssertFalse(host.sharing)
        XCTAssertEqual(host.surface?.id, "display-42"); XCTAssertEqual(host.viewerCount, 0)
        XCTAssertGreaterThan(input.releases, releases)
        XCTAssertEqual(capture.stops, 0)
        try await eventually { sockets.count == 2 && host.sharing }
        XCTAssertEqual(checks, 1); XCTAssertFalse(host.reconnecting)
        let catalog = try XCTUnwrap(sockets[1].messages.first { $0.type == "catalog" })
        XCTAssertEqual(catalog.machineID, "owned-mac")
        XCTAssertEqual(catalog.surfaces?.first?.id, "display-42")
        var stale = RemoteMessage(type: "published"); stale.generation = first.generation
        lateMessage(stale); lateClose(RemoteError.unauthorized)
        XCTAssertTrue(host.sharing); XCTAssertEqual(capture.stops, 0)
        await host.stop()
        XCTAssertEqual(capture.stops, 1); XCTAssertFalse(host.sharing); XCTAssertFalse(host.reconnecting)
    }

    @MainActor func testStopAndAccountReplacementFenceAnOutstandingAuthorization() async throws {
        let firstService = try service(), nextService = try service(), host = RemoteMacHost()
        defer { firstService.close(); nextService.close() }
        let oldCapture = RecoveryCapture(), nextCapture = RecoveryCapture()
        var sockets: [RecoverySocket] = []
        var pending: CheckedContinuation<Void, Never>?
        host.makeSignaling = { _ in let socket = RecoverySocket(); sockets.append(socket); return socket }
        host.recoveryDelay = { _ in .milliseconds(1) }
        host.checkAuthorization = { _ in await withCheckedContinuation { pending = $0 } }
        await publish(host, service: firstService, capture: oldCapture)
        sockets[0].onClose(URLError(.networkConnectionLost))
        try await eventually { pending != nil }
        await host.stop()
        XCTAssertEqual(oldCapture.stops, 1); XCTAssertFalse(host.reconnecting)
        await publish(host, service: nextService, capture: nextCapture, machine: "replacement-account-mac")
        pending?.resume(); pending = nil
        await Task.yield()
        XCTAssertEqual(sockets.count, 2)
        XCTAssertTrue(host.sharing); XCTAssertEqual(nextCapture.stops, 0)
        XCTAssertEqual(sockets[1].messages.first?.machineID, "replacement-account-mac")
        await host.stop()
    }

    @MainActor func testUnauthorizedRecoveryStopsBeforeOpeningAnotherSocket() async throws {
        let service = try service(), host = RemoteMacHost(), capture = RecoveryCapture()
        defer { service.close() }
        var sockets: [RecoverySocket] = []
        host.makeSignaling = { _ in let socket = RecoverySocket(); sockets.append(socket); return socket }
        host.recoveryDelay = { _ in .milliseconds(1) }
        host.checkAuthorization = { _ in throw RemoteError.unauthorized }
        await publish(host, service: service, capture: capture)
        sockets[0].onClose(URLError(.badServerResponse))
        try await eventually { capture.stops == 1 }
        XCTAssertFalse(host.reconnecting); XCTAssertFalse(host.sharing)
        XCTAssertEqual(host.status, RemoteError.unauthorized.localizedDescription)
        XCTAssertEqual(sockets.count, 1)
        await host.stop()
    }

    @MainActor func testCaptureFailureDuringReconnectRemainsTerminal() async throws {
        let service = try service(), host = RemoteMacHost(), capture = RecoveryCapture()
        defer { service.close() }
        let socket = RecoverySocket()
        host.makeSignaling = { _ in socket }
        host.recoveryDelay = { _ in .seconds(1) }
        await publish(host, service: service, capture: capture)
        socket.onClose(URLError(.notConnectedToInternet))
        XCTAssertTrue(host.reconnecting)
        capture.onFailure(RemoteError.geometryChanged)
        try await eventually { capture.stops == 1 }
        XCTAssertFalse(host.reconnecting); XCTAssertFalse(host.sharing)
        XCTAssertEqual(host.status, RemoteError.geometryChanged.localizedDescription)
        await host.stop()
    }

    @MainActor func testPhonePublicationIsNeverAutomaticallyRestarted() async throws {
        let service = try service(), host = RemoteMacHost(), capture = RecoveryCapture()
        defer { service.close() }
        let socket = RecoverySocket()
        host.makeSignaling = { _ in socket }
        host.checkAuthorization = { _ in XCTFail("Phone host must not enter Mac recovery") }
        await publish(host, service: service, capture: capture, kind: .phone)
        socket.onClose(URLError(.networkConnectionLost))
        try await eventually { capture.stops == 1 }
        XCTAssertFalse(host.reconnecting); XCTAssertFalse(host.sharing)
        await host.stop()
    }

    @MainActor func testExplicitAuthenticationAndPermissionFailuresDoNotScheduleRecovery() async throws {
        let service = try service()
        defer { service.close() }
        for error: Error in [RemoteError.unauthorized, RemoteError.screenPermission, RemoteError.inputPermission,
                             RemoteError.geometryChanged, URLError(.cancelled)] {
            let host = RemoteMacHost(), capture = RecoveryCapture(), socket = RecoverySocket()
            host.makeSignaling = { _ in socket }
            host.recoveryDelay = { _ in XCTFail("Terminal failures must not schedule recovery"); return .zero }
            await publish(host, service: service, capture: capture)
            socket.onClose(error)
            try await eventually { capture.stops == 1 }
            XCTAssertFalse(host.reconnecting); XCTAssertFalse(host.sharing)
            await host.stop()
        }
    }

    @MainActor func testInitialSocketFailureRetriesWithBoundedBackoff() async throws {
        let service = try service(), host = RemoteMacHost(), capture = RecoveryCapture()
        defer { service.close() }
        var sockets: [RecoverySocket] = [], attempts: [Int] = []
        XCTAssertEqual(host.recoveryDelay(0), .seconds(1))
        XCTAssertEqual(host.recoveryDelay(3), .seconds(8))
        XCTAssertEqual(host.recoveryDelay(20), .seconds(15))
        host.makeSignaling = { _ in
            let socket = RecoverySocket()
            if sockets.count < 2 { socket.connectError = URLError(.cannotConnectToHost) }
            sockets.append(socket); return socket
        }
        host.checkAuthorization = { _ in }
        host.recoveryDelay = { attempt in attempts.append(attempt); return .milliseconds(1) }
        await publish(host, service: service, capture: capture)
        try await eventually { host.sharing }
        XCTAssertEqual(attempts, [0, 1]); XCTAssertEqual(sockets.count, 3)
        XCTAssertEqual(capture.stops, 0)
        await host.stop()
    }

    @MainActor private func eventually(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Host recovery did not reach the expected state")
        throw RemoteError.unavailable
    }
}
#endif
