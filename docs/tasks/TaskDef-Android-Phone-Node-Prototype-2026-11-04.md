# TaskDef — Android Phone Node Prototype

Nov 4, 2026 · Noah

## Status and defaults

An unused Android phone becomes an experimental Magora listening node, built against the same ingest contract as the Pi so it can graduate into the app after about 3 weeks of testing. **For:** Claude Code. **From:** Magora Architect. **Status:** prototype, not a promoted build.

Defaults chosen (Noah can override any of them):

- **Prototype only.** Lives in its own repo, outside the promoted Add Node build and `BUILD.md`.
- **Two data lanes.** Detections and ACI go to prod as a normal per-node user. All sensor and health data stays on the phone.
- **Local-first.** Phase 1 writes nothing to Supabase. Phase 2 turns on prod ingest for one clearly labeled prototype node.
- **No migration.** Nothing in this TaskDef touches schema.
- **Mic:** the Moto g 5G's built-in mic first, then a 3.5mm TRRS lav in its headphone jack. The jack keeps the charging port free.

## Non-negotiables

Every change in this prototype must hold these rules, carried from the charter and the Add Node as-built record.

1. **Per-node credential only.** The phone authenticates as its own per-node user from a portal-generated `magora-config.json`. Never ship `service_role` or `PROVISION_SECRET` in the app or the repo.
2. **Node audio is never stored server-side.** Audio is analyzed on the phone and discarded. Any local clip retention is an explicit prototype-only exception that Noah approves (see open questions).
3. **No camera.** A camera captures people, which is a person-exposure surface needing a consent model. It stays out of this prototype entirely.
4. **Place over people.** The phone is a place's node. Factory-reset it before use; no personal accounts or data on it.
5. **No causal copy.** Barometer data may be logged, but nothing user-facing says weather influenced activity.
6. **Repo process.** Follow David's process: PR-only to `main`, CI checks, `AGENTS.md`. No direct pushes.
7. **No collisions.** Don't touch `magora-portal` or firmware files that open PRs touch, including David's Spec 2 work.

## Step 0 — Verify before building

No app code until both checks below are reported back to the Architect.

**Repo and prod state (Claude Code):**

- Fetch `magora-portal` and `magora-acoustic-biodiversity` heads and list open PRs. Don't scope against cached state.
- Confirm the migration ledger head on prod and `main`. Last known: through `20260727`. Nothing here needs a new one.
- Confirm what `detect.py` actually writes and how it authenticates today. The node contract in work item 1 documents this; it doesn't redesign it.
- Check whether public surfaces filter on `nodes.is_active`. This decides whether the prototype node can be hidden from the map.

