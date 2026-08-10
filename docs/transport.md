# WebSocket transport and middleware

Standard WebTorrent clients talk to trackers over WebSocket. The `ws` package provides
that transport; the `Handler` interface lets you wrap tracker behavior around it.

- [The `ws` package](#the-ws-package)
- [Origin policy](#origin-policy)
- [Backpressure](#backpressure)
- [Tracker middleware](#tracker-middleware)
- [Rate limiting](#rate-limiting)

## The ws package

```go
handler := swarmws.NewHandler(
    &tracker,
    swarmws.WithOriginCheck(func(r *http.Request) bool {
        return r.Header.Get("Origin") == "https://player.example.com"
    }),
    swarmws.WithReadLimit(64<<10),
    swarmws.WithWriteTimeout(10*time.Second),
    swarmws.WithSendQueueSize(256),
    swarmws.WithOverflowPolicy(swarmws.CloseSession),
)

mux.Handle("GET /announce", handler)
```

The `ws` package owns the HTTP upgrade, `Session` creation, message framing and
serialization, connection lifecycle, write serialization, queue bounds and backpressure,
and transport-level limits. The `Tracker` owns tracker protocol and swarm behavior.

## Origin policy

**By default, cross-origin upgrades are rejected.** Only requests whose `Origin` matches
the request host — and requests with no `Origin` header, such as non-browser clients — are
accepted. Browser WebTorrent clients served from a different domain will fail to connect
until you supply `WithOriginCheck`.

This default is deliberate: a tracker with an open origin policy lets any web page drive
signaling through your service.

## Backpressure

Each session has a bounded outbound queue. When a peer cannot keep up and the queue fills,
`WithOverflowPolicy` decides what happens:

```go
type OverflowPolicy int

const (
    // CloseSession terminates the connection with ErrQueueFull. Default.
    CloseSession OverflowPolicy = iota

    // DropMessage discards the oldest queued message and continues.
    DropMessage
)
```

The default is `CloseSession` because signaling messages are not interchangeable. Silently
dropping an offer or answer produces a WebRTC connection that fails for no visible reason;
closing the session gives the client a clear, retryable signal.

Use `DropMessage` only if you have decided that stale signaling is better than
disconnection for your workload, and watch the corresponding
[observer](extension-points.md#observer) events.

## Tracker middleware

Because tracker sessions are represented by [`Handler`](architecture.md#handler),
application code can wrap tracker behavior without tying the core engine to HTTP
middleware.

```go
func logSessions(logger *slog.Logger, next swarmmux.Handler) swarmmux.Handler {
    return swarmmux.HandlerFunc(
        func(ctx context.Context, session swarmmux.Session) error {
            started := time.Now()
            err := next.ServeTracker(ctx, session)

            logger.InfoContext(ctx, "tracker session closed",
                "session_id", session.ID(),
                "remote_addr", session.RemoteAddr(),
                "duration", time.Since(started),
                "error", err,
            )

            return err
        },
    )
}

handler := swarmws.NewHandler(logSessions(logger, &tracker))
```

## Rate limiting

`Session` is an interface, so middleware can wrap it and intercept messages. This is the
supported way to apply per-connection, per-identity, or per-swarm rate limits — HTTP
middleware only sees the upgrade, not the thousands of messages that follow it.

```go
type limitedSession struct {
    swarmmux.Session
    limiter *rate.Limiter
}

func (s limitedSession) Receive(ctx context.Context) (protocol.Message, error) {
    if !s.limiter.Allow() {
        return protocol.Message{}, swarmmux.ErrRateLimited
    }
    return s.Session.Receive(ctx)
}

func rateLimit(n rate.Limit, burst int, next swarmmux.Handler) swarmmux.Handler {
    return swarmmux.HandlerFunc(
        func(ctx context.Context, session swarmmux.Session) error {
            return next.ServeTracker(ctx, limitedSession{
                Session: session,
                limiter: rate.NewLimiter(n, burst),
            })
        },
    )
}
```

Returning `ErrRateLimited` from `Receive` produces a failure response without closing the
connection. Return a different error, or call `session.Close`, to hang up instead.

HTTP middleware remains the natural place for upgrade authentication, request IDs, origin
policy, connection-count limits, and HTTP access logging.
