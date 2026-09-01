# Telemetry schema v2 contract

These JSON files are the canonical public wire examples for Mactician telemetry,
including the legacy first-session event, the fresh activation snapshot, the
anonymous per-session summary, and consented extended diagnostics.
The Swift tests verify the encoded key sets and the private API repository keeps
byte-identical copies for its HTTP contract tests. Run
`scripts/verify-telemetry-contract.command` before a server or launcher release.

Schema v2 intentionally contains no installation identifier, account identity,
network address, host name, serial number, MAC address, or game logs. Unknown
fields are rejected by the server.
