# Subway Lore system diagrams

These diagrams describe the current proof-of-concept implementation. They reflect the code as it exists today, including the parts that are present but not yet exposed as user-facing features.

## 1. Overall project setup

```mermaid
flowchart TB
    subgraph App["SubwayLore iOS app"]
        direction TB

        subgraph UI["SwiftUI presentation"]
            ContentView
            NearbyNetworkCard
            NearbySessionView
        end

        subgraph Model["UI state boundary"]
            ViewModel["NearbySessionViewModel<br/>@MainActor ObservableObject"]
            Snapshot["DiscoverySnapshot<br/>peers, link states, chat messages"]
        end

        subgraph Coordination["Networking coordination"]
            Discovery["PeerDiscovery actor<br/>discovery plus explicit chat lifecycle"]
            Reducer["DiscoveryReducer<br/>snapshot state transitions"]
            Arbitration["ConnectionArbitration<br/>chooses one initiator"]
            PeerConn["PeerConnection actor<br/>handshake and receive loop"]
        end

        subgraph Wire["Transport and protocol"]
            Transport["TransportConfiguration<br/>TLS, TCP, peer-to-peer"]
            Framer["MessageFramer / FrameDecoder<br/>4-byte length-prefixed frames"]
            Envelope["PeerEnvelope + PeerMessage<br/>versioned JSON messages"]
        end

        subgraph Support["Identity, trust, and observability"]
            Identity["PeerIdentityStore<br/>persistent UUID + Rider name"]
            Certificate["Bundled POC PKCS#12 identity<br/>shared certificate pin"]
            Diagnostics["DiagnosticsRecorder<br/>in-memory + unified Logger"]
        end
    end

    ContentView --> ViewModel
    NearbySessionView --> ViewModel
    ViewModel --> Snapshot
    ViewModel --> Discovery
    Discovery --> Reducer
    Reducer --> Snapshot
    Snapshot --> NearbyNetworkCard
    Discovery --> Arbitration
    Discovery --> PeerConn
    Discovery --> Transport
    PeerConn --> Framer
    PeerConn --> Envelope
    Identity --> ViewModel
    Identity --> Discovery
    Certificate --> Transport
    Discovery --> Diagnostics
    PeerConn --> Diagnostics

    Bonjour["Local network Bonjour<br/>_subwaylore._tcp"] <--> Discovery
    Remote["Another SubwayLore app"] <--> Bonjour
    Remote <--> Transport
```

The UI does not call Network framework APIs directly. `NearbySessionViewModel` starts discovery, consumes the `AsyncStream<DiscoverySnapshot>`, and publishes the latest snapshot to SwiftUI. Opening Car Chat calls `joinChat(maximumPeers:)`; leaving it calls `leaveChat()`.

## 2. Peer discovery lifecycle

```mermaid
sequenceDiagram
    autonumber
    participant UI as SwiftUI
    participant VM as NearbySessionViewModel
    participant PD as PeerDiscovery actor
    participant L as TLS Bonjour listener
    participant B as Bonjour browser
    participant R as DiscoveryReducer
    participant Other as Remote peer

    UI->>VM: start
    VM->>PD: snapshots
    PD-->>VM: initial snapshot
    VM->>PD: start
    PD->>R: start
    PD->>L: advertise _subwaylore._tcp<br/>name + peerID TXT record
    PD->>B: browse _subwaylore._tcp<br/>include TXT records

    L-->>PD: listener ready with port
    PD->>R: listenerReady(port)
    PD-->>VM: searching snapshot

    Other-->>B: Bonjour service appears
    B-->>PD: endpoint set changed
    PD->>PD: map endpoints to DiscoveredPeer<br/>filter local peer UUID
    PD->>R: replacePeers
    R-->>PD: added and removed endpoint IDs
    PD-->>VM: peerFound snapshot
    VM-->>UI: render nearby rider node without an edge
    Note over UI,PD: Discovery does not create peer connections

    Other--xB: Bonjour service disappears
    B-->>PD: endpoint set changed
    PD->>R: replacePeers without remote peer
    R->>R: remove stale per-peer link state
    PD-->>VM: updated snapshot
    VM-->>UI: remove peer node
```

### Discovery state model

