import Foundation
import Combine
import WebRTC

struct RemoteControlMessage: Codable {
    enum Kind: String, Codable { case acquire, granted, denied, renew, release, revoked }
    let type: Kind
    var generation: String?
}

@MainActor
public final class RemoteViewer: ObservableObject {
    @Published public private(set) var status = "Disconnected"
    @Published public private(set) var track: RTCVideoTrack?
    @Published public private(set) var controlling = false
    @Published public private(set) var connected = false
    public private(set) var hand: RemoteHand?
    private var peer: RemotePeer?
    private var signaling: RemoteSignaling?
    private var generation: String?
    private var controlRequested = false
    private var sequence: UInt64 = 0
    private var leaseRenewal: Task<Void, Never>?
    private var connectionDeadline: Task<Void, Never>?
    private var signalQueue: Task<Void, Never>?
    private var epoch = UUID()
    private var transportReady = false
    private var channelsReady = false

    public init() {}
    var diagnosticState: String { peer?.diagnosticState ?? "no peer" }
    func diagnosticICE() async -> String { await peer?.diagnosticICE() ?? "no peer" }

    public func connect(service: RemoteService, hand: RemoteHand) async {
        close(); let attempt = UUID(); epoch = attempt; self.hand = hand; status = "Connecting…"
        connectionDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            guard let self, self.epoch == attempt, !self.connected else { return }
            self.fail(RemoteError.unavailable)
        }
        do {
            let ice = try await service.ice()
            guard epoch == attempt else { return }
            let peer = try RemotePeer(publishing: false, ice: ice)
            let signaling = RemoteSignaling(service: service)
            self.peer = peer; self.signaling = signaling
            peer.onSignal = { [weak signaling] signal in signaling?.send(.init(type: "signal", signal: signal)) }
            peer.onVideoTrack = { [weak self] track in self?.track = track }
            peer.onState = { [weak self] state in
                guard let self else { return }
                if state == .connected { transportReady = true; updateReady() }
                if [.failed, .closed, .disconnected].contains(state) { fail(RemoteError.unavailable) }
            }
            peer.onChannelsReady = { [weak self] in self?.channelsReady = true; self?.updateReady() }
            peer.onData = { [weak self] data, motion in if !motion { self?.receiveControl(data) } }
            signaling.onMessage = { [weak self, weak peer] message in
                guard let self, let signal = message.signal, let peer else { return }
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
            signaling.onClose = { [weak self] error in self?.fail(error ?? RemoteError.closed) }
            try signaling.connect(hand: hand)
        } catch { if epoch == attempt { fail(error) } }
    }

    public func takeControl() {
        guard connected, hand?.controllable == true, !controlRequested, !controlling else { return }
        controlRequested = true
        sendControl(.init(type: .acquire))
    }

    public func releaseControl() {
        controlRequested = false
        let previous = generation
        leaseRenewal?.cancel(); leaseRenewal = nil; generation = nil; controlling = false
        if let previous { sendControl(.init(type: .release, generation: previous)) }
        if connected { status = "Watching" }
    }

    public func input(kind: RemoteInput.Kind, x: Double? = nil, y: Double? = nil, button: Int? = nil,
                      down: Bool? = nil, key: UInt16? = nil, text: String? = nil, deltaX: Double? = nil, deltaY: Double? = nil) {
        guard controlling, let generation, let peer else { return }
        sequence += 1
        let event = RemoteInput(kind: kind, sequence: sequence, generation: generation, x: x, y: y,
            button: button, down: down, key: key, text: text, deltaX: deltaX, deltaY: deltaY)
        do { try event.validate(); try peer.send(JSONEncoder().encode(event), motion: kind == .move) }
        catch { fail(error) }
    }

    public func close() {
        epoch = UUID(); releaseControl(); signalQueue?.cancel(); signalQueue = nil
        connectionDeadline?.cancel(); connectionDeadline = nil
        let peer = self.peer, signaling = self.signaling
        self.peer = nil; self.signaling = nil; track = nil; hand = nil; connected = false; status = "Disconnected"
        transportReady = false; channelsReady = false
        peer?.onState = { _ in }; signaling?.onClose = { _ in }
        peer?.close(); signaling?.close()
    }

    private func fail(_ error: Error) { close(); status = error.localizedDescription }
    private func updateReady() {
        if !connected && transportReady && channelsReady { connectionDeadline?.cancel(); connected = true; status = "Watching" }
    }
    private func sendControl(_ message: RemoteControlMessage) {
        do { guard let peer else { return }; try peer.send(JSONEncoder().encode(message)) }
        catch { fail(error) }
    }
    private func receiveControl(_ data: Data) {
        guard let message = try? JSONDecoder().decode(RemoteControlMessage.self, from: data) else { fail(RemoteError.invalidMessage); return }
        switch message.type {
        case .granted:
            guard let generation = message.generation, !generation.isEmpty, generation.count <= 128 else { fail(RemoteError.invalidMessage); return }
            guard controlRequested else { sendControl(.init(type: .release, generation: generation)); return }
            guard self.generation == nil else { fail(RemoteError.invalidMessage); return }
            self.generation = generation; sequence = 0; controlling = true; status = "You’re controlling"
            leaseRenewal?.cancel()
            leaseRenewal = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    guard let self, controlling, self.generation == generation else { return }
                    sendControl(.init(type: .renew, generation: generation))
                }
            }
        case .denied: controlRequested = false; status = "Another viewer is controlling this screen"
        case .revoked: releaseControl()
        default: fail(RemoteError.invalidMessage)
        }
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

