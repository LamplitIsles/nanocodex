import AppKit
import CoreAudio
import InboxCore
import NanocodexVoice
import SwiftUI
import XCTest
@testable import Nanocodex

final class VoiceTests: XCTestCase {
    @MainActor
    func testVoiceUsesRequestedPaneAndProjectsSavedConversation() async throws {
        let model = AppModel(runtimeDirectory: "/tmp/nanocodex-voice-contract")
        defer { model.shutdown() }
        model.runtime.requestOverride = { method, _ in
            if method == "connect" { return Self.connectedState }
            if method == "createThread" { return try .encoded(AgentThread(id: "created", title: "Voice", updatedAt: 0, turnCount: 0)) }
            if method == "openThread" { return Self.emptyThread("created") }
            return .null
        }
        try await model.connect(baseUrl: "https://service.invalid", key: "fixture-only", remember: false)
        model.tabs = [WorkspaceTab(id: "voice"), WorkspaceTab(id: "other", threadId: "other-agent", draft: "Keep this draft")]
        model.activeTabID = "other"
        _ = try await model.voiceConfiguration(tabID: "voice")
        XCTAssertEqual(model.tab("voice")?.threadId, "created")
        XCTAssertEqual(model.activeTabID, "other")
        XCTAssertEqual(model.tab("other")?.draft, "Keep this draft")
        model.messages["created"] = [.init(id: "saved", turnId: "turn", kind: .user, text: "<realtime_delegation><source>transcript_tail_flush</source><input>Internal handoff instruction</input><transcript_delta>user: Hello\nassistant: Hi there.</transcript_delta></realtime_delegation>")]
        XCTAssertEqual(model.displayedTranscript("voice").map(\.text), ["Hello", "Hi there."])
        XCTAssertEqual(model.displayedTranscript("voice").map(\.kind), [.user, .assistant])
        model.voice.startTranscriptPreview(agentID: "created")
        model.closeTab("other")
        XCTAssertTrue(model.voice.isEngaged)
        model.closeTab("voice")
        XCTAssertFalse(model.voice.isEngaged)
    }

