import SwiftUI
import InboxCore

/// Voice owns its own meter invalidations; the surrounding chat observes only
/// transcript changes through VoiceTranscriptFeed.
public struct NanocodexVoiceControl: View {
    @ObservedObject private var session: VoiceSession
    private let onStart: @MainActor () async throws -> VoiceConfiguration
    private let onReturnToChat: @MainActor () -> Void
    @State private var presented = false
    @State private var returningToChat = false
    @AppStorage("nanocodex.voice") private var selectedVoice = "cove"

    public init(session: VoiceSession, onReturnToChat: @escaping @MainActor () -> Void = {}, onStart: @escaping @MainActor () async throws -> VoiceConfiguration) {
        self.session = session; self.onStart = onStart; self.onReturnToChat = onReturnToChat
    }

    public var body: some View {
        HStack(spacing: 0) {
            Button {
                if !session.isEngaged { session.start(using: configuration) }
                presented = true
            } label: {
                Image(systemName: session.isEngaged ? "waveform.circle.fill" : "waveform")
                    .font(.system(size: 19, weight: .medium)).foregroundStyle(Color.primary)
                    .frame(width: controlSize, height: controlSize).contentShape(Circle())
            }.buttonStyle(.plain)
                .accessibilityLabel(session.isEngaged ? "Open voice in \(session.conversationTitle ?? "conversation")" : "Start voice")
                .accessibilityIdentifier("start-voice")
                .contextMenu {
                    Picker("Voice", selection: $selectedVoice) {
                        ForEach(ManagedVoiceProtocol.voices, id: \.self) { voice in
                            Text(voice.capitalized).tag(voice)
                        }
                    }
                }
            if session.isEngaged {
                Button { session.stop() } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .medium))
                        .frame(width: controlSize, height: controlSize).contentShape(Circle())
                }.buttonStyle(.plain).accessibilityLabel("End voice").accessibilityIdentifier("end-voice-compact")
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $presented, onDismiss: returnToChatIfNeeded) { panel }
        #else
        .sheet(isPresented: $presented, onDismiss: returnToChatIfNeeded) { panel }
        #endif
    }
    private var panel: some View {
        VoicePanel(session: session, selectedVoice: $selectedVoice, onStart: configuration) { returningToChat = true }
    }
    private func configuration() async throws -> VoiceConfiguration {
        var result = try await onStart()
        result.voice = ManagedVoiceProtocol.voices.contains(selectedVoice) ? selectedVoice : "cove"
        return result
    }
    private func returnToChatIfNeeded() {
        guard returningToChat else { return }
        returningToChat = false; onReturnToChat()
    }
    private var controlSize: CGFloat {
        #if os(iOS)
        44
        #else
        34
        #endif
    }
}

/// Place this directly among chat rows. It has no independent scroll view,
/// transcript box, composer, or audio-rate subscription.
public struct NanocodexVoiceTranscript: View {
    @ObservedObject private var feed: VoiceTranscriptFeed
    private let conversationID: String
    private let durableRows: [TranscriptRow]
    private let onUpdate: @MainActor () -> Void

    public init(session: VoiceSession, conversationID: String, durableRows: [TranscriptRow] = [], onUpdate: @escaping @MainActor () -> Void = {}) {
        self.feed = session.transcriptFeed; self.conversationID = conversationID
        self.durableRows = durableRows; self.onUpdate = onUpdate
    }
    public var body: some View {
        let transcripts = feed.conversations[conversationID] ?? []
        VStack(alignment: .leading, spacing: 18) {
            ForEach(transcripts) { transcript in
                HStack(alignment: .top, spacing: 0) {
                    if transcript.speaker == "user" { Spacer(minLength: 44) }
                    Text(transcript.text).font(.system(size: 17)).lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        .padding(transcript.speaker == "user" ? 16 : 0)
                        .background(transcript.speaker == "user" ? Color.primary.opacity(0.055) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 24))
                        .accessibilityIdentifier("voice-transcript-" + transcript.speaker)
                    if transcript.speaker != "user" { Spacer(minLength: 0) }
                }.frame(maxWidth: .infinity, alignment: transcript.speaker == "user" ? .trailing : .leading)
                    .id("voice-" + transcript.id.uuidString)
            }
        }
        .onAppear { feed.reconcile(conversationID: conversationID, durableRows: durableRows) }
        .onChange(of: durableRows) { _, rows in feed.reconcile(conversationID: conversationID, durableRows: rows) }
        .onChange(of: transcripts) { _, _ in onUpdate() }
    }
}

