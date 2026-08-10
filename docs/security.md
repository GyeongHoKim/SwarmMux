# Security considerations

A public WebTorrent tracker is an Internet-facing signaling service. SwarmMux provides
mechanisms; you set the policy.

| Concern | Mechanism |
|---|---|
| Cross-origin abuse | [`WithOriginCheck`](transport.md#origin-policy) — cross-origin denied by default |
| Unauthorized swarm access | upgrade authentication + [`Authorizer`](extension-points.md#authorizer) |
| Answer hijacking | automatic [`peer_id` binding](protocol.md#peer-identity-and-reconnection), `ErrPeerIDConflict` |
| Oversized frames | `WithReadLimit` |
| Announce amplification | `MaxOffers`, `MaxPeersPerAnnounce` |
| Swarm-count exhaustion | `MaxSwarmsPerSession` |
| Message floods | [rate-limiting middleware](transport.md#rate-limiting) |
| Slow or stalled peers | [`WithSendQueueSize`, `WithOverflowPolicy`, `WithWriteTimeout`](transport.md#backpressure) |
| Stale membership | `PeerTTL` plus [`Store.Expire`](extension-points.md#store) |
| `peer_id` stranded by a crashed instance | binding TTL in the [`Router`](extension-points.md#router) |
| Unbounded extension data | [`Metadata`](extension-points.md#metadata) with strict decoding and size limits |
| High-cardinality swarm creation | `Authorizer`, plus connection limits in HTTP middleware |
| Blind spots | [`Observer`](extension-points.md#observer) events for rejections and saturation |

Connection-count and per-IP limits belong in HTTP middleware, before the upgrade
completes.

## Custom routers and peer identity

Answer hijacking is blocked by an atomic claim inside the
[`Router`](extension-points.md#router). A router that replaces a binding held by another
session, or that reads the holder in a separate round trip from the claim, downgrades that
protection to a per-instance best effort without any visible symptom. Validate a custom
router with [`trackertest.RunRouterConformance`](testing.md#contract-tests-for-adapters).

## Logging SDP

The tracker relays untrusted SDP payloads as opaque data. Do not log complete SDP bodies:
they may contain network topology information and substantially increase log volume.

## Reporting a vulnerability

Report security issues privately through
[GitHub security advisories](https://github.com/GyeongHoKim/swarmmux/security/advisories/new)
rather than a public issue.
