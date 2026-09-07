import Foundation
import CoreGraphics
import Combine
import WebRTC

struct RemoteControlMessage: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case acquire, granted, denied, renew, release, revoked }
    let type: Kind
    var generation: String?
}

// Hosts acknowledge release with `revoked`, including older hosts that omit a
// generation. Keep one exchange in flight so that acknowledgement cannot cancel
// a later explicit acquire. A host-initiated revocation never reacquires control.
struct RemoteViewerControl {
    private enum State { case idle, acquiring, cancelledAcquire, held(String), releasing(String) }
    private var state = State.idle
    private(set) var requested = false
    var generation: String? { if case .held(let value) = state { return value }; return nil }

    mutating func acquire() -> RemoteControlMessage? {
        requested = true
        guard case .idle = state else { return nil }
        state = .acquiring
        return .init(type: .acquire)
    }

    mutating func release() -> RemoteControlMessage? {
        requested = false
        switch state {
        case .acquiring: state = .cancelledAcquire
        case .held(let generation):
            state = .releasing(generation)
            return .init(type: .release, generation: generation)
        default: break
        }
        return nil
    }

    mutating func receive(_ message: RemoteControlMessage) throws -> RemoteControlMessage? {
        switch message.type {
        case .granted:
            guard let generation = message.generation, !generation.isEmpty, generation.count <= 128 else { throw RemoteError.invalidMessage }
            switch state {
            case .acquiring: state = .held(generation)
            case .cancelledAcquire:
                state = .releasing(generation)
                return .init(type: .release, generation: generation)
            default: throw RemoteError.invalidMessage
            }
        case .denied:
            switch state {
            case .acquiring: state = .idle; requested = false
            case .cancelledAcquire:
                state = .idle
                if requested { return acquire() }
            default: throw RemoteError.invalidMessage
            }
        case .revoked:
            if case .releasing(let generation) = state {
                guard message.generation == nil || message.generation == generation else { return nil }
                state = .idle
                if requested { return acquire() }
            } else {
                if let generation, let revoked = message.generation, revoked != generation { return nil }
                _ = release()
                if case .releasing = state { state = .idle }
            }
        default: throw RemoteError.invalidMessage
        }
        return nil
    }
}

@MainActor
public final class RemoteViewer: ObservableObject {
    @Published public private(set) var status = "Disconnected"
    @Published public private(set) var track: RTCVideoTrack?
    @Published public private(set) var frame: CGImage?
    @Published public private(set) var controlling = false
    @Published public private(set) var connected = false
    @Published public private(set) var hand: RemoteHand?
    @Published public private(set) var connecting = false
    private var service: RemoteService?
    private var suspended = false
    private var retries = 0
    private let recoveryWindow: Duration
    private var recoveryDeadline: ContinuousClock.Instant?
    private var lastFailure = ""
    private var retryTask: Task<Void, Never>?
    private var peer: RemotePeer?
    private var signaling: RemoteSignaling?
    private var control = RemoteViewerControl()
    private var generation: String? { control.generation }
    private var sequence: UInt64 = 0
    private var leaseRenewal: Task<Void, Never>?
    private var connectionDeadline: Task<Void, Never>?
    private var signalQueue: Task<Void, Never>?
    private var epoch = UUID()
    private var transportReady = false
    private var channelsReady = false
    private var frameTask: Task<Void, Never>?
    private var frameDeadline: Task<Void, Never>?
    private var framePending = false

    public init() { recoveryWindow = .seconds(90) }
    init(recoveryWindow: Duration) { self.recoveryWindow = recoveryWindow }
    var diagnosticState: String { peer?.diagnosticState ?? "no peer" }
    var diagnosticRecovery: String { "\(diagnosticState) ready=\(transportReady)/\(channelsReady) retries=\(retries) last=\(lastFailure)" }
    func diagnosticICE() async -> String { await peer?.diagnosticICE() ?? "no peer" }

    public func connect(service: RemoteService, hand: RemoteHand) async {
        close(); self.service = service; self.hand = hand
        await start(refresh: false)
    }

    /// Re-resolve the publication generation: a restarted VM keeps its machine
    /// and surface identity but must never reuse an expired signaling lease.
    public func reconnect() async {
        guard hand != nil, service != nil else { return }
        retries = 0; recoveryDeadline = nil; suspended = false
        await start(refresh: true)
    }