private struct VoicePanel: View {
    @ObservedObject var session: VoiceSession
    @Binding var selectedVoice: String
    let onStart: @MainActor () async throws -> VoiceConfiguration
    let onReturnToChat: @MainActor () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var background: Color { colorScheme == .dark ? Color(white: 0.075) : .white }
    private var loading: Bool { session.phase == .connecting || session.isReconnecting }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                background.ignoresSafeArea()
                Group {
                    if loading {
                        ProgressView().progressViewStyle(VoiceSpinnerStyle())
                            .accessibilityLabel(session.isReconnecting ? "Reconnecting voice" : "Connecting voice")
                            .accessibilityIdentifier("voice-connecting")
                    } else if session.phase == .active {
                        VoiceOrb(input: session.inputLevel, output: session.outputLevel, muted: session.isMuted)
                            .frame(width: min(230, geometry.size.width * 0.5), height: min(230, geometry.size.width * 0.5))
                            .accessibilityIdentifier("voice-orb")
                            .transition(.opacity.combined(with: .scale(scale: 0.88)))
                    } else {
                        VStack(spacing: 18) {
                            Image(systemName: "waveform").font(.system(size: 32)).foregroundStyle(.secondary)
                            if let error = session.errorMessage {
                                Text(error).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                                    .accessibilityIdentifier("voice-error")
                            }
                        }.padding(.horizontal, 36)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 40)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: loading)
                VStack {
                    HStack {
                        Button { returnToChat() } label: {
                            Image(systemName: "chevron.down").font(.system(size: 18, weight: .medium))
                                .frame(width: 48, height: 48).background(background, in: Circle())
                                .shadow(color: .black.opacity(0.05), radius: 16, y: 5)
                        }.buttonStyle(.plain).accessibilityLabel("Back to chat").accessibilityIdentifier("close-voice")
                        Spacer()
                        Text("Voice").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                            .accessibilityIdentifier("voice-panel")
                        Spacer()
                        Menu {
                            Picker("Voice for the next call", selection: $selectedVoice) {
                                ForEach(ManagedVoiceProtocol.voices, id: \.self) { voice in
                                    Text(voice.capitalized).tag(voice)
                                }
                            }
                        } label: {
                            Image(systemName: "slider.horizontal.3").frame(width: 48, height: 48)
                        }.accessibilityLabel("Choose voice").accessibilityIdentifier("choose-voice")
                    }.padding(.horizontal, 20).padding(.top, 8)
                    Spacer()
                    Text(session.status).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("voice-status").padding(.bottom, 18)
                    HStack(spacing: 12) {
                        Button { returnToChat() } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "text.bubble").font(.system(size: 19))
                                Text("Back to chat").font(.body)
                                Spacer(minLength: 0)
                            }.padding(.horizontal, 20).frame(height: 54)
                                .background(background, in: Capsule())
                        }.buttonStyle(.plain).accessibilityIdentifier("voice-return-chat")
                        if session.isEngaged {
                            Button { session.toggleMute() } label: {
                                Image(systemName: session.isMuted ? "mic.slash" : "mic")
                                    .font(.system(size: 23, weight: .medium)).frame(width: 54, height: 54)
                                    .background(background, in: Circle())
                            }.buttonStyle(.plain)
                                .accessibilityLabel(session.isMuted ? "Unmute microphone" : "Mute microphone")
                                .accessibilityIdentifier("mute-voice")
                            Button { session.stop(); returnToChat() } label: {
                                Image(systemName: "xmark").font(.system(size: 23, weight: .medium))
                                    .foregroundStyle(.white).frame(width: 54, height: 54)
                                    .background(Color(white: 0.12), in: Circle())
                            }.buttonStyle(.plain).accessibilityLabel("End voice").accessibilityIdentifier("end-voice")
                        } else {
                            Button { session.start(using: onStart) } label: {
                                Image(systemName: "waveform").font(.system(size: 22))
                                    .foregroundStyle(.white).frame(width: 54, height: 54)
                                    .background(Color(white: 0.12), in: Circle())
                            }.buttonStyle(.plain).accessibilityLabel("Retry voice").accessibilityIdentifier("retry-voice")
                        }
                    }.shadow(color: .black.opacity(colorScheme == .dark ? 0.2 : 0.065), radius: 20, y: 6)
                        .padding(.horizontal, 24).padding(.bottom, 16)
                }
            }
        }
        #if os(macOS)
        .frame(width: 480, height: 680)
        #endif
    }
    private func returnToChat() { onReturnToChat(); dismiss() }
}

