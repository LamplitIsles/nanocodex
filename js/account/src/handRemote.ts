export type RemoteHand = Readonly<{
  id: string; name: string; kind: "desktop" | "window" | "phone" | "vm";
  width: number; height: number; controllable: boolean;
  machine_id: string; machine_name: string; generation: string;
}>;
export type RemoteState = Readonly<{ status: string; connected: boolean; controlling: boolean }>;
export type RemoteInput = {
  kind: "move" | "button" | "scroll" | "key" | "text" | "releaseAll";
  x?: number; y?: number; button?: number; down?: boolean; key?: number; text?: string; deltaX?: number; deltaY?: number;
};

const encoder = new TextEncoder();
async function request(path: string, method = "GET", body?: unknown, signal?: AbortSignal): Promise<any> {
  const response = await fetch("/v1/account/hands" + path, {
    method, credentials: "same-origin", cache: "no-store", redirect: "error",
    signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(10_000)]) : AbortSignal.timeout(10_000),
    ...(body === undefined ? {} : { body: JSON.stringify(body), headers: { "content-type": "application/json" } }),
  });
  if (!response.ok) throw new Error([401, 403].includes(response.status) ? "This remote session is no longer authorized." : "This screen is unavailable.");
  return response.json();
}
export async function listRemoteHands(signal?: AbortSignal): Promise<readonly RemoteHand[]> {
  const value = await request("/screens", "GET", undefined, signal);
  if (!Array.isArray(value.surfaces) || value.surfaces.length > 512) throw new Error("Invalid screen catalog.");
  return value.surfaces;
}

/** Account cookies authorize signaling and short leases; media/input stay on WebRTC. */
export class RemoteBrowserSession {
  state: RemoteState = { status: "Connecting…", connected: false, controlling: false };
  private peer?: RTCPeerConnection;
  private socket?: WebSocket;
  private reliable?: RTCDataChannel;
  private motion?: RTCDataChannel;
  private sequence = 0;
  private generation?: string;
  private controlRequested = false;
  private candidates: RTCIceCandidateInit[] = [];
  private signalQueue = Promise.resolve();
  private abort = new AbortController();
  private watchdog?: ReturnType<typeof setTimeout>;
  private connectingTimer?: ReturnType<typeof setTimeout>;
  private renewTimer?: ReturnType<typeof setInterval>;
  private controlTimer?: ReturnType<typeof setInterval>;
  private closed = false;
  constructor(readonly hand: RemoteHand, private video: HTMLVideoElement, private changed: (state: RemoteState) => void) {}

