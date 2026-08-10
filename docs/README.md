# SwarmMux documentation

Start with the [project README](../README.md) for the pitch, installation, and a working
tracker in ten lines. These documents cover everything past that point.

| Document | Read it when you want to |
|---|---|
| [Architecture](architecture.md) | understand `Tracker`, `Handler`, `Session`, the `Store`/`Router` split, context propagation, and shutdown |
| [Extension points](extension-points.md) | implement `Authorizer`, `Metadata`, `Selector`, `Store`, `Router`, or `Observer` |
| [Attaching infrastructure](adapters.md) | wire the Redis adapter or your own backend behind `Store` and `Router`, and know who closes what |
| [WebSocket transport](transport.md) | tune the `ws` handler, set origin policy and backpressure, or add tracker middleware |
| [Protocol behavior](protocol.md) | know what clients see: compatibility, failure responses, peer identity |
| [Security](security.md) | harden a deployment that faces the Internet |
| [Testing](testing.md) | run the conformance suites for a tracker, store, or router |

Package-level API reference lives on
[pkg.go.dev](https://pkg.go.dev/github.com/GyeongHoKim/swarmmux).