    public func suspend() {
        guard hand != nil else { return }
        suspended = true; detach(); status = "Paused"
    }

    public func resume() async {
        guard suspended else { return }
        await reconnect()
    }

    private func start(refresh: Bool) async {
        guard let service, let selected = hand, !suspended else { return }
        detach(); let attempt = epoch; connecting = true
        status = refresh ? "Reconnecting…" : "Connecting…"
        let clock = ContinuousClock()
        // Replace a stalled foreground reconnect sooner within the recovery
        // window, while allowing a cold connection more setup time.
        let timeout: Duration = refresh ? .seconds(10) : .seconds(25)
        let deadline = min(clock.now + timeout, recoveryDeadline ?? clock.now + timeout)
        connectionDeadline = Task { [weak self] in
            do { try await clock.sleep(until: deadline) } catch { return }
            guard let self, self.epoch == attempt, !self.connected else { return }
            self.fail(RemoteError.unavailable)
        }
        do {
            if refresh {
                let hands = try await service.list()
                guard epoch == attempt, !Task.isCancelled else { return }
                guard let current = hands.first(where: { $0.machineID == selected.machineID && $0.id == selected.id }) else {
                    throw RemoteError.unavailable
                }
                hand = current
            }
            if hand?.transport == .frames {
                try startFrames(service: service, attempt: attempt)
                return
            }
            let ice = try await service.ice()
            guard epoch == attempt, !Task.isCancelled, let hand else { return }
            let peer = try RemotePeer(publishing: false, ice: ice)
            let signaling = RemoteSignaling(service: service)
            self.peer = peer; self.signaling = signaling
            peer.onSignal = { [weak signaling] signal in signaling?.send(.init(type: "signal", signal: signal)) }
            peer.onVideoTrack = { [weak self] track in
                guard let self, epoch == attempt else { return }; self.track = track
            }
            peer.onState = { [weak self] state in
                guard let self, epoch == attempt else { return }
                if state == .connected { transportReady = true; updateReady() }
                if [.failed, .closed, .disconnected].contains(state) { fail(RemoteError.unavailable) }
            }
            peer.onChannelsReady = { [weak self] in
                guard let self, epoch == attempt else { return }; channelsReady = true; updateReady()
            }
            peer.onData = { [weak self] data, motion in
                guard let self, epoch == attempt, !motion else { return }; receiveControl(data)
            }
            signaling.onMessage = { [weak self, weak peer] message in
                guard let self, epoch == attempt, let signal = message.signal, let peer else { return }
                let preceding = signalQueue
                signalQueue = Task { [weak self] in
                    await preceding?.value
                    guard let self, epoch == attempt, !Task.isCancelled else { return }
                    do {
                        if signal.type == .offer {
                            let ice = try await service.ice()
                            guard epoch == attempt else { return }
                            try peer.updateICE(ice)
                        }
                        try await peer.receive(signal)
                    } catch { if epoch == attempt { fail(error) } }
                }
            }
            signaling.onClose = { [weak self] error in
                guard let self, epoch == attempt else { return }; fail(error ?? RemoteError.closed)
            }
            try signaling.connect(hand: hand)
        } catch { if epoch == attempt { fail(error) } }
    }

    public func takeControl() {
        guard connected, hand?.controllable == true, !control.requested, !controlling else { return }
        if let request = control.acquire() { sendControl(request) }
    }

    public func releaseControl() {
        let release = control.release()
        leaseRenewal?.cancel(); leaseRenewal = nil; controlling = false
        if let release { sendControl(release) }
        if connected { status = "Watching" }
    }

    public func input(kind: RemoteInput.Kind, x: Double? = nil, y: Double? = nil, button: Int? = nil,
                      down: Bool? = nil, key: UInt16? = nil, text: String? = nil, deltaX: Double? = nil, deltaY: Double? = nil) {
        guard controlling, let generation else { return }
        sequence += 1
        let event = RemoteInput(kind: kind, sequence: sequence, generation: generation, x: x, y: y,
            button: button, down: down, key: key, text: text, deltaX: deltaX, deltaY: deltaY)
        do {
            try event.validate()
            if hand?.transport == .frames {
                var message = RemoteMessage(type: "input"); message.data = .input(event); signaling?.send(message)
            } else { try peer?.send(JSONEncoder().encode(event), motion: kind == .move) }
        }
        catch { fail(error) }
    }

