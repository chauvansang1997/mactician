# Telemetry and privacy

Mactician has minimized basic events, an anonymous duration-only summary for
every completed session, and separately consented extended diagnostics. Event
JSON has no stable installation or user identifier. The server retains transport
source IPs for eligible first-session and snapshot events for 365 days, so those
events are not unlinkable end-to-end. It does not retain the transport source IP
or raw payload for session summaries. The minimized payload reduces privacy risk
but does not by itself determine consent requirements in every jurisdiction.

## Basic first-session event

After the first session that reached the runtime `ready` state has ended,
Mactician sends `first_game_session` once per retained macOS preferences domain:

```json
{
  "schema_version": 2,
  "event_id": "random-uuid",
  "event": "first_game_session",
  "occurred_on": "2026-08-09",
  "duration_bucket": "30_60m",
  "launcher_version": "1.0.0",
  "launcher_build": "33"
}
```

Allowed buckets are `under_5m`, `5_15m`, `15_30m`, `30_60m`, `60_120m`,
`120_240m`, and `over_240m`. The event does not contain an installation or
device identifier, exact duration/time, device properties, launcher settings,
language, identity, logs, or network addresses.

The pending event is written to `telemetry.firstSession.pending.v2` before the
request. A retry reuses its original `event_id`. HTTP 2xx or a duplicate
acknowledgement completes it; 408, 429, 5xx, and network failures retain it. An
unrecoverable 4xx is terminal. A pending event older than seven days is deleted
without replacement. Resetting Android/TFT data does not change this state.

The server aggregates the event immediately by received date, launcher
version/build, and duration bucket. The dashboard name is **Approximate
activated installations**. It is approximate because macOS accounts can count
separately, clearing preferences or reinstalling can count again, installs with
no completed session are absent, and an event can expire during extended
offline use. It must not be labelled `unique_users`, `people`, or `MAU`.

## One-time activation snapshot

The launcher version that introduces the fresh census creates
`activation_snapshot` once for `snapshot_version` 1 per retained macOS
preferences domain. A known `granted` or `denied` choice is captured on launcher
startup. While consent is `unknown`, no snapshot is created; it is created
immediately after the user chooses:

```json
{
  "schema_version": 2,
  "event_id": "random-uuid",
  "event": "activation_snapshot",
  "snapshot_version": 1,
  "diagnostics_consent_state": "denied",
  "diagnostics_consent_version": 1,
  "launcher_version": "1.1.0",
  "launcher_build": "45"
}
```

The event is independent of Extended Diagnostics consent and is sent for either
explicit choice because it has no game-session data, duration, settings, device
properties, or stable installation identifier. It is persisted at
`telemetry.activationSnapshot.pending.v1` before delivery. Every retry reuses
the entire payload and `event_id`; every non-2xx leaves it pending. Only a 2xx
response sets `telemetry.activationSnapshot.completed.v1`. Both keys are tied
to snapshot version 1 and do not reuse first-session state.

The server reports it after the persisted UTC backend-deployment cutoff as a
separate fresh cumulative series and does not merge it with the earlier,
known-undercounted first-session series. It counts `granted`, `denied`, and any
unexpected `unknown` explicitly. Consent and refusal rates use only
`granted + denied`; missing `game_session_diagnostics` events are never treated
as refusal. The result is not a unique-person count: clearing preferences or
using another macOS account can count again, while launchers that are not
updated and run are absent.

## Anonymous game-session summary

After every completed session, Mactician creates `game_session_summary`
regardless of the Extended Diagnostics choice:

```json
{
  "schema_version": 2,
  "event_id": "random-uuid",
  "event": "game_session_summary",
  "duration_seconds": 2871,
  "launcher_version": "1.1.2",
  "launcher_build": "47"
}
```

The event contains no installation or user identifier, calendar day, exact
start or completion time, device properties, launcher settings, language,
account information, or logs. Every session receives a fresh random event UUID,
so separate summaries cannot be joined into an installation history by payload.
The local queue retains at most 64 undelivered summaries. Temporary failures
retain a summary with the same UUID; HTTP 2xx, duplicate acknowledgement, or an
unrecoverable 4xx removes it.

The server assigns the received UTC day and immediately increments only daily
session count and duration totals grouped by launcher version/build. It stores
neither the raw payload nor the summary's transport source IP. A SHA-256 event-ID
hash is retained with these aggregates for 730 days to keep delayed retries
idempotent. These totals measure aggregate adoption and play time, not unique
users, installations, or per-user engagement.

## Optional extended diagnostics

Extended diagnostics are created and sent only when
`telemetry.extendedConsent.state.v1` is `granted` for consent version 1.
`unknown` and `denied` both prohibit creation and transmission.

Each completed session then sends an independent event:

```json
{
  "schema_version": 2,
  "event_id": "random-uuid",
  "event": "game_session_diagnostics",
  "occurred_at": "2026-08-09T12:34:56Z",
  "duration_seconds": 2871,
  "launcher_version": "1.0.0",
  "launcher_build": "33",
  "consent_version": 1,
  "launcher_settings": {
    "profile_id": "quality",
    "effects_quality_id": "performance",
    "display_width": 2560,
    "display_height": 1440,
    "display_density": 416,
    "ui_scale_percent": 100,
    "guest_memory_mb": 8192,
    "guest_cpu_cores": 6
  },
  "device": {
    "model_identifier": "Mac16,1",
    "macos_version": "26.0.0",
    "physical_memory_mb": 32768,
    "logical_cpu_count": 10
  }
}
```

It never contains an installation ID, Mac name, serial number, MAC address,
Apple ID, macOS username, Riot ID, IP field, application list, or game logs.
Turning diagnostics off immediately stops event creation and deletes the entire
local diagnostic queue; it does not affect pending basic events or anonymous
session summaries. A change to
the diagnostic field set increments `consent_version` and invalidates prior
consent.

## Server retention and processing

The API strictly rejects unknown fields and out-of-range values, bounds request
size, and deduplicates by `event_id`. It retains normalized source IP records
for eligible first-session and snapshot events for 365 days, does not retain
them for session summaries, does not persist User-Agent headers, and never logs
an invalid request body.

Basic payloads and session summaries are not retained as raw events.
First-session event-ID hashes expire after 14 days. Snapshot and summary hashes
and aggregates are retained for 730 days so delayed delivery of one event ID
remains idempotent. Eligible source IP records are retained separately for 365
days only for rate limiting and abuse investigation; they are never used to
identify, deduplicate, or count installations. Raw
extended diagnostic events are retained for 365 days. Longer-lived diagnostic
aggregates must avoid small identifiable cohorts.

The release order is server compatibility, schema-v2 verification, public
privacy-policy publication, then the launcher update. No legacy event contract
is retained because the previous API and its data belonged only to the local
pre-release laboratory.