```mermaid
stateDiagram-v2
    [*] --> notStarted
    notStarted --> waitingForPermission: start
    notStarted --> searching: listener or browser ready
    waitingForPermission --> searching: network access becomes available
    searching --> peerFound: at least one remote peer discovered
    peerFound --> searching: all remote peers disappear
    searching --> permissionUnavailable: local-network access denied
    waitingForPermission --> permissionUnavailable: local-network access denied
    searching --> failed: listener or browser fails
    peerFound --> failed: listener or browser fails
    permissionUnavailable --> notStarted: stop
    failed --> notStarted: stop
    searching --> notStarted: stop
    peerFound --> notStarted: stop
```

Discovery and connection are deliberately separate. The landing page advertises and browses continuously but does not initiate connections. Per-peer link states change only while Car Chat is active.

## 3. Secure network connection

Opening Car Chat selects at most eight discovered peers and starts connection attempts. Both users must open Car Chat. If both sides create a connection, UUID arbitration keeps the connection whose direction both peers deterministically prefer.

```mermaid
sequenceDiagram
    autonumber
    participant Low as Lower-UUID app
    participant High as Higher-UUID app

    Note over Low,High: Both apps advertise and discover each other with Bonjour
    Low->>Low: user opens Car Chat
    High->>High: user opens Car Chat
    Low->>Low: select up to 8 nearby peers
    High->>High: select up to 8 nearby peers
    Low->>Low: arbitration chooses outgoing
    High->>High: arbitration chooses incoming
    Low->>Low: link state = connecting

    Low->>High: open TCP connection to Bonjour endpoint
    Low<<->>High: TLS 1 connection setup<br/>local PKCS#12 identity<br/>required peer authentication<br/>pinned shared certificate<br/>ALPN subwaylore-poc-v1

    par Symmetric application handshake
        Low->>High: framed JSON hello<br/>peerID, display name, capabilities
        High->>Low: framed JSON hello<br/>peerID, display name, capabilities
    end
    Low->>High: helloAccepted with local peerID
    High->>Low: helloAccepted with local peerID

    Low->>Low: validate protocol version<br/>sender ID and expected peer ID
    High->>High: validate protocol version<br/>sender ID
    Low->>Low: accept preferred outgoing direction
    High->>High: accept preferred incoming direction
    Low->>Low: link state = connected
    High->>High: link state = connected
    Note over Low,High: Participant strip shows green connected outlines

    loop Receive until closed
        Low<<->>High: ping, pong, text, or goodbye envelope
        Note over Low,High: Text is appended to ephemeral chat on receipt
    end

    alt Back navigation, goodbye, error, stop, or cancellation
        Low--xHigh: end stream
        Low->>Low: remove connection bookkeeping
        High->>High: remove connection bookkeeping
        Low->>Low: clear chat state and messages on leave
        High->>High: link state = discovered if still in chat
    end
```

### Per-peer link state and UI

```mermaid
stateDiagram-v2
    [*] --> discovered: Bonjour endpoint visible
    discovered --> connecting: Car Chat selects peer
    connecting --> connected: TLS and app handshake complete
    connecting --> discovered: setup or handshake fails
    connected --> discovered: connection closes while chat remains active
    discovered --> [*]: Bonjour endpoint disappears
    connecting --> [*]: Bonjour endpoint disappears
    connected --> [*]: Bonjour endpoint disappears or discovery stops
```

| Link state | Meaning | Current UI |
| --- | --- | --- |
| `discovered` | Bonjour can see the peer, but no secure session is active. | Node on landing page; neutral participant in chat |
| `connecting` | A TLS connection or application handshake is in progress. | Neutral participant plus “Connecting…” |
| `connected` | TLS and the `hello` / `helloAccepted` handshake succeeded. | Green participant outline and connected count |

## Current implementation boundaries

- Discovery, TLS setup, framing, handshake, connection arbitration, bounded chat connections, and text messaging are implemented.
- Car Chat is the explicit connection boundary. Leaving the chat closes connections and clears its in-memory messages while discovery continues.
- Car Game is visible as “Coming soon” and has no navigation or networking behavior.
- Chat messages are sent to currently connected peers only. History is not persisted or synchronized to riders who join later.
- Diagnostics are retained in memory and mirrored to Apple unified logging under subsystem `com.subwaylore.SubwayLore`.
- `ping` and `pong` protocol types exist but currently have no user-facing behavior.
- A failed connection returns to `discovered`; there is no visible per-peer failure state or explicit retry policy.
- The bundled PKCS#12 identity and password are proof-of-concept material. Every installation trusts the same pinned certificate; this is not a production identity or trust design.