**Phone capability check (Noah):** complete (2026-11-04). Moto g 5G (2022): MediaTek Dimensity 700, 5000 mAh battery, 10 W charging, Android 13, headphone jack, Wi-Fi on 2.4 GHz and 5 GHz, barometer present; a light sensor is present but deliberately unused (Noah's decision). The phone sits outdoors, sheltered, only until the external mic arrives. Overcharge protection is set to 80%. The jack route applies; the USB-charging route is dropped.

## Hardware for Noah

Testing starts outdoors on the built-in mic, in a sheltered spot. A 3.5mm mic is ordered (2026-11-04); when it is plugged in, the app logs the switch time and the prototype node is renamed so built-in and external-mic data stay separable.

| Item | When | Notes |
| --- | --- | --- |
| Moto g 5G, factory-reset | Now | Overcharge protection set to 80% (done) |
| Genuine charger for the phone | Now | The port stays free because the mic route is the jack |
| Shaded, ventilated, rain-protected spot | Now | The built-in mic opening must be open to the air, so no sealed box |
| Phone mount or zip ties | Now | Keeps it steady and off the ground |
| Movo LV1 (3.5mm, 20-ft cable) | Later | On order. Must be TRRS (4 rings). Puts the mic outside; a different capture chain from the nodes |
| Movo PM10 + PM10EC6 20-ft extension | Later, alternate | PM10 about $15, extension about $13 at Adorama |

## Work items (Claude Code)

The contract comes first, then the repo, then the app in two phases; each phase ends with a report to the Architect.

**1. Write the node contract.** Add `docs/node-contract.md` to `magora-acoustic-biodiversity`, documenting what `detect.py` does today as the rules any node must follow:

- the `magora-config.json` fields;
- the exact row shapes for `detections` and `aci_logs`, with column names quoted from the schema;
- the 15 s capture cycle, 48 kHz, and the 0.25 confidence floor;
- the BirdNET model version label;
- heartbeat semantics, including what updates `nodes.last_seen_at`. Report the stale `last_seen_at` seen at Blue Bird Ranch on 2026-11-03 as a finding; don't fix it here.

Documentation of existing behavior only; no firmware changes. Opened as a PR.

**2. Create the repo.** `magora-android-node` in the org: README marked experimental, `AGENTS.md`, a CI build check. Kotlin, a single app module.

**3. Phase 1 — local-only app (no Supabase).**

- Foreground service with the microphone service type, a persistent notification, starts on boot, and asks for the battery-optimization exemption.
- Capture 15 s clips at 48 kHz mono. Request the unprocessed audio source where the device supports it and log which source was actually granted.
- Log the active input device each cycle (built-in vs. external), so a dropped external mic shows up.
- Run BirdNET on the phone via LiteRT (the same model version as the Pi) and compute ACI. Discard audio after analysis.
- Write everything to append-only local files, rotated daily: detections, ACI, battery level and temperature, charging state, CPU throttling if available, GPS fix and time, and barometer and accelerometer readings. The light sensor is deliberately not logged (Noah's decision); do not add it.
- A status screen showing: listening yes/no, last detection, mic in use, battery temperature, and uptime.
- An export action that shares the log files.

**Built-in mic first.** Phase 1 starts on the phone's internal mic. Place the phone so its mic opening is open to the air but sheltered from rain, direct sun and wind. Speech processing and wind noise matter most on a built-in mic, so the granted audio source is the key log line. Built-in-mic detections validate the pipeline and uptime; they are not comparable to Pi data.

**4. Phase 2 — prod ingest for one prototype node.**

- Noah registers a node through Add Node, named so it's clearly a prototype (for example "[proto] Phone Node (built-in mic)"), so the capture chain is visible without a schema field. Rename it when the mic changes.
- The app imports that node's `magora-config.json` with a file picker. Store credentials in Android's encrypted storage, not in plain files.
- Post detections and ACI exactly per the node contract, as that node's user. Queue rows while offline and upload in order on reconnect.
- Sensor and health data stay on the phone.
- If Step 0 found an `is_active` filter, use it to keep the node off public surfaces; otherwise accept that it appears on the map once a plausible detection lands.

**Verification per phase:**

- Phase 1: 72 hours continuous on charge with no service death; log files complete; the external mic is held across a power replug (once it arrives).
- Phase 2: heartbeats steady on the node page; at least one plausible detection appears there; an offline queue drains correctly after a forced Wi-Fi drop.

## Scope out

None of these are built in this prototype; each is a graduation-stage decision.

- Camera or any image capture.
- Uploading audio anywhere.
- New tables or columns, including `capture_chain` and a node-environment table.
- QR provisioning in the Add Node portal page.
- Any `magora-portal` change, or edits to the promoted `BUILD.md`.
- Using the phone's neural processing chip for inference; CPU is enough for the prototype.
- Ultrasound or bat detection.
- A second BirdNET model or overlapping-window inference, unless Phase 1 shows ample headroom.

## Decision gate (about 3 weeks after Phase 2 starts)

The prototype graduates only if it passes every check below; otherwise it is shelved, with nothing to unwind in prod beyond one labeled node.

- [ ] Ran 14+ consecutive days on charge without the service dying or needing manual restarts.
- [ ] Battery temperature stayed under a safe ceiling (set from the Phase 1 data) and the battery shows no swelling.
- [ ] The external mic was never silently dropped; the logged input device matched for the whole run.
- [ ] Heartbeats on the node page are steady, with gaps explained by real outages only.
- [ ] Detection quality is comparable to a Pi node, checked side by side if a working Pi is nearby (see open questions).
- [ ] At least one sensor stream proved worth keeping, or a decision to drop all of them.

Built-in-mic weeks count toward the uptime, thermal and heartbeat checks. Detection comparability is judged only on an external-mic run.

**If it graduates, in this order:**

1. Decide promoted second build vs. community build (revisits the one-build product decision).
2. Add QR-code provisioning to Add Node.
3. Add the `capture_chain` migration, then the node-environment table for the sensors that earned it. Both are coordinated with David.
4. Write a community build doc that points to the node contract.

## Flags and open questions

**Migrations:** none in this TaskDef. Graduation implies two (`capture_chain`, node-environment), numbered from the live ledger head and coordinated with David under the staging freeze.

**Vault:** on Phase 2 start, add a dated line to the current-state docs noting the prototype node exists and is labeled. At the gate, write a build log in `Log/` recording the result either way.

**Open questions:**

- [ ] Side-by-side reference: the only reporting node on 2026-11-03 was Blue Bird Ranch. Run the phone there, or wait for the Temple of the Bird fix?
- [ ] Keep short audio clips of top detections on the phone only, for Noah's review? This is an explicit exception to the no-stored-audio rule; default is no.
- [ ] Is a prod prototype node acceptable to David, given previews and dev already hit prod?
