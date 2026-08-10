# Testing

The `trackertest` package targets developers building tracker services with SwarmMux, and
authors of `Store` and `Router` adapters.

- [Tracker conformance](#tracker-conformance)
- [Contract tests for adapters](#contract-tests-for-adapters)
- [WebSocket integration tests](#websocket-integration-tests)

## Tracker conformance

```go
package mytracker_test

import (
    "testing"

    "github.com/GyeongHoKim/swarmmux"
    "github.com/GyeongHoKim/swarmmux/trackertest"
)

func TestTrackerConformance(t *testing.T) {
    var tracker swarmmux.Tracker
    trackertest.RunConformance(t, &tracker)
}
```

The suite verifies announce lifecycle events, offer and answer routing, scrape statistics,
multiple swarms over one connection, disconnect cleanup, malformed messages, binary
identifier edge cases, peer expiration, `peer_id` conflict handling, backpressure
behavior, and that a failing `Store` or `Router` surfaces as `ErrBackend` without
dropping the connection.

> **Scope of the suite.** `RunConformance` asserts *default* engine behavior. It assumes a
> `Selector` that returns every eligible candidate and an `Authorizer` that permits every
> join. A tracker configured with a restrictive selector or authorizer will fail some
> cases legitimately. Run the suite against a tracker whose `Store`, `Router`, `Metadata`,
> and `Observer` are yours, but whose selection and authorization are left at their
> defaults.

## Contract tests for adapters

If you implement [`Store`](extension-points.md#store) or
[`Router`](extension-points.md#router) — including in a companion module — these suites
check the contracts documented for each interface:

```go
func TestRedisStore(t *testing.T) {
    trackertest.RunStoreConformance(t, func() swarmmux.Store {
        return redisstore.New(newTestRedis(t))
    })
}

func TestRedisRouter(t *testing.T) {
    trackertest.RunRouterConformance(t, func() swarmmux.Router {
        return redisrouter.New(newTestRedis(t))
    })
}
```

`RunStoreConformance` covers the `CandidateLimit` and `Truncated` bounds, `Scrape` omitting
unknown info hashes, `DeleteSession` clearing memberships across every swarm a session
joined, and `Extra` surviving a write and read back byte for byte.

`RunRouterConformance` exercises multi-instance behavior by constructing several routers
against the same backend and asserting cross-instance delivery. It also checks the
identity contract that `ErrPeerIDConflict` rests on: concurrent `Bind` calls for one
`(InfoHash, PeerID)` from different sessions leave exactly one holder and report it to
the loser, a released binding becomes claimable again, and `Close` stops the router's
goroutines without touching the caller's connection.

## WebSocket integration tests

```go
func TestWebTorrentClient(t *testing.T) {
    var tracker swarmmux.Tracker

    server := trackertest.NewServer(t, &tracker)
    t.Cleanup(server.Close)

    trackerURL := server.WebSocketURL()

    // Connect a WebTorrent-compatible client to trackerURL.
    _ = trackerURL
}
```

Interoperability tests should also run against the official
`webtorrent/bittorrent-tracker` implementation.