    public func close() {
        suspended = false; retries = 0; recoveryDeadline = nil; lastFailure = ""
        detach(); hand = nil; service = nil; status = "Disconnected"
    }

    private func detach() {
        epoch = UUID(); retryTask?.cancel(); retryTask = nil
        // Best effort release before closing transport; never replay control or
        // typed input when the next connection is established.
        if let generation {
            let release = RemoteControlMessage(type: .release, generation: generation)
            if hand?.transport == .frames {
                var relay = RemoteMessage(type: "control"); relay.data = .control(release)
                signaling?.send(relay)
            } else if let data = try? JSONEncoder().encode(release) { try? peer?.send(data) }
        }
        control = RemoteViewerControl(); controlling = false
        leaseRenewal?.cancel(); leaseRenewal = nil
        signalQueue?.cancel(); signalQueue = nil
        connectionDeadline?.cancel(); connectionDeadline = nil
        frameTask?.cancel(); frameTask = nil; frameDeadline?.cancel(); frameDeadline = nil; framePending = false; frame = nil
        let peer = self.peer, signaling = self.signaling
        self.peer = nil; self.signaling = nil; track = nil; connected = false; connecting = false
        transportReady = false; channelsReady = false
        peer?.onState = { _ in }; signaling?.onClose = { _ in }
        peer?.close(); signaling?.close()
    }

    private func fail(_ error: Error) {
        lastFailure = error.localizedDescription
        detach(); status = error.localizedDescription
        guard !suspended, hand != nil, service != nil,
              error as? RemoteError != .unauthorized, error as? RemoteError != .invalidMessage else { return }
        let clock = ContinuousClock()
        let deadline = recoveryDeadline ?? clock.now + recoveryWindow
        recoveryDeadline = deadline
        guard clock.now < deadline else { return }
        // A temporarily absent publication fails immediately. Three attempts
        // only covered seven seconds of VM downtime; bound recovery by elapsed
        // time so a slower restart can publish its new generation.
        let nextAttempt = min(clock.now + .seconds(1 << min(retries, 3)), deadline)
        retries += 1
        let attempt = epoch; connecting = true; status = "Reconnecting…"
        retryTask = Task { [weak self] in
            do { try await clock.sleep(until: nextAttempt) } catch { return }
            guard let self, epoch == attempt else { return }
            // start() cancels outstanding work, so relinquish this task first.
            retryTask = nil
            guard clock.now < deadline else { connecting = false; status = lastFailure; return }
            await start(refresh: true)
        }
    }
    private func updateReady() {
        if !connected && transportReady && channelsReady {
            connectionDeadline?.cancel(); retries = 0; recoveryDeadline = nil
            connecting = false; connected = true; status = "Watching"
        }
    }
    private func sendControl(_ message: RemoteControlMessage) {
        if hand?.transport == .frames {
            var relay = RemoteMessage(type: "control"); relay.data = .control(message); signaling?.send(relay); return
        }
        do { guard let peer else { return }; try peer.send(JSONEncoder().encode(message)) }
        catch { fail(error) }
    }

    private func startFrames(service: RemoteService, attempt: UUID) throws {
        let signaling = RemoteSignaling(service: service); self.signaling = signaling
        signaling.onMessage = { [weak self] message in
            guard let self, epoch == attempt else { return }
            do {
                switch message.type {
                case "ready": requestFrame(attempt: attempt)
                case "frame":
                    guard framePending else { throw RemoteError.invalidMessage }
                    frame = try RemoteFrame.decode(message); framePending = false
                    frameDeadline?.cancel(); frameDeadline = nil
                    transportReady = true; channelsReady = true; updateReady()
                    frameTask = Task { [weak self] in
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                        guard let self, epoch == attempt else { return }; requestFrame(attempt: attempt)
                    }
                case "control":
                    guard case .control(let control) = message.data else { throw RemoteError.invalidMessage }
                    receiveControl(try JSONEncoder().encode(control))
                case "renewed", "pong": break
                default: throw RemoteError.invalidMessage
                }
            } catch { fail(error) }
        }
        signaling.onClose = { [weak self] error in
            guard let self, epoch == attempt else { return }; fail(error ?? RemoteError.closed)
        }
        try signaling.connect(hand: hand)
    }

