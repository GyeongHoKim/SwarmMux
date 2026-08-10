# SwarmMux development commands.
#
# Cross-platform rules for anyone editing this file:
#   * just runs each recipe LINE in its own shell, so never chain with `&&`
#     (Windows PowerShell 5.1 does not support it).
#   * Recipe bodies call `go`, `golangci-lint`, `gotestsum`, `git`, or `npm`
#     only. Anything needing `rm`/`mkdir` gets a [unix] and a [windows] copy.

[unix]
set shell := ["bash", "-euo", "pipefail", "-c"]

[windows]
set shell := ["powershell.exe", "-NoLogo", "-NoProfile", "-Command"]

# List available recipes.
default:
    @just --list --unsorted

# Install pinned tools, npm dev dependencies, and git hooks.
[group('setup')]
setup:
    mise install
    npm ci
    lefthook install

# Install the git hooks only.
[group('setup')]
hooks:
    lefthook install

# Compile every package.
[group('build')]
build:
    go build ./...

# Run the test suite.
[group('test')]
test:
    gotestsum --format pkgname -- ./...

# Run tests under the race detector with randomized test order.
[group('test')]
test-race:
    go test -race -shuffle=on ./...

# Run only the protocol conformance suites.
[group('test')]
conformance:
    go test -run Conformance -v ./...

# Produce coverage.out.
[group('test')]
cover:
    go test -coverprofile=coverage.out -covermode=atomic ./...
    go tool cover -func=coverage.out

# Render coverage.out to coverage.html.
[group('test')]
cover-html: cover
    go tool cover -html=coverage.out -o coverage.html

# Report lint findings.
[group('check')]
lint:
    golangci-lint run

# Apply the lint fixes that are safe to automate.
[group('check')]
lint-fix:
    golangci-lint run --fix

# Validate .golangci.yml against the v2 schema.
[group('check')]
lint-config:
    golangci-lint config verify

# Format all Go sources.
[group('check')]
format:
    golangci-lint fmt

# Fail if anything is unformatted; prints the diff.
[group('check')]
format-check:
    golangci-lint fmt --diff

# Run go vet.
[group('check')]
vet:
    go vet ./...

# Tidy go.mod and go.sum.
[group('check')]
tidy:
    go mod tidy

# Fail if go.mod or go.sum is not tidy.
[group('check')]
tidy-check: tidy
    git diff --exit-code -- go.mod go.sum

# Everything CI runs, in the same order.
[group('check')]
ci: format-check lint-config lint tidy-check build test test-race

# Remove build and coverage artifacts.
[unix]
[group('setup')]
clean:
    rm -f coverage.out coverage.html
    go clean -testcache

# Remove build and coverage artifacts.
[windows]
[group('setup')]
clean:
    Remove-Item -Force -ErrorAction SilentlyContinue coverage.out, coverage.html
    go clean -testcache