    /// Actual native microphone/WebRTC/data-channel journey. Synthetic speech
    /// enters through the installed BlackHole device, never the physical mic.
    @MainActor
    func testNativeSpeechInterruptFollowUpAndStop() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["NANOCODEX_DESKTOP_VOICE_LIVE"] == "1" else { throw XCTSkip("Opt-in native voice service evidence") }
        let credential = try XCTUnwrap(AccountKeychain.environmentCredential())
        let input = try Self.defaultInput()
        let loopback = try Self.audioDevice(named: "BlackHole 2ch")
        try Self.setDefaultInput(loopback)
        defer { try? Self.setDefaultInput(input) }
        let client = ManagedClient(credential: try AccountCredential(origin: credential.baseUrl, apiKey: credential.apiKey))
        defer { client.close() }
        let agentID = try await client.create(requestID: UUID().uuidString)
        print("Native speech validation agent: \(agentID)")
        let model = AppModel(runtimeDirectory: "/tmp/nanocodex-native-speech-\(agentID)")
        defer { model.shutdown() }
        model.runtime.requestOverride = { method, _ in
            if method == "connect", case .object(var state) = Self.connectedState {
                state["baseUrl"] = .string(credential.baseUrl); return .object(state)
            }
            if method == "openThread" { return Self.emptyThread(agentID) }
            return .null
        }
        try await model.connect(baseUrl: credential.baseUrl, key: credential.apiKey, remember: false)
        model.tabs = [WorkspaceTab(id: "voice", threadId: agentID, title: "Native voice validation")]
        model.select("voice"); model.isStarting = false
        let evidence = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/evidence")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let host = NSHostingView(rootView: ContentView().environmentObject(model).frame(width: 1100, height: 800))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        var player: Process?
        defer { if player?.isRunning == true { player?.terminate() } }
        func play(_ path: String) throws {
            let process = Process(); process.executableURL = URL(fileURLWithPath: env["NANOCODEX_VOICE_SOX"] ?? "/opt/homebrew/bin/sox")
            process.arguments = ["-q", path, "-t", "coreaudio", "BlackHole 2ch"]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); player = process
        }
        func wait(_ condition: () -> Bool, seconds: Double = 25) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition(), Date() < deadline, model.voice.phase != .failed { try await Task.sleep(for: .milliseconds(40)) }
            guard condition() else { throw RuntimeFailure(message: model.voice.errorMessage ?? "Native speech evidence timed out") }
        }
        func deleteAgent() async throws {
            for attempt in 0..<5 {
                do { _ = try await client.json(path: "/v1/agents/\(agentID)", method: "DELETE"); return }
                catch APIError.http(503) where attempt < 4 { try await Task.sleep(for: .seconds(2)) }
            }
        }
        do {
            let began = Date()
            model.voice.start { try await model.voiceConfiguration(tabID: "voice") }
            try await wait({ model.voice.phase == .active }, seconds: 50)
            let startupMS = Date().timeIntervalSince(began) * 1000
            try play("/tmp/nanocodex-voice-count.wav")
            try await wait({ model.voice.outputLevel > 0.015 })
            try await Task.sleep(for: .milliseconds(1000))
            try await wait({ model.voice.outputLevel > 0.015 })
            let interruptedAt = Date()
            try play("/tmp/nanocodex-native-voice-interrupt.wav")
            try await wait({ model.voice.outputLevel < 0.004 }, seconds: 8)
            let quietMS = Date().timeIntervalSince(interruptedAt) * 1000
            try await wait({ model.voice.transcripts.contains { $0.speaker == "assistant" && ($0.text.lowercased().contains("thirteen") || $0.text.contains("13")) } })
            try await wait({ model.voice.outputLevel < 0.004 && player?.isRunning != true })
            try play("/tmp/nanocodex-native-voice-followup.wav")
            try await wait({ model.voice.transcripts.contains { $0.speaker == "assistant" && $0.text.lowercased().contains("blue") } })
            XCTAssertGreaterThan(model.voice.audioBytesSent, 0); XCTAssertGreaterThan(model.voice.audioBytesReceived, 0)
            XCTAssertFalse(model.voice.transcripts.contains { $0.text.contains("<realtime_") || $0.text.contains("<source>") })
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: image)
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: evidence.appendingPathComponent("native-voice-live.png"))
            let rows = model.voice.transcripts.map { ["speaker": $0.speaker, "text": $0.text] }
            try await wait({ player?.isRunning != true && model.voice.outputLevel < 0.004 })
            try play("/tmp/nanocodex-voice-count.wav")
            try await wait({ model.voice.outputLevel > 0.015 })
            let stoppedAt = Date(); model.voice.stop()
            let stopMS = Date().timeIntervalSince(stoppedAt) * 1000
            XCTAssertFalse(model.voice.isEngaged); XCTAssertEqual(model.voice.inputLevel, 0); XCTAssertEqual(model.voice.outputLevel, 0)
            await model.voice.finishStopping()
            if player?.isRunning == true { player?.terminate() }
            let restartedAt = Date()
            model.voice.start { try await model.voiceConfiguration(tabID: "voice") }
            try await wait({ model.voice.phase == .active }, seconds: 30)
            let restartMS = Date().timeIntervalSince(restartedAt) * 1000
            model.voice.stop(); await model.voice.finishStopping()
            try JSONSerialization.data(withJSONObject: ["startup_ms": startupMS, "restart_ms": restartMS, "first_quiet_after_interrupt_ms": quietMS, "stop_ms": stopMS, "transcripts": rows], options: [.prettyPrinted, .sortedKeys]).write(to: evidence.appendingPathComponent("native-voice-live.json"))
            print("Native speech PASS: startup \(Int(startupMS)) ms, restart \(Int(restartMS)) ms, quiet after interrupt \(Int(quietMS)) ms, stop \(Int(stopMS)) ms")
        } catch {
            model.voice.stop(); await model.voice.finishStopping()
            try? await deleteAgent(); throw error
        }
        try await deleteAgent()
    }

    private static var connectedState: JSONValue { .object(["connected": .bool(true), "baseUrl": .string("https://service.invalid"), "threads": .array([]), "hands": .array([]), "defaults": .object([:]), "platform": .string("darwin"), "version": .string("0.1.0"), "accountScope": .string("voice-evidence")]) }
    private static func emptyThread(_ id: String) -> JSONValue { .object(["id": .string(id), "events": .array([]), "hasMore": .bool(false), "connected": .bool(true), "activeTurns": .array([]), "settings": .object(["model": .string("gpt-5.4"), "thinking": .string("high"), "reasoning_mode": .string("standard"), "fast_mode": .bool(false)])]) }
    private static func defaultInput() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device: AudioDeviceID = 0; var size = UInt32(MemoryLayout.size(ofValue: device))
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { throw RuntimeFailure(message: "Cannot read audio input") }
        return device
    }
    private static func setDefaultInput(_ device: AudioDeviceID) throws {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = device
        guard AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout.size(ofValue: device)), &device) == noErr else { throw RuntimeFailure(message: "Cannot select audio input") }
    }
    private static func audioDevice(named name: String) throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices)
        for device in devices {
            var property = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var value: CFString = "" as CFString; var length = UInt32(MemoryLayout<CFString>.size)
            if AudioObjectGetPropertyData(device, &property, 0, nil, &length, &value) == noErr, value as String == name { return device }
        }
        throw XCTSkip("Install BlackHole 2ch for native synthetic speech evidence")
    }
}
