#if os(macOS)
import XCTest
import WebRTC
@testable import NanocodexRemote

final class AccountVMTests: XCTestCase {
    // Requires an explicitly selected disposable VM with an idle, focused foot
    // terminal. Measures decoded pixels after real input, not a signaling ack.
    @MainActor func testVMInputToVisibleFrame() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["NANOCODEX_TEST_REMOTE_ENV"],
              let machine = environment["NANOCODEX_TEST_VM_MACHINE_ID"] else {
            throw XCTSkip("Requires the isolated factory VM and its focused test terminal")
        }
        var values: [String: String] = [:]
        for line in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") {
            guard let split = line.firstIndex(of: "=") else { continue }
            values[String(line[..<split])] = String(line[line.index(after: split)...])
        }
        let origin = try XCTUnwrap(URL(string: try XCTUnwrap(values["NANOCODEX_MANAGED_URL"])))
        guard ["127.0.0.1", "localhost"].contains(origin.host ?? ""), machine.hasPrefix("vm:") else {
            throw XCTSkip("This journey only uses the explicitly selected local test VM")
        }
        let token = try XCTUnwrap(values["NANOCODEX_API_KEY"])
        let service = try RemoteService(origin: origin) { $0.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let viewer = RemoteViewer()
        defer { viewer.close(); service.close() }
        let hands = try await service.list()
        let hand = try XCTUnwrap(hands.first { $0.machineID == machine && $0.kind == .vm })
        await viewer.connect(service: service, hand: hand)
        try await eventually { viewer.connected && viewer.track != nil }
        let track = try XCTUnwrap(viewer.track), transition = ScreenTransition()
        track.add(transition); defer { track.remove(transition) }
        viewer.takeControl(); try await eventually { viewer.controlling }
        try await eventually { transition.stable }
        for escape in ["47m", "0m"] {
            viewer.input(kind: .text, text: "printf '\\033[" + escape + "\\033[2J\\033[H'")
            try await Task.sleep(for: .milliseconds(150))
            try await eventually { transition.stable }
            transition.arm()
            for down in [true, false] { viewer.input(kind: .key, down: down, key: 40) }
            try await eventually { transition.milliseconds != nil }
            print("Local VM input to first visible transition: \(Int(transition.milliseconds!)) ms")
            try await eventually { transition.stable }
        }
        viewer.releaseControl()
        XCTAssertFalse(viewer.controlling)
    }

    @MainActor private func eventually(_ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while ProcessInfo.processInfo.systemUptime < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The VM did not reach the expected decoded video or input state")
        throw RemoteError.unavailable
    }
}
#endif
