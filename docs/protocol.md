# Protocol behavior

What a WebTorrent client sees on the wire: compatibility guarantees, failure responses,
and how peer identity is handled.

- [Compatibility](#compatibility)
- [Error semantics](#error-semantics)
- [Peer identity and reconnection](#peer-identity-and-reconnection)

## Compatibility

SwarmMux targets interoperability with the WebTorrent WebSocket tracker protocol
implemented by
[`webtorrent/bittorrent-tracker`](https://github.com/webtorrent/bittorrent-tracker).

That extension is not described by a finalized standalone BEP, so SwarmMux treats the
behavior of the official WebTorrent tracker implementation as the primary compatibility
reference while following the relevant BitTorrent tracker semantics from:

- [BEP 3: The BitTorrent Protocol Specification](https://www.bittorrent.org/beps/bep_0003.html)
- [BEP 48: Tracker Protocol Extension: Scrape](https://www.bittorrent.org/beps/bep_0048.html)

Compatibility details:

- `info_hash`, `peer_id`, `to_peer_id`, and `offer_id` are typed 20-byte values.
- The wire codec handles WebTorrent's JSON binary-string representation.
- SDP offers and answers are opaque signaling payloads.
- Announce events map to
  [`AnnounceEvent`](architecture.md#identifiers-and-events); an absent event field means
  `EventUpdated`.
- A single WebSocket connection may participate in multiple swarms.
- Closing a connection removes every membership associated with that session.
- Application-specific announce fields are preserved and validated through
  [`Metadata`](extension-points.md#metadata).

SwarmMux does not create `RTCPeerConnection` objects and does not parse SDP for WebRTC
behavior. It only routes signaling data between peers.

Classic HTTP and UDP tracker endpoints (BEP 3 / BEP 15), DHT, and PEX are out of scope.

> **API stability note.** `protocol.Message` appears in the public `Session` interface, so
> the `protocol` package is bound to the same compatibility promise as the root package.

## Error semantics

```go
var (
    ErrForbidden      // Authorizer rejected the swarm join
    ErrPeerNotFound   // Router has no binding for the target peer
    ErrRateLimited    // application middleware rejected the message
    ErrInvalidMessage // malformed frame, bad identifier, or metadata validation failure
    ErrTooManySwarms  // MaxSwarmsPerSession exceeded
    ErrPeerIDConflict // peer_id already bound to a different live session
    ErrQueueFull      // outbound queue overflow under CloseSession policy
    ErrShutdown       // tracker is shutting down or already shut down
    ErrBackend        // the Store or Router failed; the cause is wrapped
)
```

| Error | Sent to client as | Connection |
|---|---|---|
| `ErrForbidden` | `failure reason` | stays open |
| `ErrPeerNotFound` | `failure reason` | stays open |
| `ErrRateLimited` | `failure reason` | stays open |
| `ErrInvalidMessage` | `failure reason` | stays open |
| `ErrTooManySwarms` | `failure reason` | stays open |
| `ErrBackend` | `failure reason` | stays open |
| `ErrPeerIDConflict` | `failure reason` | **closed** |
| `ErrQueueFull` | none | **closed** |
| `ErrShutdown` | none | **closed** |

Per-announce failures keep the connection alive so a client can retry or announce a
different swarm. Only identity conflicts, backpressure, and shutdown terminate a session.

Failure reason strings are intentionally coarse and do not echo back attacker-supplied
input.

### Backend failures

An error from [`Store`](extension-points.md#store) or
[`Router`](extension-points.md#router) that is not one of the sentinels above is wrapped
in `ErrBackend`, reported through [`Observer`](extension-points.md#observer), and
surfaced to the client as a failure response. The announce has no effect: no membership
is written, and no peers are returned.

**The connection stays open.** A database failover or a broker hiccup is routine for a
tracker attached to real infrastructure, and closing every session on one would send the
entire swarm reconnecting into a backend that is already struggling. Clients retry at the
announce interval instead.

SwarmMux does not retry on the adapter's behalf and adds no deadline of its own to the
context it passes. Retry policy, circuit breaking, and timeouts belong to the adapter,
which is the only layer that knows what its backend costs.

## Peer identity and reconnection

Any client can claim any `peer_id` in an announce. Without protection, a malicious client
could claim a victim's `peer_id` and receive answers meant for them.

SwarmMux binds identity through the [`Router`](extension-points.md#router):

- Every announce calls `Router.Bind` for the `(InfoHash, PeerID)` pair. The first call
  claims it for that session; later calls from the holder refresh it.
- `Bind` reports the session that holds the pair. When that is a **different** session,
  the announce is rejected with `ErrPeerIDConflict` and the claiming session is closed.
  The existing binding is left intact, so a hijack attempt cannot displace the peer it
  targets.
- The claim is atomic, so the guarantee holds across a tracker fleet and not merely
  within one process — provided the `Router` honors
  [its contract](extension-points.md#router).
- When the owning session ends — disconnect, `stopped` event, or expiry — `Unbind`
  releases the pair and the identity becomes claimable again.
- Bindings carry a TTL. An instance that crashes without unbinding therefore does not
  strand a `peer_id` permanently; the binding lapses and the identity frees up.
- A reconnect after a dropped connection succeeds once the old binding is released or has
  expired. A client that reconnects faster than the binding lapses sees
  `ErrPeerIDConflict` and should retry, which is the same signal an actual conflict
  produces — the tracker cannot tell the two apart.

Re-announcing an existing `(InfoHash, PeerID)` from the **same** session is idempotent and
simply refreshes `LastSeen` and statistics.

This is identity *continuity*, not authentication. For real guarantees, authenticate the
upgrade request and enforce the peer identity in your
[`Authorizer`](extension-points.md#authorizer).
