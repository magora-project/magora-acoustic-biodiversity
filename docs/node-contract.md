# Magora Node Contract

This document describes the behavior implemented by the current `firmware/detect.py` on the promoted Raspberry Pi node. It is a contract derived from the running firmware, not a redesign and not a commitment to add behavior to new node types.

## Scope and source

- Contract source: `firmware/detect.py` from the pinned node firmware release.
- Capture implementation: ALSA `arecord` writes a temporary WAV, BirdNET analyzes it, and the temporary WAV is deleted in the `finally` block after each cycle.
- The node is provisioned from `magora-config.json`; the first-run script stores the credential and location fields in protected files on the node.

## Provisioning configuration

`magora-config.json` currently supplies these fields:

| Field | Current use |
| --- | --- |
| `node_id` | Node identity included in Supabase rows. |
| `node_name` | Display name and location label. |
| `node_email` | Per-node Supabase account email. |
| `node_password` | Per-node Supabase account password. |
| `supabase_url` | Supabase project URL written to the node environment. `detect.py` itself has the production URL hard-coded. |
| `supabase_anon_key` | Public API key used for REST requests and GoTrue sign-in. |
| `lat` / `lon` | Numeric place coordinates used in detections and temporal calculations. |
| `wifi_ssid`, `wifi_password`, `wifi_country` | Node network setup. |
| `ssh_password` | Optional SSH password for the Pi; absent means the Pi account stays locked. |

`detect.py` reads `SUPABASE_ANON_KEY`, `NODE_EMAIL`, `NODE_PASSWORD`, and `NODE_ID` from `/home/magora/secrets.env`. Location data comes from `/home/magora/location.json`. Do not copy credentials into application source or repository data.

## Authentication

At startup, `detect.py` signs in as the node's own GoTrue user:

```text
POST {SUPABASE_URL}/auth/v1/token?grant_type=password
apikey: SUPABASE_ANON_KEY
email: NODE_EMAIL
password: NODE_PASSWORD
```

The response access token is retained in memory and used for REST writes. If a write returns HTTP 401, `detect.py` signs in again and retries that write once. The whitelist lookup uses the anon key because it only reads `nodes`; the ACI and detection writes use the node JWT.

A new node type must authenticate as its own per-node user. It must not ship the service role key, provisioning secret, or shared credentials.

## Capture and inference

Every capture cycle is independent:

- Target duration: 15 seconds.
- USB/generic microphones are converted by ALSA to mono, 48 kHz, 16-bit PCM (`S16_LE`).
- The existing I2S ADAU7002 path captures two channels, native 32-bit, at 48 kHz; `detect.py` selects one live channel for ACI.
- BirdNET minimum confidence: `0.25`.
- BirdNET sensitivity: `1.25`.
- BirdNET overlap: `1.5` seconds.
- Temporary WAVs are deleted on timeout, capture failure, and after successful analysis.

The running implementation uses `birdnetlib==0.18.1`, `Analyzer()`, and `Recording(...)`; the image verifies that this environment loads the BirdNET model. Repository docs should not infer a different semantic model-release label from package versions alone. The runtime package and image environment are the pinned provenance of the current implementation.

## Supabase row contract

### Detection

Each eligible BirdNET detection is posted to the REST endpoint `POST /rest/v1/detections` using the node JWT.

```json
{
  "node_id": "<node UUID>",
  "species_name": "<common name>",
  "raw_label": "<scientific name>",
  "confidence": 0.95,
  "detected_at": "<ISO 8601 UTC timestamp>",
  "location": "POINT(<longitude> <latitude>)",
  "is_dawn_chorus": true,
  "minutes_from_sunrise": 42,
  "dawn_chorus_window": true,
  "phenological_week": 25,
  "season": "breeding"
}
```

Relevant schema column names are exactly:

- `node_id`
- `species_name`
- `raw_label`
- `confidence`
- `detected_at`
- `location`
- `is_dawn_chorus`
- `minutes_from_sunrise`
- `dawn_chorus_window`
- `phenological_week`
- `season`

The HTTP request is made with JSON content, `apikey`, `Authorization: Bearer <node JWT>`, and `Prefer: return=minimal`. `aci` and time category are used locally in output but are not columns in the detection payload sent by `detect.py`.

### ACI

Each cycle with a valid ACI score is posted to `POST /rest/v1/aci_logs` using the node JWT.

