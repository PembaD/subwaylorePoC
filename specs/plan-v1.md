# Subway Lore POC — Implementation Plan V1

## Objective

Build a two-device iOS proof of concept that demonstrates nearby discovery and direct messaging without internet access using Apple's modern Network.framework APIs.

The POC must answer:

> Can two physical iPhones discover each other, establish a secure peer-to-peer connection, exchange small messages, detect a disconnect, and reconnect reliably enough to justify building the Subway Lore mesh protocol?

This plan covers direct connections only. Multi-hop routing, production identity, cloud sync, games, and the full social product are later phases.

---

## Technical Baseline

| Area | V1 decision |
|---|---|
| IDE / SDK | Xcode 27 with the latest installed iOS SDK |
| Minimum iOS version | iOS 26.0 |
| Language mode | Swift 6 |
| UI | SwiftUI |
| Discovery | `NetworkBrowser` with Bonjour |
| Inbound connections | `NetworkListener` |
| Direct transport | `NetworkConnection` over TCP |
| Nearby path | Apple peer-to-peer Wi-Fi enabled in Network parameters |
| Security | TLS through Network.framework plus an application handshake |
| Message encoding | `Codable` JSON |
| Message framing | Fixed-width length prefix followed by JSON payload |
| State management | Swift actors for transport; `@MainActor` observable UI model |
| Persistence | None in V1; diagnostics stay in memory and can be exported |
| Backend | None |

MultipeerConnectivity and `MCSession` must not be introduced. WebSockets are not part of nearby communication.

---

## Scope

### Included

- One iOS app installed on two or more physical iPhones.
- A landing page that enters a nearby-session diagnostic screen.
- Per-install POC peer identity.
- Bonjour advertising and browsing.
- Direct peer-to-peer TCP connection establishment.
- TLS transport configuration.
- Duplicate-connection resolution.
- Bidirectional ping and short text-message exchange.
- Length-prefixed message framing.
- Connection lifecycle and error diagnostics.
- Manual log export.
- Unit tests for protocol behavior.
- At least 20 physical-device connection cycles.

### Excluded

- Multi-hop relaying and five-neighbor topology management.
- Train-car boundary detection.
- Feed, production DMs, waves, trivia gameplay, or friends.
- Sign in with Apple.
- Production key management and reputation.
- GRDB, event sourcing, or cloud synchronization.
- C++ backend components.
- WebSockets, APNs, analytics SDKs, and crash-reporting SDKs.
- UWB / Nearby Interaction.
- App Store distribution.

---

## Repository Structure

Evolve the project toward the following layout:

```text
SubwayLore/
  SubwayLore/
    App/
      SubwayLoreApp.swift
    Features/
      Landing/
        LandingView.swift
      NearbySession/
        NearbySessionView.swift
        NearbySessionViewModel.swift
    Networking/
      PeerTransport.swift
      NetworkPeerTransport.swift
      PeerDiscovery.swift
      PeerConnection.swift
      MessageFramer.swift
      TransportConfiguration.swift
    Protocol/
      PeerIdentity.swift
      PeerEnvelope.swift
      PeerMessage.swift
      Handshake.swift
    Diagnostics/
      DiagnosticEvent.swift
      DiagnosticsRecorder.swift
      DiagnosticsExportView.swift
    DesignSystem/
      LoreColors.swift
      LoreCard.swift
    Resources/
      Assets.xcassets
  SubwayLoreTests/
    MessageFramerTests.swift
    ProtocolEncodingTests.swift
    ConnectionArbitrationTests.swift
    DiagnosticsRecorderTests.swift
  SubwayLoreUITests/
specs/
  plan-v1.md
```

Do not split code into packages during V1. Protocol boundaries should be explicit in source, but a package adds little value until a second target consumes the code.

---

## Phase 0 — Project Configuration

### Tasks

1. Restrict supported destinations to iPhone and iPad.
2. Set the minimum deployment target to iOS 26.0.
3. Set Swift language mode to Swift 6.
4. Replace the placeholder bundle identifier with a stable reverse-domain identifier.
5. Confirm automatic signing for both physical test devices.
6. Add `NSLocalNetworkUsageDescription` with user-facing copy explaining nearby rider discovery.
7. Add `_subwaylore._tcp` to `NSBonjourServices`.
8. Confirm the app installs and launches on both physical devices.
9. Preserve the existing landing page and move it into the feature-oriented folder structure.