private struct VoiceSpinnerStyle: ProgressViewStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            Circle().trim(from: 0.08, to: 0.88)
                .stroke(AngularGradient(colors: [.gray.opacity(0.02), .gray.opacity(0.55)], center: .center),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: 24, height: 24)
                .rotationEffect(.degrees(reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360))
        }
    }
}

/// An etched, iridescent sphere. Contours breathe with speech; rendering stays
/// in this small canvas and pauses when the voice surface is inactive.
private struct VoiceOrb: View {
    let input: Double
    let output: Double
    let muted: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    private var energy: Double { min(1, sqrt(max(output, muted ? 0 : input)) * 2.4) }
    private let violet = Color(red: 0.55, green: 0.39, blue: 0.83)
    private let copper = Color(red: 0.98, green: 0.64, blue: 0.40)
    private let pearl = Color(red: 0.94, green: 0.85, blue: 1)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || scenePhase != .active)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let bounds = CGRect(origin: .zero, size: size)
                let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
                let radius = min(size.width, size.height) * 0.46
                let sphere = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                let outline = Path(ellipseIn: sphere)
                let haloRadius = min(size.width, size.height) * 0.5
                let halo = CGRect(x: center.x - haloRadius, y: center.y - haloRadius,
                                  width: haloRadius * 2, height: haloRadius * 2)
                context.fill(Path(ellipseIn: halo), with: .radialGradient(
                    Gradient(colors: [violet.opacity(0.2), copper.opacity(0.08), .clear]),
                    center: center, startRadius: radius * 0.85, endRadius: haloRadius))
                context.clip(to: outline)
                context.fill(outline, with: .radialGradient(
                    Gradient(colors: [Color(red: 0.27, green: 0.16, blue: 0.40), Color(red: 0.075, green: 0.06, blue: 0.12)]),
                    center: CGPoint(x: size.width * 0.36, y: size.height * 0.3), startRadius: 0, endRadius: radius * 1.65))
                context.fill(outline, with: .radialGradient(
                    Gradient(colors: [copper.opacity(0.38), copper.opacity(0)]),
                    center: CGPoint(x: size.width * 0.85, y: size.height * 0.8), startRadius: 0, endRadius: radius * 1.25))

                // Nested, asymmetric contours give the sphere its own surface,
                // without a texture asset or animation outside the voice panel.
                for band in 0..<14 {
                    let depth = Double(band) / 13
                    let ringRadius = radius * (0.12 + depth * 0.94)
                    var contour = Path()
                    for step in 0...96 {
                        let angle = Double(step) / 96 * .pi * 2
                        let twist = time * 0.28 + depth * 3.4
                        let ripple = sin(angle * 3 + twist) * (0.024 + energy * 0.035)
                        let x = center.x + cos(angle) * ringRadius * (1 + ripple)
                        let y = center.y + sin(angle) * ringRadius * (0.84 + ripple)
                            + radius * (1 - depth) * 0.18 * cos(angle + twist)
                        let point = CGPoint(x: x, y: y)
                        if step == 0 { contour.move(to: point) } else { contour.addLine(to: point) }
                    }
                    contour.closeSubpath()
                    context.stroke(contour, with: .linearGradient(
                        Gradient(colors: [violet.opacity(0.45), pearl.opacity(0.92), copper.opacity(0.9), violet.opacity(0.32)]),
                        startPoint: CGPoint(x: 0, y: size.height * 0.15),
                        endPoint: CGPoint(x: size.width, y: size.height * 0.85)),
                        style: StrokeStyle(lineWidth: 0.8 + depth * 0.7, lineCap: .round, lineJoin: .round))
                }
                context.stroke(outline, with: .linearGradient(
                    Gradient(colors: [pearl.opacity(0.5), violet.opacity(0.05), copper.opacity(0.45)]),
                    startPoint: .zero, endPoint: CGPoint(x: bounds.maxX, y: bounds.maxY)), lineWidth: 0.8)
            }
            .scaleEffect(1 + energy * 0.05 + (reduceMotion ? 0 : sin(time * 0.7) * 0.006))
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: energy)
        .accessibilityElement(children: .ignore).accessibilityLabel(muted ? "Voice ready, microphone muted" : "Voice ready")
    }
}
