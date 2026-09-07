import XCTest
import Combine
@testable import NanocodexRemote

private final class RemoteHTTPFixture: URLProtocol {
    static let lock = NSLock()
    static var handler: ((RemoteHTTPFixture) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "remote.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.lock.withLock { Self.handler }?(self) }
    override func stopLoading() {}
    func respond(_ status: Int, _ value: [String: Any] = [:]) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: value))
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class RemoteViewerTests: XCTestCase {
    @MainActor func testCanvasTeardownDoesNotPublishDuringSwiftUIInvalidation() {
        let viewer = RemoteViewer()
#if os(macOS)
        let canvas = MacRemoteCanvas(viewer: viewer)
#else
        let canvas = TouchRemoteCanvas(viewer: viewer)
#endif
        var changes = 0
        let observer = viewer.objectWillChange.sink { changes += 1 }
        canvas.detach()
        XCTAssertEqual(changes, 0)
        withExtendedLifetime(observer) {}
    }

    override func tearDown() {
        RemoteHTTPFixture.lock.withLock { RemoteHTTPFixture.handler = nil }
        super.tearDown()
    }

    private func surface(_ generation: String, machine: String = "vm:test") -> [String: Any] {
        ["id": "desktop", "machine_id": machine, "machine_name": "Test VM", "name": "Desktop",
         "kind": "vm", "width": 1600, "height": 900, "controllable": true, "generation": generation]
    }

    private func hand(_ generation: String, machine: String = "vm:test") throws -> RemoteHand {
        try JSONDecoder().decode(RemoteHand.self, from: JSONSerialization.data(withJSONObject: surface(generation, machine: machine)))
    }

    private func service(_ handler: @escaping (RemoteHTTPFixture) -> Void) throws -> RemoteService {
        RemoteHTTPFixture.lock.withLock { RemoteHTTPFixture.handler = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteHTTPFixture.self]
        return try RemoteService(origin: URL(string: "https://remote.test")!, configuration: configuration) {
            $0.setValue("Bearer fixture", forHTTPHeaderField: "Authorization")
        }
    }

    @MainActor func testBackgroundResumeKeepsSelectionAndRefreshesPublication() async throws {
        let catalog = surface("restarted")
        let service = try service { request in
            if request.request.url?.path.hasSuffix("/screens") == true { request.respond(200, ["surfaces": [catalog]]) }
            else { request.respond(401) }
        }
        let viewer = RemoteViewer()
        defer { viewer.close(); service.close() }
        await viewer.connect(service: service, hand: try hand("original"))
        XCTAssertEqual(viewer.status, RemoteError.unauthorized.localizedDescription)
        XCTAssertFalse(viewer.connecting, "Authorization failures must not keep retrying")
        viewer.suspend()
        XCTAssertEqual(viewer.hand?.generation, "original")
        XCTAssertEqual(viewer.status, "Paused")
        await viewer.resume()
        XCTAssertEqual(viewer.hand?.generation, "restarted")
        XCTAssertFalse(viewer.controlling, "Resuming must require a new explicit control acquisition")
        XCTAssertFalse(viewer.connected)
        viewer.close()
        await viewer.resume()
        await viewer.reconnect()
        XCTAssertNil(viewer.hand)
        XCTAssertEqual(viewer.status, "Disconnected")
    }

    @MainActor func testCloseFencesAnOutstandingConnection() async throws {
        let started = expectation(description: "ICE request started")
        let lock = NSLock()
        var pending: RemoteHTTPFixture?
        let service = try service { request in lock.withLock { pending = request }; started.fulfill() }
        let viewer = RemoteViewer()
        defer { viewer.close(); service.close() }
        let hand = try hand("original")
        let connection = Task { await viewer.connect(service: service, hand: hand) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(viewer.connecting)
        viewer.close()
        lock.withLock { pending }?.respond(200, ["iceServers": []])
        await connection.value
        XCTAssertNil(viewer.hand)
        XCTAssertNil(viewer.track)
        XCTAssertFalse(viewer.connected)
        XCTAssertFalse(viewer.connecting)
        XCTAssertEqual(viewer.diagnosticState, "no peer")
        XCTAssertEqual(viewer.status, "Disconnected")
    }

    @MainActor func testTransientFailureRetriesTheSameScreenWithFreshGeneration() async throws {
        let retried = expectation(description: "Retry resolved the current publication")
        let catalog = surface("fresh")
        let other = surface("other", machine: "vm:unrelated")
        let lock = NSLock()
        var iceRequests = 0
        let service = try service { request in
            if request.request.url?.path.hasSuffix("/screens") == true {
                request.respond(200, ["surfaces": [other, catalog]])
            } else {
                let count = lock.withLock { iceRequests += 1; return iceRequests }
                request.respond(count == 1 ? 503 : 401)
                if count == 2 { retried.fulfill() }
            }
        }
        let viewer = RemoteViewer()
        defer { viewer.close(); service.close() }
        await viewer.connect(service: service, hand: try hand("original"))
        XCTAssertTrue(viewer.connecting)
        XCTAssertEqual(viewer.hand?.machineID, "vm:test")
        await fulfillment(of: [retried], timeout: 3)
        XCTAssertEqual(viewer.hand?.generation, "fresh")
        XCTAssertEqual(viewer.hand?.machineID, "vm:test")
        XCTAssertFalse(viewer.controlling)
    }

    @MainActor func testSuspendingPreventsScheduledRetries() async throws {
        let unexpected = expectation(description: "No background reconnect")
        unexpected.isInverted = true
        let service = try service { request in
            if request.request.url?.path.hasSuffix("/screens") == true { unexpected.fulfill() }
            request.respond(503)
        }
        let viewer = RemoteViewer()
        defer { viewer.close(); service.close() }
        await viewer.connect(service: service, hand: try hand("original"))
        viewer.suspend()
        await fulfillment(of: [unexpected], timeout: 1.2)
        XCTAssertEqual(viewer.status, "Paused")
        XCTAssertFalse(viewer.connecting)
        XCTAssertNotNil(viewer.hand)
    }

    @MainActor func testRecoveryWaitsForASlowerVMRestart() async throws {
        let recovered = expectation(description: "Fourth catalog retry finds the restarted VM")
        let catalog = surface("after-restart")
        let lock = NSLock()
        var listings = 0
        var iceRequests = 0
        let service = try service { request in
            if request.request.url?.path.hasSuffix("/screens") == true {
                let count = lock.withLock { listings += 1; return listings }
                request.respond(200, ["surfaces": count < 4 ? [] : [catalog]])
            } else {
                let count = lock.withLock { iceRequests += 1; return iceRequests }
                request.respond(count == 1 ? 503 : 401)
                if count == 2 { recovered.fulfill() }
            }
        }
        let viewer = RemoteViewer()
        defer { viewer.close(); service.close() }
        await viewer.connect(service: service, hand: try hand("before-restart"))
        await fulfillment(of: [recovered], timeout: 20)
        XCTAssertEqual(viewer.hand?.generation, "after-restart")
        XCTAssertFalse(viewer.controlling)
    }

    @MainActor func testRecoveryDeadlineStopsRetryingWithoutLosingSelection() async throws {
        let unexpected = expectation(description: "No request after the recovery deadline")
        unexpected.isInverted = true
        let service = try service { request in
            if request.request.url?.path.hasSuffix("/screens") == true { unexpected.fulfill() }
            request.respond(503)
        }
        let viewer = RemoteViewer(recoveryWindow: .milliseconds(100))
        defer { viewer.close(); service.close() }
        await viewer.connect(service: service, hand: try hand("original"))
        await fulfillment(of: [unexpected], timeout: 0.3)
        XCTAssertFalse(viewer.connecting)
        XCTAssertEqual(viewer.hand?.generation, "original")
        XCTAssertEqual(viewer.status, RemoteError.unavailable.localizedDescription)
    }
}