    private func requestFrame(attempt: UUID) {
        guard epoch == attempt, !framePending else { return }
        framePending = true
        signaling?.send(.init(type: "frame_request"))
        frameDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, epoch == attempt, framePending else { return }; fail(RemoteError.unavailable)
        }
    }
    private func receiveControl(_ data: Data) {
        guard let message = try? JSONDecoder().decode(RemoteControlMessage.self, from: data) else { fail(RemoteError.invalidMessage); return }
        do {
            let previous = generation
            let reply = try control.receive(message)
            controlling = generation != nil
            if let generation, generation != previous {
                sequence = 0; status = "You’re controlling"
                leaseRenewal?.cancel()
                leaseRenewal = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(3)) } catch { return }
                        guard let self, controlling, self.generation == generation else { return }
                        sendControl(.init(type: .renew, generation: generation))
                    }
                }
            } else if generation == nil {
                leaseRenewal?.cancel(); leaseRenewal = nil
                status = message.type == .denied && !control.requested ? "Another viewer is controlling this screen" : "Watching"
            }
            if let reply { sendControl(reply) }
        } catch { fail(error) }
    }
}

#if os(macOS)
@MainActor protocol RemoteInputInjector: AnyObject {
    func apply(_ event: RemoteInput) throws
    func releaseAll()
    var controlAllowed: Bool { get }
    func settled() async throws
}
extension RemoteInputInjector { func settled() async throws {} }
protocol RemoteCapture: AnyObject, Sendable {
    var onFailure: @Sendable (Error) -> Void { get set }
    @MainActor func stop() async
    func snapshot() throws -> RemoteSnapshot
}
extension RemoteCapture { func snapshot() throws -> RemoteSnapshot { throw RemoteError.unavailable } }
extension MacScreen: RemoteCapture {}
extension MacInput: RemoteInputInjector { var controlAllowed: Bool { CGPreflightPostEventAccess() } }

@MainActor protocol RemoteHostSignaling: AnyObject {
    var onMessage: (RemoteMessage) -> Void { get set }
    var onClose: (Error?) -> Void { get set }
    func connect(hand: RemoteHand?) throws
    func send(_ message: RemoteMessage)
    func close(error: Error?)
}
extension RemoteSignaling: RemoteHostSignaling {}

@MainActor
public final class RemoteMacHost: ObservableObject {
    var diagnosticStates: [String] { viewers.values.map { $0.peer.diagnosticState } }
    @Published public private(set) var status = "Not sharing"
    @Published public private(set) var sharing = false
    @Published public private(set) var reconnecting = false
    @Published public private(set) var viewerCount = 0
    @Published private(set) var surface: RemoteSurface?
    private struct Viewer { let peer: RemotePeer; var renewal: Task<Void, Never>? }
    private var viewers: [String: Viewer] = [:]
    private var preparations = Set<String>()
    private var signaling: (any RemoteHostSignaling)?
    private struct Publication {
        let service: RemoteService
        let machineID: String
        let name: String
        let surface: RemoteSurface
    }
    private var requestedPublication: Publication?
    private var recoveryTask: Task<Void, Never>?
    private var recoveryAttempts = 0
    private var captureEpoch = UUID()
    var makeSignaling: (RemoteService) -> any RemoteHostSignaling = { RemoteSignaling(service: $0) }
    var checkAuthorization: (RemoteService) async throws -> Void = { _ = try await $0.list() }
    var recoveryDelay: (Int) -> Duration = { .seconds(min(15, 1 << min($0, 4))) }
    private var input: (any RemoteInputInjector)?
    private var lease = RemoteControlLease()
    private var leaseTimer: Task<Void, Never>?
    private var signalQueue: Task<Void, Never>?
    private var epoch = UUID()
    private var capture: (any RemoteCapture)?
    private var captureSource: RTCVideoSource?
    private var publication: String?
    private var agentTask: Task<Void, Never>?
    private var agentRequestID: String?
    private var phoneBridge: PhoneBridge?
    // The broker issues one-hour credentials and caches them for ten minutes.
    // Renew well before the shortest remaining lifetime, including cache age.
    var iceRenewalInterval: Duration = .seconds(20 * 60)

    public init() {}

