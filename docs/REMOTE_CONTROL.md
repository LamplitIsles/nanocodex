# Interactive Hands

Work in progress on `feat/apple-remote-control`. The scope is interactive macOS,
paired iPhone, and factory-spawned Nanocodex VM Hands, accessible from the native
Apple clients and the account browser. No production deployment has been made.

## Transport and ownership

Use WebRTC video and data channels. VNC is not required. Wayland is the Linux
compositor/input backend; it does not replace the network transport.

- `apple/NanocodexRemote` owns native WebRTC, ScreenCaptureKit capture, Quartz
  input, paired-phone capture/input, and the sharing UI. Apple apps consume this
  package without importing one another's source. One capture source serves all
  viewers of a surface; each peer owns its own track and encoder.
- `hands/remote` is the Go companion. On Linux it bridges Waymote capture/input to
  Pion WebRTC. On macOS it owns a paired-device tunnel and signed Xcode runner.
- The managed Worker and existing account Durable Object own account
  authorization, discovery, signaling, and short-lived Cloudflare TURN
  credentials. Video/input use the direct peer connection, with TURN as the
  optional relay. There is no SFU. Live video stays off the agent transcript;
  an agent's requested screenshots return through the normal tool-result path.
- Discrete input uses an ordered reliable channel. Absolute motion uses an
  unordered channel without retransmits. Clicks carry their own coordinates and
  fence older motion. Control is exclusive, expires after ten seconds without
  renewal, and releases keys/buttons on disconnect, focus loss, or revocation.
- Signaling is fenced to the account, host connection generation, and surface.
  A live socket cannot renew authorization itself: the client makes a freshly
  authenticated HTTP request. Existing Connect grants do not grant screen access.

## Agent control and human takeover

Each published surface advertises an account-owned `screen_*` tool through the
existing Hand registry. An agent discovers it with `tool_search`, observes the
screen, and sends click, text, key, scroll, or drag actions. Code Mode callers
use `image(result)` to display returned screenshots. Coordinates are normalized
across the whole image; keyboard actions use USB HID usages and optional
modifiers. An observation is bounded to 1280 pixels on its longest edge.

Agent and human input share the same host control lease and input backend.
Taking control in a viewer cancels pending agent input and releases held keys
and buttons. Agents receive `busy` while a human controls the screen; they may
still observe it. Releasing control allows agent input again. Already submitted
XCTest phone gestures must finish, but queued gestures are cancelled.

Agent calls use the existing authenticated signaling socket. They have a short
deadline, are bound to the exact host connection and publication generation,
and are never automatically replayed after a lost acknowledgement. A failed or
interrupted call requires another observation before deciding whether to send
more input. Hosts without the agent capability flag remain viewable and do not
advertise an unsupported tool. Connect-scoped agents receive no screen tools.

Linux uses `grim` to observe the existing compositor without opening a second
Waymote input session. Some distribution builds advertise JPEG in their help
while disabling it at compile time; the companion captures PNG and converts
only agent observations to bounded JPEGs. Native Mac and paired-phone hosts
encode the latest captured frame on demand.

