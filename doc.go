// Package swarmmux is a Go SDK for running a WebTorrent tracker inside your own
// application.
//
// It implements the WebTorrent tracker protocol, WebSocket signaling, swarm
// membership, peer discovery, offer/answer routing, and scrape statistics, and
// exposes an extension point for every policy decision it leaves to the
// embedding application.
//
// The zero value of [Tracker] is a working tracker backed by in-memory storage
// and routing:
//
//	var tracker swarmmux.Tracker
//
//	mux := http.NewServeMux()
//	mux.Handle("GET /announce", swarmws.NewHandler(&tracker))
//
// SwarmMux is not a standalone tracker daemon. The application owns the HTTP
// server, deployment model, authentication, persistence, and observability.
//
// See the docs directory in the repository for the architecture overview,
// extension point contracts, transport tuning, protocol behavior, security
// considerations, and the conformance suites.
package swarmmux
