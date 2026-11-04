# Magora Node Contract

This document has two clearly separated views:

- **Deployed behavior** is the authoritative baseline derived from `detect.py` at commit `f0c1940acd7b35877e0af44a810fc3d2bc27ab9a`, which is pinned by `firmware/magora-firstrun.sh`.
- **Repository-head differences** describe how current `main` differs from that deployed commit. They are informational and must not be treated as behavior already running on provisioned nodes.

## Scope and source

- Contract source for nodes provisioned after it became the deployment pin: `firmware/detect.py` at `f0c1940acd7b35877e0af44a810fc3d2bc27ab9a`.
- Deployment pin: `DETECT_SHA=f0c1940acd7b35877e0af44a810fc3d2bc27ab9a` in `firmware/magora-firstrun.sh`.
- Capture implementation: ALSA `arecord` writes a temporary WAV, BirdNET analyzes it, and the temporary WAV is deleted in the `finally` block after each cycle.
- `magora-firstrun.sh` writes the node credentials to `/home/magora/secrets.env` with mode `0600`. It creates `/home/magora/location.json` without changing its permissions, so precise coordinates and the node name may remain readable under the service account's normal local umask.

## Deployed behavior differences from repository head

Current repository head `firmware/detect.py` differs from deployed commit `f0c1940acd7b35877e0af44a810fc3d2bc27ab9a` in these ways:

- Confidence floor, named `MIN_CONF`: deployed `0.20`; repository head `0.25`.
- Sheets mirror: deployed code has a hard-coded, always-used Google Apps Script URL. Repository head reads optional `SHEETS_WEBHOOK_URL` and defaults it to empty.
- Repository head adds guards so `post_data()` and queue flushing are no-ops when the optional Sheets URL is unset; deployed code has no such guards and assumes the hard-coded URL exists.
- These are the only `firmware/detect.py` differences between the deployed commit and repository head. They are limited to `MIN_CONF`, the Sheets configuration, and guarding that optional mirror. Authentication, row shapes, capture settings, species whitelist behavior, and queue mechanics described in this document remain shared unless explicitly listed above.

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

`detect.py` reads `SUPABASE_ANON_KEY`, `NODE_EMAIL`, `NODE_PASSWORD`, and `NODE_ID` from `/home/magora/secrets.env`. Location data comes from `/home/magora/location.json`. If that file is missing, malformed, or lacks a field, `get_location()` silently falls back to `43.4`, `-110.7`, and `"Jackson WY"` (`detect.py`). Those fallback coordinates are written into detection rows and supplied to the sunrise-derived fields, so a damaged location configuration can silently mis-geotag detections. Do not copy credentials into application source or repository data.

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
- BirdNET minimum confidence, named `MIN_CONF`: deployed `0.20`; repository head `0.25`.
- BirdNET sensitivity: `1.25`.
- BirdNET overlap: `1.5` seconds.
- Temporary WAVs are deleted on timeout, capture failure, and after successful analysis.

The running implementation uses `Analyzer()` and `Recording(...)`. Images built from commit `e565362d9ab5bdc99360bfbc4ef8e9b05e60521d` onward pin `birdnetlib==0.18.1` and verify model loading at image-build time. Repository docs should not infer a different semantic model-release label from package versions alone. Runtime versions on nodes provisioned from earlier images are unknown.

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

Each cycle with a valid ACI score is posted to `POST /rest/v1/aci_logs` using the node JWT. `calculate_aci()` rounds its result to three decimal places before posting it.