@MainActor
public final class RemoteMacHost: ObservableObject {
    var diagnosticStates: [String] { viewers.values.map { $0.peer.diagnosticState } }
    @Published public private(set) var status = "Not sharing"
    @Published public private(set) var sharing = false
    @Published public private(set) var viewerCount = 0
    @Published private(set) var surface: RemoteSurface?
    private struct Viewer { let peer: RemotePeer; var renewal: Task<Void, Never>? }
    private var viewers: [String: Viewer] = [:]
    private var preparations = Set<String>()
    private var signaling: RemoteSignaling?
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

    private func publish(service: RemoteService, machineID: String, name: String, surface: RemoteSurface, attempt: UUID,
                         prepare: @escaping (RTCVideoSource) async throws -> (any RemoteCapture, any RemoteInputInjector)) async {
        guard epoch == attempt else { return }
        let surfaceID = surface.id
        do {
            // One capture per shared surface, independent of viewer count.
            // Each peer owns its own track/encoder but consumes this same source.
            let source = RemotePeer.screenSource()
            let (screen, injector) = try await prepare(source)
            guard epoch == attempt else { await screen.stop(); return }
            capture = screen; captureSource = source; input = injector; self.surface = surface
            screen.onFailure = { [weak self] error in
                Task { @MainActor in
                    guard let self, self.epoch == attempt else { return }
                    let previous = self.detach(), stopped = self.epoch
                    for capture in previous { await capture.stop() }
                    if self.epoch == stopped { self.status = error.localizedDescription }
                }
            }
            if let phone = injector as? PhoneInput {
                let failure = screen.onFailure
                phone.onFailure = { failure($0) }
            }
            let signaling = RemoteSignaling(service: service); self.signaling = signaling
            signaling.onMessage = { [weak self, weak signaling] message in
                guard let self, epoch == attempt else { return }
                switch message.type {
                case "ready": signaling?.send(.init(type: "catalog", machineID: machineID, machineName: name, surfaces: [surface]))
                case "published": publication = message.generation; sharing = true; status = "Screen available"
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
                    if let id = message.viewerID { preparations.remove(id); Task { await self.removeViewer(id) } }
                case "signal":
                    guard let id = message.viewerID, let signal = message.signal else { return }
                    let preceding = signalQueue
                    signalQueue = Task { [weak self] in
                        await preceding?.value
                        guard let self, epoch == attempt, let peer = viewers[id]?.peer else { return }
                        do { try await peer.receive(signal) } catch { await removeViewer(id) }
                    }
                default: break
                }
            }
            signaling.onClose = { [weak self] error in
                guard let self else { return }
                Task {
                    guard self.epoch == attempt else { return }
                    let previous = self.detach(), stopped = self.epoch
                    for capture in previous { await capture.stop() }
                    if self.epoch == stopped { self.status = error?.localizedDescription ?? "Screen sharing stopped" }
                }
            }
            try signaling.connect()
            leaseTimer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let self else { return }
                    if lease.isExpired(now: ProcessInfo.processInfo.systemUptime) { revokeControl() }
                }
            }
        } catch {
            if epoch == attempt {
                let previous = detach(), stopped = epoch
                for capture in previous { await capture.stop() }
                if epoch == stopped { status = error.localizedDescription }
            }
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
            peer.onSignal = { [weak self] signal in self?.signaling?.send(.init(type: "signal", viewerID: id, signal: signal)) }
            peer.onData = { [weak self] data, motion in self?.receive(data: data, motion: motion, viewerID: id) }
            peer.onState = { [weak self] state in
                if [.failed, .closed, .disconnected].contains(state) { Task { await self?.removeViewer(id) } }
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
        } catch { Task { await removeViewer(viewerID) } }
    }

    public func revokeControl() {
        let owner = lease.owner; lease.release(); input?.releaseAll()
        if owner?.hasPrefix("agent:") == true { agentTask?.cancel() }
        if let owner, let peer = viewers[owner]?.peer {
            _ = try? peer.send(JSONEncoder().encode(RemoteControlMessage(type: .revoked)))
        }
    }

    private func removeViewer(_ id: String) async {
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

    // Detach synchronously before awaiting capture cleanup. An old shutdown
    // cannot clear a newer sharing session that starts while cleanup suspends.
    private func detach() -> [any RemoteCapture] {
        epoch = UUID(); leaseTimer?.cancel(); signalQueue?.cancel(); preparations.removeAll()
        agentTask?.cancel(); agentTask = nil; agentRequestID = nil; publication = nil
        revokeControl()
        let signaling = self.signaling; self.signaling = nil; signaling?.onClose = { _ in }; signaling?.close()
        let previous = Array(viewers.values); viewers.removeAll(); viewerCount = 0
        for viewer in previous { viewer.renewal?.cancel(); viewer.peer.onState = { _ in }; viewer.peer.close() }
        input = nil; captureSource = nil; surface = nil; sharing = false; status = "Not sharing"
        var captures: [any RemoteCapture] = []
        if let capture { captures.append(capture) }; capture = nil
        if let phoneBridge { captures.append(phoneBridge) }
        phoneBridge = nil
        return captures
    }
}
#endif