    public func start(service: RemoteService, machineID: String, name: String, surfaceID: String) async {
        let previous = detach(), attempt = epoch
        status = "Starting screen sharing…"
        for capture in previous { await capture.stop() }
        guard epoch == attempt else { return }
        do {
            let surfaces = try await MacScreen.surfaces()
            guard epoch == attempt else { return }
            guard let surface = surfaces.first(where: { $0.id == surfaceID }) else { throw RemoteError.unavailable }
            await publish(service: service, machineID: machineID, name: name, surface: surface, attempt: attempt) { source in
                let screen = MacScreen(source: source)
                let bounds = try await screen.start(surfaceID: surfaceID)
                do { return (screen, try MacInput(bounds: bounds, displayID: UInt32(surfaceID.dropFirst("display-".count)))) }
                catch { await screen.stop(); throw error }
            }
        } catch { if epoch == attempt { status = error.localizedDescription } }
    }

    public func startPhone(service: RemoteService, machineID: String, name: String, controlPort: Int = 18100, videoPort: Int = 19100,
                           bridge configuration: PhoneBridgeConfiguration? = nil) async {
        let previous = detach(), attempt = epoch
        status = "Starting iPhone sharing…"
        for capture in previous { await capture.stop() }
        guard epoch == attempt else { return }
        do {
            if let configuration {
                let bridge = PhoneBridge(executable: configuration.companionExecutable ?? PhoneBridge.bundledExecutable); phoneBridge = bridge
                bridge.onFailure = { [weak self] error in
                    Task { @MainActor in
                        guard let self, self.epoch == attempt else { return }
                        let captures = self.detach(), stopped = self.epoch
                        for capture in captures { await capture.stop() }
                        if self.epoch == stopped { self.status = error.localizedDescription }
                    }
                }
                try await bridge.start(configuration)
                guard epoch == attempt else { return }
            }
            let phone = try await PhoneInput.connect(port: controlPort)
            guard epoch == attempt else { return }
            let surface = RemoteSurface(id: "phone", name: "iPhone", kind: .phone, width: Int(phone.size.width), height: Int(phone.size.height), controllable: true, agentTools: true)
            await publish(service: service, machineID: machineID, name: name, surface: surface, attempt: attempt) { source in
                let screen = try PhoneScreen(source: source, port: videoPort, expectedSize: phone.size)
                try await screen.start()
                return (screen, phone)
            }
        } catch {
            if epoch == attempt {
                let captures = detach(), stopped = epoch
                for capture in captures { await capture.stop() }
                if epoch == stopped { status = error.localizedDescription }
            }
        }
    }

    func publish(service: RemoteService, machineID: String, name: String, surface: RemoteSurface, attempt requestedAttempt: UUID? = nil,
                         prepare: @escaping (RTCVideoSource) async throws -> (any RemoteCapture, any RemoteInputInjector)) async {
        let attempt = requestedAttempt ?? epoch
        guard epoch == attempt else { return }
        do {
            // One capture per shared surface, independent of viewer count.
            // Each peer owns its own track/encoder but consumes this same source.
            let source = RemotePeer.screenSource()
            let (screen, injector) = try await prepare(source)
            guard epoch == attempt else { await screen.stop(); return }
            capture = screen; captureSource = source; input = injector; self.surface = surface
            let capturedEpoch = captureEpoch
            screen.onFailure = { [weak self] error in
                Task { @MainActor in
                    guard let self, self.captureEpoch == capturedEpoch else { return }
                    let previous = self.detach(), stopped = self.epoch
                    for capture in previous { await capture.stop() }
                    if self.epoch == stopped { self.status = error.localizedDescription }
                }
            }
            if let phone = injector as? PhoneInput {
                let failure = screen.onFailure
                phone.onFailure = { failure($0) }
            }
            if surface.kind == .desktop {
                requestedPublication = Publication(service: service, machineID: machineID, name: name, surface: surface)
            }
            connectPublication(service: service, machineID: machineID, name: name, surface: surface, attempt: attempt)
        } catch {
            if epoch == attempt {
                let previous = detach(), stopped = epoch
                for capture in previous { await capture.stop() }
                if epoch == stopped { status = error.localizedDescription }
            }
        }
    }