The Linux companion reads Waymote's native Annex-B H.264 pipe, bounds each
access unit, and packetizes it into WebRTC RTP using the encoder's 60 Hz clock.
There is no second decode/encode pass. This also works with libkrun TSI, whose
[documented networking limitations](https://github.com/libkrun/libkrun#known-limitations)
exclude listening on guest UDP sockets. The original loopback RTP hop produced
a connected control channel but no video in a real VM; the pipe fixes that. The current desktop profile is 1600×900,
60 fps, 6 Mbps. Those are configuration targets, not measured latency guarantees.

## Apple setup

Build the Apple projects normally. The Mac app's build phase builds and signs
`nanocodex-remote` into `Contents/Helpers`; this requires Go 1.26 in addition to
Xcode and the existing managed runtime/Node build prerequisites. Both clients
expose Screens; the account browser exposes Screens from Connect and the agent
terminal.

For Mac hosting, choose a display and explicitly start sharing. macOS Screen
Recording permission is required for capture, and Accessibility/input permission
for control. Allow Local Network access when connecting to a Hand on the same
network. Sharing remains visible in the main Mac toolbar after the picker
closes. Stop sharing and account changes revoke viewers and release input.

For iPhone hosting:

1. Pair and trust the iPhone with the Mac, enable Developer Mode, and configure
   Apple development signing in Xcode.
2. Build the `WebDriverAgentRunner` scheme from Appium WebDriverAgent using
   `build-for-testing` for that device. The output includes a `.xctestrun` file
   beside the signed runner application. Keep both together. The bridge currently
   accepts the standalone WebDriverAgentRunner format, not a combined test plan.
3. In the Mac app's Screens panel, find the paired iPhone, choose that trusted
   `.xctestrun`, and click Share iPhone. The app starts the companion and runner;
   separate terminal processes are unnecessary.
4. View/control the shared iPhone from another authenticated client. Stop sharing
   closes the tunnels and requests WDA shutdown. The companion also stops when
   its owning app's stdin closes, including after an app crash.

The bridge binds only `127.0.0.1:18100` and `127.0.0.1:19100`, on both the Mac and
runner configuration. It refuses occupied ports. Account/provider credentials
are excluded from the runner's environment. A manual developer bridge is also
available as `nanocodex-remote phone-tunnel --udid DEVICE`.

This is a paired developer-device workflow, not system-wide touch injection from
an ordinary App Store application. It does not require iPhone Mirroring. XCTest
submits complete drag gestures on release, so iPhone dragging does not yet have
the Mac backend's continuous feedback. Screen rotation ends sharing and requires
sharing the new geometry. The current phone stream is MJPEG from the runner,
converted to a WebRTC video track on the Mac.

## Cloudflare relay

The managed Worker accepts `NANOCODEX_TURN_KEY_ID` and
`NANOCODEX_TURN_API_TOKEN`. It generates one-hour credentials through Cloudflare
Realtime TURN through its `generate-ice-servers` endpoint and caches them briefly
per account. The API token stays on the Worker. Each new viewer fetches current
credentials; a long-running host does not retain its startup credentials for
later viewers. Linux fetches them asynchronously so existing input is not
blocked by a new viewer joining. Without both settings, the endpoint returns
Cloudflare STUN only.

Hosts refresh credentials and restart ICE every twenty minutes; viewers fetch
current credentials before answering each offer. This stays within the one-hour
credential lifetime even when the server returns a ten-minute-old cached value.
The existing video tracks and control channels survive renewal. Hosts send new
ICE candidates after their corresponding offers, and unanswered host offers
expire after twenty-five seconds.

Cloudflare Realtime was activated with explicit approval. The user supplied
`TURN_TOKEN_ID` and `TURN_SERVER_API_KEY` in the main checkout's private `.env`;
only those values were mapped to the isolated managed Worker's `.dev.vars`
bindings above. No production deployment has been performed.

The real authenticated development Worker now issues Cloudflare credentials.
Live testing caught a Workers compatibility issue: its fetch implementation
requires `redirect: "manual"`; redirects and other non-success responses are
rejected without forwarding the provider credential. Provider errors return 503.

A native WebRTC test forced Cloudflare relay candidates, decoded video, exchanged
reliable input and disposable motion, and switched to newly minted credentials
and a new TURN allocation. Video and input continued after ICE restart. The test
passed in 1.696 seconds (`/tmp/nanocodex-cloudflare-relay-test.log`); this is test
runtime, not an end-to-end latency measurement. The earlier local Coturn renewal
test also passed.

## VM setup and lifecycle

`hands/remote/image/Dockerfile` builds a pinned labwc/Waymote desktop and the Go
companion. Build it from `hands/remote` with:

```sh
docker build -t nanocodex-remote-desktop:development -f image/Dockerfile .
```

For a factory, materialize the image as a raw ext4 root using the existing
[`VmImageBuilder`](VM.md#preparing-immutable-images), then pass that immutable
root to the normal factory command:

```sh
nanocodex2 host --factory-name desktop-hands \
  --vm-template /path/to/desktop.ext4 \
  --vm-guest-runtime /path/to/nanocodex-vm-guest \
  --state-dir /path/to/private-factory-state --vm-workspace /workspace
```

Use a guest ELF built for the image architecture. On Apple Silicon, sign the
host executable with `nanocodex-vm.entitlements` after every Rust rebuild, and
provide `--vm-firmware` if libkrunfw is outside the system loader path. The
factory automatically clones a private writable root for each allocation.
Updating a template affects future allocations; retained VM roots are preserved.

For local Portless testing only, the guest needs the public Portless CA and an
`/etc/hosts` entry for the canonical development hostname; `.localhost` wildcard
resolution on macOS is not inherited by Linux. Under TSI that entry points to
`127.0.0.1`. These development settings do not belong in production images.

The image and authenticated desktop backend work in a real Wayland container.
Factory-spawned `nanocodex-vm` Hands now launch the companion when it is present
in their image; shell-only and explicitly offline images keep their existing behavior.
The real factory mounted the desktop in 1.345 seconds on the test Mac,
published it with its allocation credential, and retained its workspace across
agent turns and a host restart. This is one local startup sample.

The integration lives in the existing VM launch/lifetime owners, including
`vm_hand.rs` and `vm_host.rs`. It preserves each VM's private
root, workspace mounts, two-turn retention, and shutdown contract. The guest must
receive an allocation-scoped host credential, never a full account/provider key.
The current standalone `--credential-file` path was tested using an isolated
local development account; it must not be copied into factory guests as-is.

The user explicitly approved the scoped Rust launch/shutdown changes. Factory
startup now detects the desktop companion in the image and publishes with the
allocation credential. The guest retains labwc across signaling reconnects,
rotates its credential when the host lease changes, and exits before VM shutdown.
A real factory VM has now streamed decoded 1600×900 video to both the browser
and native Mac viewer. Browser text and raw key input created/read workspace
files, and pointer dragging moved its terminal window. Host shutdown disconnected
the old viewer; restarting retained the private root and its files. Network
publication retries independently of compositor readiness, so a signaling outage
does not block the shell attachment.

## Evidence and outstanding work (2026-09-07)

- A real managed agent discovered the factory VM's `screen_*` tool, received
  decodable screenshots through Code Mode, clicked its visible terminal, typed
  a command, and pressed Return. A later screen-only turn visibly listed the
  resulting `/workspace/agent-screen-control-evidence` file and the retained
  file created by the iOS viewer. No shell tool was used for these screen
  journeys. Native video continued while the agent worked.
- The native Mac viewer took human control of that VM. Agent observation still
  succeeded, but its one attempted text action returned `busy`; the marker was
  absent afterward. After release, agent input worked again. In a second live
  check, human takeover interrupted the third drag of a bounded four-drag
  sequence. The result was `cancelled`, and the agent never sent the fourth
  drag (`/tmp/nanocodex-remote-vm-agent-interrupt2.log`).
- Local VM screen-tool observations took 67–85 ms and click/text/Return actions
  with a resulting screenshot took 174–180 ms in the first successful journey
  (`/tmp/nanocodex-remote-vm-agent-screen-live2.log`). These are tool response
  samples, excluding model reasoning, not internet latency claims. The Linux
  gesture scheduler now keeps the requested gesture clock instead of rounding
  every step's delay up to a host tick; input delayed over 500 ms is cancelled.
- Eight Worker protocol tests pass across signaling and agent screen routing,
  including host replacement, cross-account rejection, result ownership, stale
  routes, image results, and unknown outcomes without replay. Five Swift
  protocol tests pass, including real JPEG encoding, image bounds, and clearing
  retained frames. Go race tests pass after the capture and scheduling fixes.
- Native Mac and iOS Simulator app builds pass. The Swift package's protocol tests
  and real WebRTC video/data-channel test pass.
- The Mac app's real Screens UI published its 2560×1440 display, and the account
  browser decoded the ScreenCaptureKit stream at 1920×1080. Sharing remained
  visible after closing the picker. The main toolbar stop action disconnected
  the browser and removed the Mac from the account catalog. This used the
  isolated app bundle with `NANOCODEX_DESKTOP_DATA` and `NANOCODEX_ENV_FILE`,
  leaving the normal app's runtime and saved account untouched.
- The current Mac test build uses a stable Apple Development signing identity.
  Ad-hoc signatures can change the identity macOS associates with permissions
  on every rebuild; use your team's development certificate for repeated TCC
  testing. Read-only inspection confirmed the current test app's saved Screen
  Recording and Accessibility grants still require the old ad-hoc code hash,
  while the installed build has a certificate-based designated requirement.
  The enabled Settings entries therefore do not authorize this build. Removing
  and re-adding the exact signed test app is pending; future builds using the
  same signing identity retain a stable requirement. Mac host input remains
  unverified until that grant applies.
  The UI now exposes Enable control for a shared display lacking input access,
  retains permission guidance across catalog refreshes, and remembers the host's
  selected display when reopening the picker.
- Five signaling tests pass in the real local Durable Object runtime, including
  host replacement, stale generation, authorization expiry, and ownership of
  viewer closure. Managed and account TypeScript checks pass. Six account proxy
  tests previously passed. Two TURN endpoint contract tests pass, covering the
  documented request, credential cache expiry, and provider failure. These use a
  stubbed provider and do not constitute Cloudflare relay connectivity evidence.
  Nine VM pool tests also pass, including the public allocation-authenticated
  screen publication/renewal route and rejection after allocation release.
  Twenty-three Rust VM host lifecycle tests pass.
- A native account-authenticated VM viewer changed the focused test terminal
  through the WebRTC data channel and detected the resulting decoded-pixel
  transitions at 84 and 77 ms locally. The measurement excludes signaling setup
  and reports the first substantial visual change, not completion of an arbitrary
  application operation (`/tmp/nanocodex-remote-vm-latency-test.log`).
  The final packaged companion also passed this journey, with local samples of
  61 and 63 ms (`/tmp/nanocodex-remote-vm-latency-test-v6.log`). Its agent drag
  journey moved the visible terminal and released control; a requested 1500 ms
  drag returned its screenshot in 2.533 seconds, so that duration setting is
  best effort, not an end-to-end response deadline.
- The browser decoded the real 1600×900 Wayland stream, submitted text and raw
  keyboard input, created files in the desktop's workspace, released control,
  and reconnected after page reload. The retained files remained visible. The
  latest packaged companion also reconnects, decodes video, and accepts keyboard input. Browser Escape
  shortcut delivery remains unverified in the current automation environment;
  the visible Release control button works.
- The native iPhone Simulator UI signed into the real local account over HTTPS,
  decoded the Wayland desktop, took control, sent a shell command that created
  `/workspace/ios-native-control-evidence`, released control, relaunched, and
  reconnected. The test passed and its retained screenshots show decoded video
  before and after reconnect. Simulator tests require normal Xcode signing:
  disabling signing omits the app identity needed for Keychain storage. This
  validates the iOS viewer UI. The same journey also passed against the rebuilt
  companion that fetches credentials per viewer and renews ICE. A physical iPhone
  viewer on another network still needs evidence.
- The same iOS UI journey passed against the actual factory VM in 56.565 seconds
  (`apple/build-remote-evidence/RemoteVM-3.xcresult`), including the terminal
  command, keyboard visibility, release, app relaunch, and reconnection. An
  earlier attempt stalled while opening the Simulator keyboard and lost the
  session; the repeat completed without changing the input implementation.
- The physical iPhone 17 Pro (iOS 26.6) produced decoded WebRTC frames and accepted
  Home through a viewer data channel. Account-authenticated tests have passed
  discovery, control exclusivity, touch input opening Calculator's mode menu,
  Home input, handoff, and stop/disconnect using
  the owned bridge. Intermittent native ICE failures on this Mac's virtual/VPN
  interfaces were resolved for same-Mac viewers by enabling loopback candidates.
  Three consecutive full account/phone runs then passed, including two viewers
  and control handoff (19.99 s, 19.73 s, 18.44 s total test duration). Those
  durations are not input latency measurements. A separate decoded-video check
  measured Home input to the first substantial visible transition at 295, 296,
  and 305 ms in three local runs. It sampled frame luminance after Calculator
  settled and separately verified SpringBoard became active; it retained no
  screenshots. This is a small local sample, not an internet performance claim.
- The physical-phone account test exercises renewal accelerated to three
  seconds. Both native viewers retain video and the control lease across repeated
  renewals, followed by control handoff. A browser joined the same phone host,
  decoded 602×1310 video across three observed ICE renewals, and received the
  correct control-exclusivity response after renewal. Extended runs exposed a
  test fixture issue: Calculator restores its open mode menu after Home. The
  test now dismisses that existing menu through remote input and waits for the
  mode button to become hittable before opening it again. Two consecutive full
  runs passed after this correction, with Home-to-visible-transition samples of
  272 and 280 ms. These remain local measurements, not internet latency claims.
- The owned phone bridge starts against the physical device and releases its
  localhost listeners on stop. The signed runner configuration is copied
  privately; source artifacts remain unchanged.
- A real managed agent also controlled the physical iPhone through its published
  screen tool. It observed Calculator, tapped the mode button, and returned
  decodable 589×1280 screenshots. A native viewer took control; the agent's one
  Home attempt returned `busy`, and Calculator remained active. After release,
  agent Home input succeeded and an independent device query confirmed
  SpringBoard. Stopping sharing disconnected the viewer and closed both bridge
  listeners. `AccountPhoneAgentTests` passed in 105.340 seconds; that includes
  model reasoning and is not a latency sample. The evidence is private under
  `/tmp/nanocodex-phone-agent-evidence`, with the test log at
  `/tmp/nanocodex-phone-agent-test2.log`.
- Go race tests cover control fencing, input sequencing, runner configuration,
  and bounded H.264 pipe framing/packetization. The gated Wayland integration test exercised the
  real compositor, encoded video, and injected input. The full account/Wayland test also
  publishes a real host, observes changed ICE credentials, and creates a terminal
  file through the existing data channel after renewal while video continues.
  Run these tests with exclusive access to the desktop: two Waymote instances
  compete for the compositor input method. The application uses one capture per
  host and shares it across viewers.

Remaining functional verification is native Mac host pointer/keyboard input
and its agent screen tool after the exact signed app receives its macOS
permissions. Re-add
`macos/build-remote-evidence/Build/Products/Debug/Nanocodex.app` in Screen Recording
and Accessibility; leave the normal Nanocodex application's entries unchanged.
A physical iPhone viewer on
a different network and a production-duration Cloudflare relay soak have not
been tested. Those are deployment/performance follow-ups, not evidence already
provided by the local tests.
No latency numbers should be inferred from test duration or configured FPS.

For the gated Mac viewer test, first start sharing through the isolated Mac app,
focus its empty composer, and provide its published machine ID:

```sh
NANOCODEX_TEST_REMOTE_ENV=/path/to/local-account.env \
NANOCODEX_TEST_MAC_MACHINE_ID=the-published-machine-id \
swift test --package-path apple/NanocodexRemote --filter AccountMacTests
```

The environment file contains `NANOCODEX_MANAGED_URL` for the localhost service
and its local `NANOCODEX_API_KEY`. The input guard requires the app bundle ID
`xyz.paradigm.nanocodex.macos.remote-evidence`. After a non-skipped run, inspect
the composer for `WebRTC Mac input verified`: text entry plus a raw Backspace
must remove the trailing test character. The test does not inspect another
application's UI or count a skipped input step as completed input evidence.

References: [Cloudflare Realtime](https://developers.cloudflare.com/realtime/),
[Waymote](https://github.com/rockorager/waymote),
[Appium WebDriverAgent](https://github.com/appium/WebDriverAgent),
[WebRTC network defaults](https://webrtc.googlesource.com/src/%2B/5a7e6f8ed1c1313300fb6bb48d70e056202011ed/rtc_base/network.h),
[iPhone Mirroring requirements](https://support.apple.com/en-gb/120421).

Device inventory remains available at `GET /v1/account/hands`. Screen viewers
use `GET /v1/account/hands/screens`; the separate responses preserve the native
Hands inventory while screens are published, disconnected, or replaced.