  async connect(): Promise<void> {
    this.connectingTimer = setTimeout(() => this.close("Could not establish a screen connection. Reconnect to try again."), 25_000);
    try {
      const ice = await request("/ice", "POST", undefined, this.abort.signal);
      if (this.closed) return;
      const peer = new RTCPeerConnection({ iceServers: ice.iceServers, bundlePolicy: "max-bundle" });
      this.peer = peer;
      peer.onicecandidate = ({ candidate }) => { if (candidate) this.signal({ type: "candidate", candidate: candidate.candidate, sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex }); };
      peer.ontrack = ({ track }) => {
        this.video.srcObject = new MediaStream([track]);
        void this.video.play().catch(() => { if (!this.closed) this.update({ status: "Tap the picture to start video." }); });
      };
      peer.onconnectionstatechange = () => {
        if (import.meta.env.DEV) console.debug("Remote peer state", peer.connectionState, peer.iceConnectionState);
        if (["failed", "disconnected", "closed"].includes(peer.connectionState)) this.close("Screen disconnected. Reconnect to continue.");
        else this.ready();
      };
      peer.ondatachannel = ({ channel }) => this.channel(channel);
      const url = new URL("/v1/account/hands/view", location.origin);
      url.protocol = location.protocol === "https:" ? "wss:" : "ws:";
      url.search = new URLSearchParams({ machine_id: this.hand.machine_id, surface_id: this.hand.id, generation: this.hand.generation }).toString();
      const socket = new WebSocket(url); this.socket = socket;
      socket.onclose = () => this.close("Screen disconnected. Reconnect to continue.");
      socket.onerror = () => this.close("Could not connect to this screen.");
      socket.onmessage = ({ data }) => {
        this.signalQueue = this.signalQueue.then(async () => {
          if (this.closed) return;
          if (typeof data !== "string" || encoder.encode(data).length > 70_000) throw new Error("Invalid remote signal.");
          const message = JSON.parse(data);
          if (message.type === "ready") {
            if (this.renewTimer || typeof message.connection_id !== "string" || message.connection_id.length > 128) throw new Error("Invalid remote lease.");
            const id = message.connection_id;
            this.authorized();
            this.renewTimer = setInterval(() => {
              void request("/renew", "POST", { connection_id: id }, this.abort.signal).then(() => {
                if (socket.readyState === WebSocket.OPEN) socket.send('{"type":"ping"}');
              }).catch(error => this.close(error.message));
            }, 10_000);
          } else if (message.type === "renewed") this.authorized();
          else if (message.type === "signal") {
            const signal = message.signal;
            if (signal.type === "candidate") {
              if (this.candidates.length >= 128) throw new Error("Too many remote candidates.");
              if (peer.remoteDescription) await peer.addIceCandidate(signal);
              else this.candidates.push(signal);
            } else if (signal.type === "offer" && typeof signal.sdp === "string" && encoder.encode(signal.sdp).length <= 65_536) {
              if (import.meta.env.DEV) console.debug("Remote ICE negotiation", peer.remoteDescription ? "renewal" : "initial");
              // The host periodically restarts ICE before TURN credentials
              // expire. Answer using current credentials on this side too.
              const ice = await request("/ice", "POST", undefined, this.abort.signal);
              if (this.closed) return;
              peer.setConfiguration({ ...peer.getConfiguration(), iceServers: ice.iceServers });
              await peer.setRemoteDescription({ type: "offer", sdp: signal.sdp });
              for (const candidate of this.candidates.splice(0)) await peer.addIceCandidate(candidate);
              await peer.setLocalDescription(await peer.createAnswer());
              this.signal({ type: "answer", sdp: peer.localDescription!.sdp });
            } else throw new Error("Invalid remote offer.");
          }
        }).catch(error => this.close(error.message));
      };
      this.authorized();
    } catch (error) { if (!this.closed) this.close(error instanceof Error ? error.message : "Could not connect."); }
  }