```json
{
  "node_id": "<node UUID>",
  "recorded_at": "<ISO 8601 UTC timestamp>",
  "aci_score": 0.1234,
  "time_category": "Morning",
  "dawn_chorus": true,
  "duration_secs": 15
}
```

Relevant schema column names are exactly:

- `node_id`
- `recorded_at`
- `aci_score`
- `time_category`
- `dawn_chorus`
- `duration_secs`

ACI rows are written every processed 15-second cycle when a valid score is calculated. They are the production heartbeat source used to derive node status; direct writes by `detect.py` do not update `nodes.last_seen_at`. That value is refreshed by the server-side node-status heartbeat process when it evaluates recent `aci_logs`.

As a production finding, Blue Bird Ranch reported stale `last_seen_at` on 2026-11-03. This contract records the known stale-display finding but does not prescribe or implement a fix here.

## Species whitelist

Before listening, `detect.py` fetches:

```text
GET /rest/v1/nodes?id=eq.<node_id>&select=species_whitelist
```

using the public anon key and authorization header. The response is read from the first matching node row.

- A non-empty `species_whitelist` array becomes the allowed species set; matching is case-insensitive.
- A null, missing, or empty array means no whitelist is loaded.
- The whitelist is cached at `/home/magora/species_whitelist.json`.
- If Supabase is unavailable, the node retries up to six times and then uses the cached file if present.
- If no usable value or cache exists, it runs without species filtering.

A detection is submitted only when:

1. It is not excluded by the fixed non-bird list or insects; and
2. Its common name is on the whitelist, or the whitelist is absent; or
3. It is not on the whitelist but confidence is at least `0.70`, in which case the node prints `UNUSUAL` and permits it.

Applying the per-node whitelist is **current firmware behavior**, but it is not an ingest contract required of every new node type. In particular, a new implementation must not assume that Supabase or a whitelist is available until its own contract work explicitly declares it. New nodes should document whether they implement the whitelist and the range-validity gate separately from ingestion.

## Legacy Sheets mirror

`SHEETS_WEBHOOK_URL` is a legacy optional mirror for personal dashboards.

- It defaults to unset.
- When set, ACI and Bird detections are posted as separate JSON objects to that URL.
- Detection and ACI retry behavior for this mirror uses local JSON queues.
- The endpoint is considered unauthenticated and unsafe to publish as a node default; the source warning explicitly says public builds must never ship a hard-coded URL.
- It is not part of the Supabase ingest contract.
- New node types must **not** implement or depend on the Sheets mirror.

## Retry queues and ordering

`detect.py` has two legacy mirror queues only:

- Detections: `/home/magora/retry_queue.json`
- ACI: `/home/magora/aci_queue.json`

Queues contain legacy mirror payload objects, not Supabase detection or ACI rows. Supabase writes are attempted immediately and are not queued by the detection loop.

Within each queue, new items are appended and files are rewritten as JSON arrays. The legacy flush logic loads the queue, walks items in array order, and preserves items whose POST fails. Successful older items are removed before later failures, so remaining items stay in original order.

The current loop processes queues as follows at the end of a capture cycle:

1. Flush detection legacy mirror items.
2. Flush ACI legacy mirror items.

These separate queues do **not** provide cross-table ordering, exactly-once delivery, or a retry for failed Supabase writes. A network error queueing the Sheets mirror does not add those rows to the Supabase path. For new Android or other queued-ingest implementations, offline ordering must be specified separately and should not claim parity with this legacy queue behavior.

## Fixed filters

Before posting a detection, `detect.py` excludes:

- Human vocalization, human non-vocalization, and human whistling.
- Crowd, dog, cat, engine, siren, power tools, gun, fireworks, hand saw, chainsaw, car, truck, motorcycle.
- Laysan Albatross and Black-footed Albatross, as known raven-confusion exclusions.
- Katydid, cricket, grasshopper, and cicada common names.

These filters are behavior specific to the current Pi firmware, not additional database constraints.

## Out of contract

The current detector does not:

- write heartbeat status through its own REST request;
- write audio files to Supabase;
- write node location updates on each cycle;
- write battery, temperature, GPS, barometer, accelerometer, or other sensor data;
- upload camera or person data;
- implement new schema fields for capture chain or environment data;
- persist Supabase detection/ACI rows through the legacy queue files described above.
