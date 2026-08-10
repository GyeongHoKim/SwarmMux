# Attaching your own infrastructure

SwarmMux never opens a database, cache, or broker connection. You construct the client,
hand it to the tracker, and close it yourself.

This page covers the wiring and the lifecycle. For the interfaces themselves, see
[extension points](extension-points.md).

- [The wiring](#the-wiring)
- [Who owns what](#who-owns-what)
- [Shutdown order](#shutdown-order)
- [Why Redis](#why-redis)
- [Splitting Store and Router](#splitting-store-and-router)
- [Writing your own adapter](#writing-your-own-adapter)

## The wiring

```go
rdb := redis.NewClient(&redis.Options{Addr: os.Getenv("REDIS_ADDR")})

var tracker swarmmux.Tracker
tracker.Store = redisstore.New(rdb)     // companion module
tracker.Router = redisrouter.New(rdb)   // companion module
tracker.PeerTTL = 5 * time.Minute

mux := http.NewServeMux()
mux.Handle("GET /announce", swarmws.NewHandler(&tracker))

server := &http.Server{
    Addr:              ":8080",
    Handler:           mux,
    ReadHeaderTimeout: 5 * time.Second,
}
```

An adapter takes an **already-constructed client**, not a DSN string. Your pool size,
timeouts, TLS settings, cluster or failover configuration, and any tracing middleware you
have wrapped around that client are what the tracker uses. Nothing is configured twice,
and there is no second connection pool you did not ask for.

Adapters live in a separate module with its own `go.mod`, so you `go get` it only if you
need it. An application on the in-memory defaults never builds a Redis client.

## Who owns what

| | Created by | Closed by |
|---|---|---|
| Redis or other backend client | your code | your code, after `Tracker.Shutdown` returns |
| [`Store`](extension-points.md#store) | your code, from the client | nothing — it holds no resources of its own |
| [`Router`](extension-points.md#router) | your code, from the client | `Tracker.Shutdown`, through `Router.Close` |
| [`Session`](architecture.md#session) | the `ws` handler | the `ws` handler, or `Tracker.Shutdown` |
| `http.Server` | your code | your code |

`Router.Close` stops the goroutines and subscriptions the router itself started. It does
**not** close the client you passed in — that one is yours, and other parts of your
application are probably still using it.

## Shutdown order

```go
ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
defer cancel()

if err := server.Shutdown(ctx); err != nil {   // 1. no new upgrades
    log.Printf("HTTP shutdown: %v", err)
}

if err := tracker.Shutdown(ctx); err != nil {  // 2. drain sessions, then Router.Close
    log.Printf("tracker shutdown: %v", err)
}

rdb.Close()                                    // 3. your clients, last
```

Closing a client before `Tracker.Shutdown` returns pulls the connection out from under a
router that is still unbinding sessions, or a store still writing a final `stopped`
event. The full engine sequence is in
[graceful shutdown](architecture.md#graceful-shutdown).

## Why Redis

Redis is the one backend SwarmMux ships an adapter for, because a single server satisfies
both interfaces:

- **Bounded sampling.** `Update` has to return a sample without scanning the swarm. Redis
  samples a set in time proportional to the sample, not to the membership; the same query
  in SQL is a full scan or a sampling extension.
- **Expiry.** `Expire` maps onto a range delete over a `LastSeen` index, so reclaiming
  memberships a crashed instance left behind is one command rather than a sweep.
- **Atomic claim.** `Bind` needs a compare-and-set that also reports the current holder.
  That is one short Lua script — and it is what keeps
  [`ErrPeerIDConflict`](protocol.md#peer-identity-and-reconnection) meaningful across a
  fleet instead of within one process.
- **Fan-out.** `Route` has to reach whichever instance holds a session. Pub/Sub does that
  with no separate broker to operate.

One caveat: Redis Pub/Sub is at-most-once. A message published while a subscriber is
reconnecting is lost, and `Route` cannot detect it — it reports success once the peer is
bound. For signaling that is an acceptable trade, because a lost offer costs one failed
WebRTC attempt and the client retries on its next announce. If you need delivery
guarantees, implement `Router` over a stream instead.

## Splitting Store and Router

`Store` and `Router` are independent, and nothing requires them to share a backend. A
team already running Postgres might keep membership there — durable, queryable, joinable
against the rest of their data — and use Redis only for routing, where low-latency
delivery is the whole job and Postgres `LISTEN`/`NOTIFY` is a poor fit.

That is a normal configuration, not a workaround. Write the store, keep the shipped
router. See
[Store and Router are different things](architecture.md#store-and-router-are-different-things).

A single-instance tracker needs neither: the defaults are in-memory.

## Writing your own adapter

Redis and the in-memory defaults are what SwarmMux ships. Anything else — Postgres,
DynamoDB, NATS, an internal membership service — you write, and the SDK is built on the
assumption that you will. `Store` is four methods and `Router` is five, so an adapter is a
small file rather than a subsystem, and unlike most plugin models the contract is
executable:

```go
func TestMyStore(t *testing.T) {
    trackertest.RunStoreConformance(t, func() swarmmux.Store {
        return mystore.New(newTestBackend(t))
    })
}
```

The suites check the parts that are easy to get subtly wrong — `CandidateLimit` bounds,
`Scrape` omitting unknown info hashes, `DeleteSession` reaching every swarm, and the
atomic `Bind` that [peer identity](protocol.md#peer-identity-and-reconnection) rests on.
Read the implementation contract for
[`Store`](extension-points.md#store) or [`Router`](extension-points.md#router) first; the
suite reports violations, but the contract explains them.

SwarmMux is pre-1.0 and the engine is still being built. `Store` and `Router` will change
as the implementation turns up what the specification got wrong, so expect an adapter to
need updating between releases until the interfaces settle.