  takeControl(): void {
    if (this.state.connected && this.hand.controllable && !this.state.controlling && !this.controlRequested) {
      this.controlRequested = true; this.send({ type: "acquire" });
    }
  }
  releaseControl(): void {
    this.controlRequested = false;
    const generation = this.generation; this.generation = undefined;
    clearInterval(this.controlTimer); this.controlTimer = undefined;
    if (generation && !this.closed) this.send({ type: "release", generation });
    if (!this.closed) this.update({ controlling: false, status: "Watching" });
  }
  input(event: RemoteInput): void {
    if (!this.state.controlling || !this.generation || this.closed) return;
    this.send({ ...event, sequence: ++this.sequence, generation: this.generation }, event.kind === "move");
  }
  close(status = "Disconnected"): void {
    if (this.closed) return;
    if (import.meta.env.DEV) console.debug("Remote session closed", status);
    this.releaseControl(); this.closed = true; this.abort.abort();
    clearTimeout(this.watchdog); clearTimeout(this.connectingTimer); clearInterval(this.renewTimer); clearInterval(this.controlTimer);
    if (this.socket) { this.socket.onclose = null; this.socket.onerror = null; this.socket.close(); }
    if (this.peer) { this.peer.onconnectionstatechange = null; this.peer.close(); }
    this.video.srcObject = null;
    this.update({ status, connected: false, controlling: false });
  }
  private authorized(): void {
    clearTimeout(this.watchdog);
    this.watchdog = setTimeout(() => this.close("This remote session is no longer authorized."), 25_000);
  }
  private signal(signal: unknown): void {
    if (this.closed) return;
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN || this.socket.bufferedAmount > 128_000) { this.close("Signaling connection unavailable."); return; }
    this.socket.send(JSON.stringify({ type: "signal", signal }));
  }
  private send(value: unknown, motion = false): void {
    const channel = motion ? this.motion : this.reliable;
    if (this.closed || !channel || channel.readyState !== "open") return;
    if (channel.bufferedAmount > (motion ? 4096 : 32_768)) { if (!motion) this.close("Connection too slow for control."); return; }
    const wire = JSON.stringify(value);
    if (encoder.encode(wire).length > 8192) { this.close("Input is too large."); return; }
    try { channel.send(wire); } catch { this.close("Input connection closed."); }
  }
  private channel(channel: RTCDataChannel): void {
    if (channel.label === "remote-control-v1" && !this.reliable && channel.ordered && channel.maxRetransmits === null && channel.maxPacketLifeTime === null) this.reliable = channel;
    else if (channel.label === "remote-motion-v1" && !this.motion && !channel.ordered && channel.maxRetransmits === 0 && channel.maxPacketLifeTime === null) this.motion = channel;
    else { channel.close(); this.close("Invalid remote input channel."); return; }
    channel.onopen = () => this.ready(); channel.onclose = () => this.close("Input connection closed.");
    channel.onmessage = ({ data }) => {
      try {
        if (channel !== this.reliable || typeof data !== "string" || encoder.encode(data).length > 8192) throw new Error();
        const value = JSON.parse(data);
        if (value.type === "granted" && typeof value.generation === "string" && value.generation.length > 0 && value.generation.length <= 128) {
          if (!this.controlRequested) { this.send({ type: "release", generation: value.generation }); return; }
          if (this.generation) throw new Error();
          this.generation = value.generation; this.sequence = 0; this.update({ controlling: true, status: "You’re controlling" });
          clearInterval(this.controlTimer);
          this.controlTimer = setInterval(() => this.send({ type: "renew", generation: this.generation }), 3000);
        } else if (value.type === "revoked") this.releaseControl();
        else if (value.type === "denied") { this.controlRequested = false; this.update({ status: "Another viewer is controlling this screen." }); }
        else throw new Error();
      } catch { this.close("Invalid remote control response."); }
    };
    this.ready();
  }
  private ready(): void {
    if (!this.closed && !this.state.connected && this.peer?.connectionState === "connected" && this.reliable?.readyState === "open" && this.motion?.readyState === "open") {
      clearTimeout(this.connectingTimer); this.update({ connected: true, status: "Watching" });
    }
  }
  private update(patch: Partial<RemoteState>): void { this.state = { ...this.state, ...patch }; this.changed(this.state); }
}

/** Physical keys use the same USB HID page as the native clients. */
export const remoteKeys: Readonly<Record<string, number>> = Object.freeze({
  ...Object.fromEntries(Array.from({ length: 26 }, (_, index) => ["Key" + String.fromCharCode(65 + index), 4 + index])),
  ...Object.fromEntries(Array.from({ length: 9 }, (_, index) => ["Digit" + (index + 1), 30 + index])),
  ...Object.fromEntries(Array.from({ length: 12 }, (_, index) => ["F" + (index + 1), 58 + index])),
  Digit0: 39, Enter: 40, Escape: 41, Backspace: 42, Tab: 43, Space: 44, Minus: 45, Equal: 46,
  BracketLeft: 47, BracketRight: 48, Backslash: 49, Semicolon: 51, Quote: 52, Backquote: 53,
  Comma: 54, Period: 55, Slash: 56, CapsLock: 57, Insert: 73, Home: 74, PageUp: 75, Delete: 76,
  End: 77, PageDown: 78, ArrowRight: 79, ArrowLeft: 80, ArrowDown: 81, ArrowUp: 82,
  ControlLeft: 224, ShiftLeft: 225, AltLeft: 226, MetaLeft: 227, ControlRight: 228, ShiftRight: 229, AltRight: 230, MetaRight: 231,
});