```json
{
  "node_id": "<node UUID>",
  "recorded_at": "<ISO 8601 UTC timestamp>",
  "aci_score": 0.123,
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
- A null, missing, or empty server array does **not** invalidate the cache. Both deployed and head code break out after observing this authoritative empty/unset response, then fall back to `/home/magora/species_whitelist.json` if a cached non-empty array exists. Clearing the server value therefore leaves stale filtering active until the cache is removed or a later non-empty whitelist is received.
- The whitelist is cached at `/home/magora/species_whitelist.json`.
- If Supabase is unavailable, the node retries up to six times and then uses the cached file if present.
- If no usable server value or cache exists, it runs without species filtering.

A detection is submitted only when:

1. It is not excluded by the fixed non-bird list or insects; and
2. Its common name is on the whitelist, or the whitelist is absent; or
3. It is not on the whitelist but confidence is at least `0.70`, in which case the node prints `UNUSUAL` and permits it.

Applying the per-node whitelist is **current firmware behavior**, but it is not an ingest contract required of every new node type. In particular, a new implementation must not assume that Supabase or a whitelist is available until its own contract work explicitly declares it. New nodes should document whether they implement the whitelist and the range-validity gate separately from ingestion.

## Legacy Sheets mirror

The deployed pin and repository head have different legacy mirror behavior:

- **Deployed behavior:** `f0c1940...` contains an always-on, hard-coded Google Apps Script URL in `SCRIPT_URL`; every provisioned node posts to it. This contradicts the repository-head Add Node D2 decision represented by the optional environment configuration below, and is tracked separately as a finding.
- **Repository-head behavior:** `SCRIPT_URL` is read from `SHEETS_WEBHOOK_URL` and defaults to empty. When unset, Sheets posting and legacy queue flushing are no-ops.
- When a URL is enabled in repository head, ACI and Bird detections are posted as separate JSON objects to that URL.
- The endpoint is unauthenticated. New node types must not implement or depend on the Sheets mirror.
- The deployed mirror is a legacy outbound path and is not part of the Supabase ingest contract.

## Retry queues and ordering

`detect.py` has two legacy mirror queues only:

- Detections: `/home/magora/retry_queue.json`
- ACI: `/home/magora/aci_queue.json`

Queues contain legacy mirror payload objects, not Supabase detection or ACI rows. Supabase writes are attempted immediately and are not queued by the detection loop.

Within each queue, new items are appended and files are rewritten as JSON arrays. The Sheets mirror calls `requests.post()` without `raise_for_status()`. Therefore:

- Python transport exceptions (timeouts, connection failures, and similar request-raising exceptions) are caught by the queue callers and items remain for retry.
- HTTP responses such as 429 or 500 are returned normally and are not exceptions, because `raise_for_status()` is not called. Callers and the flush loop treat those items as successfully delivered and remove them; they are not retained or retried.
- Successfully delivered items are removed from the queue; remaining items stay in original array order.

The current loop processes queues as follows at the end of a capture cycle:

1. Flush detection legacy mirror items.
2. Flush ACI legacy mirror items.

These separate queues do not provide cross-table ordering or exactly-once delivery. Supabase detections and ACI rows are attempted immediately and are not queued offline; a Wi-Fi drop can lose those Supabase writes. For new Android implementations, offline ordering and retry semantics must be specified independently.

## Fixed filters

Before posting a detection, `detect.py` excludes:

- Human vocal, Human non-vocal, and Human whistling.
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

## Fleet firmware is provisioned, not upgraded

`magora-firstrun.sh` downloads its current `DETECT_SHA` once, when one-shot first provisioning runs. `magora-firstrun.service` stops itself after its completion flag exists, so changing the pin later does not update `/home/magora/detect.py` on an already provisioned node. The repository can show known pin changes, but it cannot identify which file is installed on each live node.

Git history shows these known detector pins and key changes. This is a historical index, not an installed-fleet inventory.

The pins below are reconstructed from `git log -p -- firmware/magora-firstrun.sh`; each row was active after the corresponding pin transition. The table is historical, not an installed-fleet inventory.

| Pin | `MIN_CONF` | Capture path | Other visible change |
| --- | --- | --- | --- |
| `06744307156fa810962223520f26b08c4b0ea1c6` | `0.10` | Fixed I2S capture command | Exact-SHA timezone fix; hard-coded Sheets URL |
| `ce03534e33bb99dfd25ee4ecc40d22af225e6dc7` | `0.35` | Fixed capture command | Location and season filtering enabled |
| `16489ece376773560f9ff1b88023840304b023f7` | `0.25` | Fixed capture command | `MIN_CONF` changed from `0.35` |
| `02d01f79f024383c5a1c05257d5aede65cbe6813` | `0.25` | Fixed capture command | BirdNET location filtering removed |
| `23ba708268b4f6969d40ccac22c068f18de10e8d` | `0.10` | Fixed capture command | Diagnostic pin; no location filter |
| `8b564aa5ab47c9a6a7b27a7bd4fdd644fe2fa1f9` | `0.10` | Fixed capture command | Filter variant |
| `a3cc6a289c137fe9cf85a1a25dff829c981dfd33` | `0.10` | Fixed capture command | Added YAMNet wildlife analysis with `YAMNET_CONF = 0.3` |
| `5e09fdc47bb4066585bbd75078d4b099cc505f3d` | `0.10` | Fixed capture command | Added BirdNET low-pass preprocessing; YAMNet removed |
| `abbca9b1b40edd2e8e13124aeac3fc55ac8c2ae4` | `0.10` | Fixed capture command | Clean baseline; filter variant removed |
| `ced0ea67eb56ea8a94c3134ec56129d0c3a3daab` | `0.07` | Fixed capture command | Albatross exclusions added |
| `40ca863b52e3feb85cf19513f3ddb6506227bd16` | `0.20` | Fixed capture command | Species whitelist filtering added |
| `e05b4b92114f64c00cee6dfe000ed341565bc89d` | `0.20` | USB/I2S auto-detection | Initial USB microphone capture support |
| `f0c1940acd7b35877e0af44a810fc3d2bc27ab9a` | `0.20` | USB/I2S auto-detection | Improved USB device recognition; hard-coded always-on Sheets URL |

Repository head additionally raises `MIN_CONF` to `0.25`, makes the Sheets URL optional and disabled by default, and guards an unset mirror. These are not installed on older nodes.

For images built from commit `e565362d9ab5bdc99360bfbc4ef8e9b05e60521d` onward, the runtime pins include `birdnetlib==0.18.1`; the image build verifies `Analyzer()` loads the BirdNET model. Repository docs should not infer a different semantic model-release label from package versions alone. Runtime versions on nodes provisioned from earlier images are unknown.
