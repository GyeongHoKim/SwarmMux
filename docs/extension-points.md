# Extension points

Every decision SwarmMux refuses to make for you has a named interface. All of them are
optional: the zero-value `Tracker` supplies a working default for each.

- [`Authorizer`](#authorizer) — who may join a swarm
- [`Metadata`](#metadata) — application data carried on an announce
- [`Selector`](#selector) — which peers get matched
- [`Store`](#store) — where membership and statistics live
- [`Router`](#router) — how signaling reaches a peer on another instance
- [`Observer`](#observer) — metrics and tracing

## Authorizer

Authenticate the WebSocket upgrade with ordinary Go HTTP middleware:

```go
func requireToken(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        identity, err := authenticate(r)
        if err != nil {
            http.Error(w, "unauthorized", http.StatusUnauthorized)
            return
        }

        ctx := context.WithValue(r.Context(), identityKey{}, identity)
        next.ServeHTTP(w, r.WithContext(ctx))
    })
}

mux.Handle("GET /announce", requireToken(swarmws.NewHandler(&tracker)))
```

Then use `Authorizer` for swarm-specific policy after the connection is established:

```go
type Authorizer interface {
    Authorize(context.Context, Authorization) error
}

type AuthorizeFunc func(context.Context, Authorization) error

type Authorization struct {
    SessionID  SessionID
    RemoteAddr net.Addr
    InfoHash   InfoHash
    PeerID     PeerID
    Event      AnnounceEvent
    Extra      any // decoded by Metadata, nil if no hook is set
}
```

```go
tracker.Authorizer = swarmmux.AuthorizeFunc(
    func(ctx context.Context, request swarmmux.Authorization) error {
        identity, ok := identityFromContext(ctx)
        if !ok || !identity.CanAccess(request.InfoHash) {
            return swarmmux.ErrForbidden
        }
        return nil
    },
)
```

`Authorize` is called once per swarm join, not on every announce. Returning `ErrForbidden`
fails that announce and leaves the connection open; see
[error semantics](protocol.md#error-semantics).

Values placed on the request context by HTTP middleware are visible here — see
[context propagation](architecture.md#context-propagation).

SwarmMux intentionally does not define JWT, cookie, API-key, user-account, or
product-specific authorization models.

## Metadata

Applications can attach bounded, validated data to announcements and use it from selection
policy. SwarmMux core knows no application field names; you supply the decoder.

```go
type Metadata interface {
    Decode(context.Context, json.RawMessage) (any, error)
}

type MetadataFunc func(context.Context, json.RawMessage) (any, error)
```

A live-streaming service might accept:

```json
{
  "stream_position": 1042,
  "segment_from": 1038,
  "segment_to": 1046,
  "region": "kr-seoul"
}
```

```go
type myMeta struct {
    StreamPosition int64  `json:"stream_position"`
    SegmentFrom    int64  `json:"segment_from"`
    SegmentTo      int64  `json:"segment_to"`
    Region         string `json:"region"`
}

tracker.Metadata = swarmmux.MetadataFunc(
    func(ctx context.Context, raw json.RawMessage) (any, error) {
        var m myMeta

        decoder := json.NewDecoder(bytes.NewReader(raw))
        decoder.DisallowUnknownFields()
        if err := decoder.Decode(&m); err != nil {
            return nil, fmt.Errorf("%w: %v", swarmmux.ErrInvalidMessage, err)
        }
        if m.SegmentFrom > m.SegmentTo || m.Region == "" {
            return nil, swarmmux.ErrInvalidMessage
        }

        return m, nil
    },
)
```

The decoded value reaches [`Authorizer`](#authorizer) as `Authorization.Extra`. What
travels into the [`Store`](#store) is the **raw bytes**, not the decoded value: a store
backed by Redis or Postgres has to persist something it can serialize, and it has no way
to reconstruct an application-defined Go type on the way back out. Before calling
[`Selector`](#selector), the tracker decodes each candidate's stored bytes through this
same hook, so selection policy sees the typed value:

```go
meta, ok := candidate.Extra.(myMeta)
```

`Decode` therefore runs once for the announcing peer and once per candidate returned by
the store. Keep it cheap, and make it safe for concurrent use.

A candidate whose stored bytes no longer decode — an application that changed its schema
while peers were still announcing, say — is dropped from the selection and reported
through [`Observer`](#observer). It is not a connection-level failure.

When `Metadata` is nil — the default — extension fields are ignored entirely, nothing is
persisted, and `Extra` is always nil on both sides.

Reject unknown fields and enforce size limits. Never persist unbounded, unvalidated data
received from the network.

## Selector

SwarmMux ships a default selector so a tracker works immediately, but policy is
replaceable.

```go
type Selector interface {
    Select(context.Context, Selection) ([]Candidate, error)
}

type SelectorFunc func(context.Context, Selection) ([]Candidate, error)

type Selection struct {
    InfoHash   InfoHash
    Requester  Candidate
    Candidates []Candidate // bounded; see Store
    Count      int         // how many peers the requester asked for
    Truncated  bool        // true if the swarm is larger than Candidates
}

// Candidate is a peer as selection policy sees it: a stored membership record with its
// application data already decoded by Metadata.
type Candidate struct {
    ID        PeerID
    SessionID SessionID
    Left      int64
    LastSeen  time.Time
    Extra     any // decoded by Metadata, nil if no hook is set
}
```

`Candidate` is the selector-facing view of a [`Peer`](#store). They carry the same fields
except for `Extra`, which a `Store` holds as opaque bytes and a `Selector` receives
decoded — see [`Metadata`](#metadata).

```go
tracker.Selector = swarmmux.SelectorFunc(
    func(ctx context.Context, selection swarmmux.Selection) ([]swarmmux.Candidate, error) {
        return selectBestPeers(
            selection.Requester,
            selection.Candidates,
            selection.Count,
        ), nil
    },
)
```

A custom selector can rank on region or ISP, connection quality, upload capacity, live
playback position, overlapping media-segment cache windows, existing connection count, or
application-defined health scores.

`Candidates` is a **bounded sample**, never guaranteed to be the whole swarm. Check
`Truncated` if your policy needs to know that it is choosing from a subset.

Selectors decide policy. SwarmMux owns membership lifecycle and signaling routing.

## Store

The store holds swarm membership and statistics. It does **not** hold live connections —
see [Store and Router are different things](architecture.md#store-and-router-are-different-things).

```go
type Store interface {
    Update(context.Context, MembershipUpdate) (SwarmSnapshot, error)
    Scrape(context.Context, []InfoHash) (map[InfoHash]SwarmStats, error)
    DeleteSession(context.Context, SessionID) error
    Expire(ctx context.Context, olderThan time.Time) (removed int, err error)
}

type MembershipUpdate struct {
    InfoHash  InfoHash
    PeerID    PeerID
    SessionID SessionID
    Event     AnnounceEvent

    Left, Downloaded, Uploaded int64

    // Extra is the announce's application data, already validated by Metadata.
    // Store it verbatim; it is opaque to the store.
    Extra json.RawMessage

    // CandidateLimit is a hard upper bound on len(SwarmSnapshot.Candidates).
    CandidateLimit int

    Now time.Time
}

type SwarmSnapshot struct {
    Stats      SwarmStats
    Candidates []Peer // at most MembershipUpdate.CandidateLimit entries
    Truncated  bool   // the swarm holds more members than were returned
}

type Peer struct {
    ID        PeerID
    SessionID SessionID
    Left      int64
    LastSeen  time.Time
    Extra     json.RawMessage
}

type SwarmStats struct {
    Complete   int32
    Incomplete int32
    Downloaded int32
}
```

Assign it to the tracker:

```go
tracker.Store = myStore
```

### Implementation contract

- `Update` **must not** return the full membership of a large swarm. Honor
  `CandidateLimit`, and prefer a cheap random or partial sample over a full scan. Set
  `Truncated` when members were left out. This is what keeps a Redis- or SQL-backed store
  viable at swarm sizes where a full fetch per announce would not be. The tracker derives
  `CandidateLimit` from the request's `numwant`, `MaxPeersPerAnnounce`, and an oversampling
  factor, so a `Selector` has more candidates to discriminate between than it will
  ultimately return.
- `Extra` is **opaque**. Persist and return the bytes unchanged; never parse them or
  reject a membership because of their shape. Validation already happened in
  [`Metadata`](#metadata), and only the application knows the schema.
- `Scrape` **omits the key** for an unknown info hash rather than returning zero-valued
  stats, so callers can distinguish "empty swarm" from "never seen".
- `DeleteSession` removes every membership held by a session across all swarms, so the
  store needs an index from `SessionID` to memberships — not only the per-swarm index
  that `Update` and `Scrape` use.
- `Expire` is called periodically by the tracker with `now - PeerTTL`. A backend with
  native expiry (Redis `EXPIRE`, a TTL index) may implement it as a no-op returning
  `0, nil`. Without it, memberships left behind by a crashed instance are never reclaimed.
- `MembershipUpdate.Now` and the `olderThan` passed to `Expire` come from the tracker's
  clock. Instances of a fleet do not share one, so a store that compares them against
  timestamps written by another instance inherits that skew; a backend with native expiry
  should prefer its own clock.
- Return backend failures as ordinary errors. The tracker wraps them — see
  [backend failures](protocol.md#backend-failures) — and does not retry on your behalf.
  Apply your own timeouts: the tracker adds no deadline of its own to the context.
- All methods must be safe for concurrent use.

There is no `Close`. The application opens the connection, hands the store to the
tracker, and closes the connection when it is done — SwarmMux never owns it. A store may
be backed by process memory, Redis, SQL, a distributed key/value store, or a
service-specific membership backend.

Validate your implementation with
[`trackertest.RunStoreConformance`](testing.md#contract-tests-for-adapters).

## Router

The router delivers signaling messages to live peers. It is what makes a tracker fleet
work as one tracker.

```go
type Router interface {
    // Bind claims (ih, pid) for a session on this instance and refreshes the
    // binding's expiry. It returns the session that holds the pair afterwards:
    // sid on a successful claim or a refresh, and the existing holder — left
    // untouched — when a different session already owns it.
    Bind(ctx context.Context, ih InfoHash, pid PeerID, sid SessionID) (holder SessionID, err error)

    // Unbind removes every binding for a session.
    Unbind(ctx context.Context, sid SessionID) error

    // Route delivers msg to the given peer, wherever it is connected.
    // It returns ErrPeerNotFound if the peer is not currently bound.
    Route(ctx context.Context, ih InfoHash, to PeerID, msg protocol.Message) error

    // Deliver registers the callback used to hand messages that arrived from a
    // remote instance to a local session. The tracker calls it once at startup.
    Deliver(fn func(SessionID, protocol.Message))

    // Close stops the goroutines and subscriptions the router started.
    // The tracker calls it once, during Shutdown.
    Close(ctx context.Context) error
}
```

The default router is in-memory and single-process. It requires no configuration and is
the right choice until you run more than one tracker instance.

To scale out, replace it:

```go
tracker.Router = redisrouter.New(rdb) // companion module
```

A distributed router routes locally when the target session is on this instance, and
publishes to the owning instance otherwise. The receiving instance passes the message to
the callback it received from `Deliver`.

### Implementation contract

- `Bind` **must be atomic**: claiming a free pair and reporting the current holder is one
  compare-and-set, so two instances racing on the same `(InfoHash, PeerID)` cannot both
  see it as free. This is what makes `ErrPeerIDConflict` hold across a fleet rather than
  only within one process — see
  [peer identity](protocol.md#peer-identity-and-reconnection).
- `Bind` **never replaces** a binding held by a different session. Report the holder and
  leave it alone; the tracker rejects the claimant. A router that overwrote the binding
  would hand an attacker the answers meant for the peer they targeted.
- The tracker calls `Bind` on **every** announce for the swarm, not only the first. The
  first call claims the pair; later calls from the holding session refresh it.
- **Bindings must expire.** Give them a TTL of at least `PeerTTL` and let each `Bind`
  refresh it. Without expiry, an instance that crashes without unbinding strands every
  `peer_id` it held, and those peers can never reconnect.
- `Route` returns `ErrPeerNotFound` when the peer is unknown or has disconnected. The
  tracker surfaces that to the sender as a WebTorrent failure rather than closing the
  connection — peers disappearing mid-signaling is normal.
- `Route` must not block indefinitely; honor the context deadline. Other backend failures
  come back as ordinary errors — see [backend failures](protocol.md#backend-failures).
- `Deliver` is called exactly once, before any `Bind`.
- `Close` is called once, after every session has been unbound and every handler has
  returned. It is idempotent, and it must not close a connection the application owns —
  the Redis client passed to the constructor stays the application's to close. `Route`
  returns `ErrShutdown` afterwards.

The Redis Pub/Sub router lives in a companion module, so embedding SwarmMux never pulls in
a backend you do not use — see
[attaching your own infrastructure](adapters.md). Validate any implementation with
[`trackertest.RunRouterConformance`](testing.md#contract-tests-for-adapters).

## Observer

`Observer` connects SwarmMux to your metrics or tracing stack.

```go
type Observer interface {
    Observe(context.Context, ObserverEvent)
}

type ObserverFunc func(context.Context, ObserverEvent)

type ObserverEventKind uint8

type ObserverEvent struct {
    Kind      ObserverEventKind
    SessionID SessionID
    InfoHash  InfoHash
    PeerID    PeerID
    Event     AnnounceEvent
    Duration  time.Duration
    Count     int
    Err       error
}
```

A single method with an extensible event struct is deliberate: new signals can be added
without breaking every implementation.

Emitted kinds cover session open and close, announces by event type, offer and answer
routing outcomes, selected peer counts, expired and disconnected peers, rejected protocol
messages, outbound queue saturation, and store and router latency.

**`Observe` is called synchronously on the hot path and must not block.** Do buffered or
asynchronous work inside your implementation, not on the caller's goroutine. The default
observer is a no-op.