### Suggested permission copy

> Subway Lore uses the local network to discover and connect with nearby riders, even when the internet is unavailable.

### Completion gate

- The app builds with Swift 6 for an iOS 26 simulator and two iOS 26+ physical devices.
- Both devices show the local-network permission prompt.
- Denying permission produces a visible, understandable state rather than a silent failure.

---

## Phase 1 — Protocol and Diagnostics Foundation

### Peer identity

Create a random installation ID on first launch and store it in `UserDefaults` for the duration of the POC. Generate a short display name such as `Rider-4F2A` from that ID.

This is not production identity. It exists only to make logs and deterministic connection arbitration understandable.

### Envelope

Every application message uses a versioned envelope:

```swift
struct PeerEnvelope: Codable, Identifiable, Sendable {
    let protocolVersion: UInt16
    let id: UUID
    let senderID: UUID
    let sequence: UInt64
    let sentAt: Date
    let body: PeerMessage
}
```

Initial message types:

- `hello`: protocol version, peer ID, display name, and capabilities.
- `helloAccepted`: confirms successful application handshake.
- `ping`: includes a correlation ID and sender timestamp.
- `pong`: echoes the correlation ID and timestamps.
- `text`: contains a short UTF-8 string.
- `goodbye`: optional graceful-disconnect reason.

Set conservative limits:

- Maximum framed payload: 64 KiB.
- Maximum text body: 1,000 Unicode characters for the POC.
- Unsupported protocol versions close the connection with a diagnostic event.

### Framing

TCP is a byte stream. One receive operation is not guaranteed to equal one application message.

Implement a framer that:

1. Reads a four-byte unsigned big-endian payload length.
2. Rejects zero-length and oversized frames.
3. Buffers partial input.
4. Emits every complete JSON payload in order.
5. Retains incomplete trailing bytes for the next receive.

### Diagnostics

Use a bounded in-memory recorder. Each event contains:

- Timestamp
- Severity
- Category
- Local peer ID
- Remote peer ID when known
- Connection ID when known
- Human-readable summary
- Structured metadata such as byte count, sequence, or error code

Never use `print` as the only record of a transport event. Console logging is useful during development, but the same important event must be visible or exportable in the app.

### Completion gate

- Protocol values round-trip through JSON encoding.
- The framer passes fragmented, combined, malformed, and oversized-input tests.
- The diagnostics recorder is safe to call across concurrent transport tasks.

---

## Phase 2 — Nearby Discovery

### Listener

Create a `NetworkListener` configured for TCP and TLS. Enable peer-to-peer operation and advertise the listener as `_subwaylore._tcp` over Bonjour.

The listener must:

- Select or publish an available port.
- Advertise the local peer's short display name as non-sensitive metadata when supported.
- Accept incoming connections.
- Report listener state transitions and failures.
- Stop cleanly when the nearby session ends.

### Browser

Create a `NetworkBrowser` for `_subwaylore._tcp` with peer-to-peer discovery enabled.

The browser must:

- Maintain a current set of discovered endpoints.
- Ignore the local service if it is returned.
- Surface additions, removals, and browser failures.
- Avoid opening repeated connections to the same endpoint.
- Stop cleanly when the nearby session ends.

### Permission states

Represent at least:

- Not started
- Waiting for permission
- Searching
- Peer found
- Permission denied or restricted
- Failed

The UI must distinguish "no peers nearby" from "local-network access is unavailable."

### Completion gate

- Device A discovers Device B and vice versa while both apps are foregrounded.
- Discovery works without internet connectivity.
- Starting and stopping discovery ten times does not leak duplicate browser or listener tasks.

---

## Phase 3 — Secure Direct Connection

### Connection ownership

Wrap every `NetworkConnection` in a `PeerConnection` actor responsible for:

- Connection state
- TLS establishment
- Application handshake
- Receive loop
- Framing and decoding
- Serialized sends
- Sequence generation
- Graceful shutdown
- Per-connection diagnostics

Views must never own Network.framework connection objects directly.

### TLS strategy

For V1, use Network.framework TLS rather than custom encryption. Document the trust model before coding it.

The preferred POC strategy is:

1. Generate or bundle only the minimum test identity necessary for TLS.
2. Perform an application handshake containing the stable POC peer ID.
3. Record that transport encryption does not by itself prove a production user identity.
4. Do not disable certificate verification globally or ship private production credentials in the repository.

If ad-hoc mutual trust prevents the first connection spike, complete a clearly labeled unencrypted local TCP spike, then add TLS before declaring Phase 3 complete. Plain TCP is an intermediate diagnostic step, not an accepted POC result.

### Duplicate connections

Both devices may discover and connect to each other at the same time. After exchanging `hello` messages:

- Compare the two stable peer UUIDs.
- Apply one deterministic rule for which direction survives.
- Close the duplicate connection.
- Record the arbitration decision.

For example, the device with the lexicographically smaller UUID retains its outbound connection and rejects the inverse duplicate.

### Completion gate

- Two devices establish exactly one logical connection.
- Both sides complete TLS and the application handshake.
- Simultaneous discovery does not leave duplicate logical connections.
- Invalid, oversized, or unsupported messages close only the affected connection and do not crash the app.

---

## Phase 4 — Messaging and Latency Measurement

### Messaging behavior

Implement:

- Send ping to one connected peer.
- Send ping to every connected peer.
- Send a short text message.
- Receive and display text messages.
- Suppress duplicate envelope IDs.
- Display message sequence and delivery timestamp.

### Latency

Calculate round-trip time from `ping` to matching `pong` using a monotonic local clock. Do not calculate one-way latency from wall-clock timestamps because device clocks may differ.

Track:

- Last round-trip time
- Minimum and maximum round-trip time
- p50 and p95 round-trip time for the current run
- Sent, received, duplicate, malformed, and failed message counts

### Completion gate

- 100 sequential pings complete in both directions without application-level duplication.
- Text messages survive deliberately fragmented frame delivery in tests.
- The UI remains responsive during sustained sends.

---

## Phase 5 — POC User Interface

### Landing page

Keep the current landing page visually focused. Replace mock values with transport state only when doing so is honest and useful.

- `Offline ready` means the local transport can be started; it must not imply a peer is already connected.
- The nearby-rider count comes from discovery or established handshakes.
- Car-chat and trivia cards remain non-interactive previews during V1 or should be visibly labeled as coming later.
- `Enter this car` starts the nearby session and opens the diagnostic experience.

### Nearby-session screen

Create a practical test screen containing:

1. Local peer name and short ID.
2. Permission and discovery state.
3. Listener state.
4. Discovered, connecting, and connected peers.
5. Start/stop networking control.
6. Ping-one and ping-all controls.
7. Short-message composer.
8. Received-message timeline.
9. Latency and delivery counters.
10. Timestamped event log.
11. Copy/share-log action.

### UX rules

- Networking failures must appear in the interface.
- Destructive diagnostic actions such as clearing logs require no production-level ceremony, but disconnect must be visually distinct from send actions.
- Controls unavailable in the current state must be disabled.
- The app must remain useful with Dynamic Type and VoiceOver.

### Completion gate

- A tester can conduct the entire two-device protocol without attaching Xcode.
- A tester can export enough information to explain a failed run.

---

## Phase 6 — Lifecycle and Recovery

Test and implement behavior for:

- Peer walks out of range.
- Peer disables Wi-Fi.
- App moves to the background.
- App returns to the foreground.
- App is force-closed and reopened.
- Listener fails and restarts.
- Browser fails and restarts.
- Connection stalls during handshake.
- Peer disappears while a message is being sent.

Use bounded exponential backoff with jitter for automatic retries. Manual stop must cancel pending retries immediately.

Foreground reconnection is required. Continuous background discovery is not a V1 requirement, but observed system behavior must be recorded.

### Completion gate

- Returning both apps to the foreground restores discovery and connection without reinstalling either app.
- Relay-unrelated failures do not require an app restart.
- All long-running tasks are cancelled when the user stops the session.

---

## Phase 7 — Physical-Device Validation

### Controlled test matrix

Run at least 20 complete cycles:

```text
start discovery
  → discover peer
  → connect and handshake
  → exchange 10 pings
  → exchange text in both directions
  → disconnect
  → reconnect
```

Record for each run:

| Metric | Measurement |
|---|---|
| Discovery time | Browser start until endpoint appears |
| Connection time | Connection start until Network.framework ready |
| Handshake time | Transport ready until `helloAccepted` |
| Ping RTT | p50 and p95 |
| Delivery | Sent, received, duplicate, malformed, failed |
| Recovery time | Disconnect until new handshake completes |
| Battery | Percentage change and duration |
| Environment | Room, street, station, moving train |
| Radio state | Wi-Fi, cellular, airplane mode configuration |

### Environment progression

1. Two devices in the same quiet room.
2. Devices separated across a room and hallway.
3. No internet access with the radios required for peer-to-peer communication still enabled.
4. Crowded public environment.
5. Subway platform.
6. Moving subway car.

### POC success criteria

- At least 19 of 20 controlled cycles complete successfully.
- No app crashes.
- No unresolved duplicate logical connections.
- No malformed frame causes unbounded allocation or process failure.
- Median discovery-to-handshake time is recorded, even if no target is imposed yet.
- Ping delivery and RTT distributions are recorded.
- Reconnection behavior is documented.
- Battery consumption is measured rather than guessed.

---

## Test Strategy

### Unit tests

- Every protocol message encodes and decodes.
- Unknown protocol versions fail predictably.
- Framer accepts partial headers and bodies.
- Framer emits multiple coalesced frames.
- Framer rejects zero and oversized lengths.
- Duplicate envelope IDs are suppressed.
- Sequence counters are monotonic per connection.
- Connection-arbitration decisions are deterministic.
- Diagnostics storage respects its maximum capacity.

### UI tests

- Landing page opens the nearby-session screen.
- Start/stop controls reflect state.
- Empty, denied, searching, connected, and failed states render correctly with injected fake transport states.
- Send controls are disabled without a connection.

### Dependency design for testing

Define a `PeerTransport` protocol consumed by the view model. Supply:

- `NetworkPeerTransport` for devices.
- `PreviewPeerTransport` for SwiftUI previews.
- `FakePeerTransport` for deterministic tests.

Do not mock Network.framework types throughout the UI. Keep framework-specific behavior behind the transport implementation.

---

## Implementation Order

Use small, independently verifiable pull requests or commits:

1. Project target, permissions, and folder organization.
2. Protocol models, framing, diagnostics, and unit tests.
3. Bonjour listener and browser with discovery UI.
4. Direct connection plus hello handshake.
5. TLS completion and duplicate-connection arbitration.
6. Ping, text messages, deduplication, and metrics.
7. Nearby-session diagnostic UI and log export.
8. Lifecycle recovery and retry policy.
9. Physical-device test run and results report.

Do not begin multi-hop routing until the V1 results report is reviewed.

---

## Known Risks

| Risk | V1 response |
|---|---|
| Local-network permission obscures discovery failures | Model permission-related states and expose errors in-app. |
| Both peers initiate connections | Resolve duplicates using stable peer IDs and a deterministic rule. |
| TCP boundaries are mistaken for message boundaries | Require and thoroughly test length-prefixed framing. |
| TLS trust becomes disproportionate POC work | Time-box the trust spike, permit plain TCP only as an intermediate step, and require TLS before completion. |
| Foreground/background transitions kill networking | Treat foreground reconnection as required and document background limits. |
| Simulator behavior differs from device behavior | Use the simulator for UI and unit tests only; validate transport on physical iPhones. |
| Mock landing-page activity is confused with live data | Clearly separate preview data from measured discovery and connection state. |
| Subway RF performance differs from office testing | Require platform and moving-train test runs before advancing to mesh work. |

---

## Deliverables

V1 is complete when the repository contains:

1. A buildable Swift 6 iOS 26+ application using the modern Network.framework API family.
2. A functional landing-to-diagnostics flow.
3. Bonjour peer discovery over Apple peer-to-peer networking.
4. One secure logical connection between two devices.
5. Bidirectional ping and short-text messaging.
6. In-app diagnostics and exported run logs.
7. Unit tests for protocol, framing, arbitration, and diagnostics.
8. Logs from at least 20 controlled cycles.
9. A written results report with a recommendation to proceed, revise, or stop.

The next plan should cover a three-device relay only if these deliverables demonstrate that direct peer-to-peer networking is sufficiently reliable.