    private func connectPublication(service: RemoteService, machineID: String, name: String,
                                    surface: RemoteSurface, attempt: UUID) {
        guard epoch == attempt else { return }
        let surfaceID = surface.id
        do {
            let signaling = makeSignaling(service); self.signaling = signaling
            signaling.onMessage = { [weak self, weak signaling] message in
                guard let self, epoch == attempt else { return }
                switch message.type {
                case "ready": signaling?.send(.init(type: "catalog", machineID: machineID, machineName: name, surfaces: [surface]))
                case "published": publication = message.generation; sharing = true; reconnecting = false; recoveryAttempts = 0; status = "Screen available"
                case "agent_call": handleAgent(message, attempt: attempt)
                case "agent_cancel":
                    if agentRequestID == message.requestID { agentTask?.cancel(); if lease.owner?.hasPrefix("agent:") == true { revokeControl() } }
                case "viewer":
                    guard let id = message.viewerID, message.surfaceID == surfaceID,
                          !preparations.contains(id), viewers[id] == nil else { return }
                    guard viewers.count + preparations.count < 4 else {
                        signaling?.send(.init(type: "close_viewer", viewerID: id)); return
                    }
                    preparations.insert(id)
                    Task { await self.addViewer(id: id, service: service, attempt: attempt) }
                case "viewer_left":
                    if let id = message.viewerID { preparations.remove(id); Task { await self.removeViewer(id, attempt: attempt) } }
                case "signal":
                    guard let id = message.viewerID, let signal = message.signal else { return }
                    let preceding = signalQueue
                    signalQueue = Task { [weak self] in
                        await preceding?.value
                        guard let self, epoch == attempt, let peer = viewers[id]?.peer else { return }
                        do { try await peer.receive(signal) } catch { await removeViewer(id, attempt: attempt) }
                    }
                default: break
                }
            }
            signaling.onClose = { [weak self] error in
                self?.signalingFailed(error ?? RemoteError.closed, attempt: attempt)
            }
            try signaling.connect(hand: nil)
            leaseTimer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let self, epoch == attempt else { return }
                    if lease.isExpired(now: ProcessInfo.processInfo.systemUptime) { revokeControl() }
                }
            }
        } catch { signalingFailed(error, attempt: attempt) }
    }

    private func signalingFailed(_ error: Error, attempt: UUID) {
        guard epoch == attempt else { return }
        if error is CancellationError || error is DecodingError || (error as? URLError)?.code == .cancelled {
            stopAfterFailure(error)
            return
        }
        if let remote = error as? RemoteError,
           ![.unavailable, .closed].contains(remote) {
            stopAfterFailure(error)
            return
        }
        guard let requested = requestedPublication, capture != nil else {
            stopAfterFailure(error)
            return
        }
        recoveryTask?.cancel(); recoveryTask = nil
        disconnectPublication()
        sharing = false; reconnecting = true; status = "Reconnecting screen sharing…"
        let attempt = epoch, delay = recoveryDelay(recoveryAttempts)
        recoveryAttempts += 1
        recoveryTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, epoch == attempt, !Task.isCancelled else { return }
            do {
                // Re-evaluate app-owned authentication on every attempt. In
                // particular, a failed WebSocket handshake must not hide 401/403.
                try await checkAuthorization(requested.service)
                guard epoch == attempt, !Task.isCancelled else { return }
                recoveryTask = nil
                connectPublication(service: requested.service, machineID: requested.machineID,
                    name: requested.name, surface: requested.surface, attempt: attempt)
            } catch {
                guard epoch == attempt, !Task.isCancelled else { return }
                recoveryTask = nil
                signalingFailed(error, attempt: attempt)
            }
        }
    }

    private func stopAfterFailure(_ error: Error) {
        let previous = detach(), stopped = epoch
        status = error.localizedDescription
        Task {
            for capture in previous { await capture.stop() }
            guard epoch == stopped else { return }
            status = error.localizedDescription
        }
    }

    private func addViewer(id: String, service: RemoteService, attempt: UUID) async {
        var connection: RemotePeer?
        do {
            // A host may share for days. New viewers must not inherit the
            // short-lived TURN credentials issued when sharing first started.
            let ice = try await service.ice()
            guard epoch == attempt, let source = captureSource, preparations.remove(id) != nil else { return }
            let peer = try RemotePeer(publishing: true, ice: ice, source: source); connection = peer
            viewers[id] = Viewer(peer: peer); viewerCount = viewers.count
            peer.onSignal = { [weak self, weak peer] signal in
                guard let self, let peer, epoch == attempt, viewers[id]?.peer === peer else { return }
                signaling?.send(.init(type: "signal", viewerID: id, signal: signal))
            }
            peer.onData = { [weak self, weak peer] data, motion in
                guard let self, let peer, epoch == attempt, viewers[id]?.peer === peer else { return }
                receive(data: data, motion: motion, viewerID: id)
            }
            peer.onState = { [weak self] state in
                if [.failed, .closed, .disconnected].contains(state) { Task { await self?.removeViewer(id, attempt: attempt) } }
            }
            try await peer.offer()
            guard epoch == attempt, viewers[id]?.peer === peer else { return }
            viewers[id]?.renewal = Task { [weak self, weak peer] in
                while !Task.isCancelled {
                    guard let self, let peer else { return }
                    do {
                        try await Task.sleep(for: iceRenewalInterval)
                        let ice = try await service.ice()
                        guard epoch == attempt, viewers[id]?.peer === peer, !Task.isCancelled else { return }
                        try await peer.restartICE(ice)
                    } catch {
                        if epoch == attempt, !Task.isCancelled { await removeViewer(id) }
                        return
                    }
                }
            }
        } catch {
            connection?.onState = { _ in }; connection?.close()
            guard epoch == attempt else { return }
            status = error.localizedDescription; preparations.remove(id)
            await removeViewer(id)
        }
    }

    private func receive(data: Data, motion: Bool, viewerID: String) {
        guard let peer = viewers[viewerID]?.peer else { return }
        let attempt = epoch
        let now = ProcessInfo.processInfo.systemUptime
        do {
            if let event = try? RemoteInput.decode(data) {
                guard (event.kind == .move) == motion else { throw RemoteError.invalidMessage }
                if try lease.accept(event, from: viewerID, now: now) { try input?.apply(event) }
                return
            }
            guard !motion else { throw RemoteError.invalidMessage }
            let message = try JSONDecoder().decode(RemoteControlMessage.self, from: data)
            switch message.type {
            case .acquire:
                guard input?.controlAllowed == true else { throw RemoteError.inputPermission }
                if lease.isExpired(now: now) || lease.owner?.hasPrefix("agent:") == true { revokeControl() }
                if lease.owner != nil { try peer.send(JSONEncoder().encode(RemoteControlMessage(type: .denied))); return }
                let generation = UUID().uuidString
                input?.releaseAll(); try lease.acquire(owner: viewerID, generation: generation, now: now)
                try peer.send(JSONEncoder().encode(RemoteControlMessage(type: .granted, generation: generation)))
            case .renew:
                guard let generation = message.generation else { throw RemoteError.invalidMessage }
                try lease.renew(owner: viewerID, generation: generation, now: now)
            case .release:
                guard lease.owner == viewerID, lease.generation == message.generation else { return }
                revokeControl()
            default: throw RemoteError.invalidMessage
            }
        } catch { Task { await removeViewer(viewerID, attempt: attempt) } }
    }

    public func revokeControl() {
        let owner = lease.owner; lease.release(); input?.releaseAll()
        if owner?.hasPrefix("agent:") == true { agentTask?.cancel() }
        if let owner, let peer = viewers[owner]?.peer {
            _ = try? peer.send(JSONEncoder().encode(RemoteControlMessage(type: .revoked)))
        }
    }

    private func removeViewer(_ id: String, attempt: UUID? = nil) async {
        guard attempt == nil || epoch == attempt else { return }
        preparations.remove(id)
        if lease.owner == id { revokeControl() }
        signaling?.send(.init(type: "close_viewer", viewerID: id))
        guard let viewer = viewers.removeValue(forKey: id) else { return }
        viewerCount = viewers.count; viewer.renewal?.cancel(); viewer.peer.onState = { _ in }; viewer.peer.close()
    }

    private func handleAgent(_ message: RemoteMessage, attempt: UUID) {
        guard let id = message.requestID, UUID(uuidString: id) != nil else { return }
        func reply(_ status: String) {
            var result = RemoteMessage(type: "agent_result"); result.requestID = id; result.agentStatus = status; signaling?.send(result)
        }
        guard let action = message.input, let agentID = message.agentID, !agentID.isEmpty, agentID.count <= 128,
              let deadline = message.deadlineAt, deadline > Date().timeIntervalSince1970 * 1000,
              deadline <= Date().timeIntervalSince1970 * 1000 + 10_000,
              message.surfaceID == surface?.id, message.generation == publication,
              let capture, let injector = input else { reply("invalid"); return }
        guard agentTask == nil else { reply("busy"); return }
        let owner = "agent:" + agentID
        if action.action == "release" {
            if lease.owner == owner { revokeControl() }
            reply("ok"); return
        }
        let generation = UUID().uuidString
        let steps: [(delay: Int, input: RemoteInput)]
        do {
            steps = try action.steps(generation: generation)
            if surface?.kind == .phone && ((action.action == "key" && (![40, 42, 74].contains(action.key ?? 0) || !(action.modifiers ?? []).isEmpty))
                || (action.action == "click" && (action.button ?? 0) > 1)) { throw RemoteError.invalidMessage }
            if !steps.isEmpty {
                guard injector.controlAllowed else { throw RemoteError.inputPermission }
                if lease.isExpired(now: ProcessInfo.processInfo.systemUptime) { revokeControl() }
                if lease.owner == owner { revokeControl() }
                guard lease.owner == nil else { reply("busy"); return }
                injector.releaseAll()
                try lease.acquire(owner: owner, generation: generation, now: ProcessInfo.processInfo.systemUptime)
            }
        } catch { reply("invalid"); return }
        agentRequestID = id
        agentTask = Task { [weak self] in
            guard let self else { return }
            defer { if agentRequestID == id { agentRequestID = nil; agentTask = nil } }
            var result = RemoteMessage(type: "agent_result"); result.requestID = id
            do {
                for step in steps {
                    if step.delay > 0 { try await Task.sleep(for: .milliseconds(step.delay)) }
                    try Task.checkCancellation()
                    guard epoch == attempt, Date().timeIntervalSince1970 * 1000 < deadline else { throw RemoteError.closed }
                    guard try lease.accept(step.input, from: owner, now: ProcessInfo.processInfo.systemUptime) else { throw RemoteError.busy }
                    try injector.apply(step.input)
                }
                if !steps.isEmpty { try await injector.settled(); try await Task.sleep(for: .milliseconds(100)) }
                try Task.checkCancellation()
                let snapshot = try await Task.detached { try capture.snapshot() }.value
                try Task.checkCancellation()
                guard epoch == attempt, Date().timeIntervalSince1970 * 1000 < deadline else { throw RemoteError.closed }
                result.agentStatus = "ok"; result.jpeg = snapshot.jpeg.base64EncodedString()
                result.width = snapshot.width; result.height = snapshot.height
            } catch {
                result.agentStatus = Task.isCancelled ? "cancelled" : (error as? RemoteError == .busy ? "busy" : "unavailable")
            }
            // Keys/buttons never remain pressed between agent calls. Ownership
            // lasts briefly between calls, and a human can preempt it immediately.
            if lease.owner == owner, lease.generation == generation { injector.releaseAll() }
            if epoch == attempt { signaling?.send(result) }
        }
    }

    public func stop() async {
        for capture in detach() { await capture.stop() }
    }

    // A signaling outage releases all control and fences old viewer callbacks,
    // while the selected Mac capture remains alive for the next publication.
    private func disconnectPublication() {
        epoch = UUID(); leaseTimer?.cancel(); signalQueue?.cancel(); preparations.removeAll()
        agentTask?.cancel(); agentTask = nil; agentRequestID = nil; publication = nil
        revokeControl()
        let signaling = self.signaling; self.signaling = nil; signaling?.onClose = { _ in }; signaling?.onMessage = { _ in }; signaling?.close(error: nil)
        let previous = Array(viewers.values); viewers.removeAll(); viewerCount = 0
        for viewer in previous { viewer.renewal?.cancel(); viewer.peer.onState = { _ in }; viewer.peer.close() }
    }

    private func detach() -> [any RemoteCapture] {
        // Clear intent before awaiting capture cleanup, so Stop or an account
        // change cannot be undone by a late authorization or capture completion.
        recoveryTask?.cancel(); recoveryTask = nil; recoveryAttempts = 0
        requestedPublication = nil; reconnecting = false; captureEpoch = UUID()
        disconnectPublication()
        input = nil; captureSource = nil; surface = nil; sharing = false; status = "Not sharing"
        var captures: [any RemoteCapture] = []
        if let capture { captures.append(capture) }; capture = nil
        if let phoneBridge { captures.append(phoneBridge) }
        phoneBridge = nil
        return captures
    }
}
#endif
