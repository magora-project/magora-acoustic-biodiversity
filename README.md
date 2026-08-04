# Magora Network

A distributed acoustic biodiversity monitoring network for detecting and logging birds, insects, and soundscape health using low-cost hardware and open-source AI.

Each node is a Raspberry Pi with a microphone, running BirdNET for species identification and a continuous Acoustic Complexity Index (ACI) for insect and soundscape monitoring. All data flows into a central Supabase database with PostGIS geospatial indexing.

The goal is a community-owned network of listening stations that generates research-grade biodiversity data — accessible to citizen scientists, naturalists, and institutions alike.

---

## What it detects

- **Birds** — species identification via Cornell Lab's BirdNET, confidence-scored detections
- **Insects** — Acoustic Complexity Index as a biodiversity proxy (no additional hardware needed)
- **Soundscape health** — continuous ACI logging every 15 seconds, 24/7
- **Dawn chorus** — automatic detection of the morning chorus window relative to local sunrise

---

## Hardware

There are two builds. **[BUILD.md](BUILD.md) is the canonical guide** — parts, prices and commands
live there and nowhere else.

**Promoted build — no soldering.** A USB microphone on a Raspberry Pi 4. Make this one if you're
building your first node.

| Component | Model | Cost |
|---|---|---|
| Compute | Raspberry Pi 4 Model B (2GB) | ~$55 |
| Microphone | Movo M1 **USB** lavalier | ~$20 |
| Storage | 64GB high-endurance microSD | ~$15 |
| Power | Official Raspberry Pi 15W USB-C | ~$8–10 |
| Weatherproofing | Enclosure, gland, mic shield, desiccant | ~$30–50 |

**Total per node: ~$128–165.** Full list, including why the cheaper board is a false economy, in
[BUILD.md](BUILD.md).

**Reference build — requires soldering.** INMP441 I2S MEMS microphone wired to the GPIO header on a
Pi Zero 2W, ~$38. Supported but not promoted; it's what the network's existing nodes run. Wiring in
[hardware/WIRING.md](hardware/WIRING.md).

---

## Quick start

1. **Buy the parts** — see [BUILD.md](BUILD.md)
2. **Register your place** at the [Magora portal](https://magora-portal.vercel.app/register) and
   download `magora-config.json`
3. **Flash** the [pre-built node image](https://github.com/magora-project/magora-acoustic-biodiversity/releases/latest/download/magora-node.img.xz)
   with the Raspberry Pi Imager
4. **Copy `magora-config.json`** to the `bootfs` drive, at the top level
5. **Power on.** First boot takes 25–40 minutes while it installs itself
6. **Watch for your first detection** on your node's page

No SSH, no terminal, and no editing files on the Pi. The config file on the boot partition is the
entire configuration step — `magora-firstrun.sh` reads it on first boot and provisions the node.

Step-by-step, written for someone who has never opened a terminal: **[BUILD.md](BUILD.md)**.

---

## Data

All detections are logged to a central Supabase PostgreSQL database with PostGIS. The data is publicly readable and available in Darwin Core format for research use.

- **Detections:** `https://wqxmmuwrfltpaxnuddwk.supabase.co/rest/v1/detections`
- **ACI logs:** `https://wqxmmuwrfltpaxnuddwk.supabase.co/rest/v1/aci_logs`
- **Darwin Core view:** `https://wqxmmuwrfltpaxnuddwk.supabase.co/rest/v1/occurrences_view`

---

## Project structure

```
magora-acoustic-biodiversity/
├── firmware/
│   ├── detect.py                # Main detection loop (BirdNET + ACI)
│   ├── magora-firstrun.sh       # First-boot self-provisioning from magora-config.json
│   ├── magora-firstrun.service  # systemd unit for the above
│   └── birdnet.service          # systemd service for detect.py
├── build/
│   └── customize-image.sh       # Turns Pi OS Lite into the Magora node image (CI)
├── hardware/
│   └── WIRING.md                # INMP441 wiring (reference build)
├── worker/                      # Fly.io BirdNET queue consumer for mobile Listens
├── docs/
│   └── ARCHITECTURE.md          # System architecture
├── BUILD.md                     # Canonical build guide — parts, prices, walkthrough
├── README.md
├── CONTRIBUTING.md
└── LICENSE
```

---

## Network map

| Node | Location | Habitat |
|---|---|---|
| birdnode1 | Southern Colorado | Montane scrub |

---

## Contributing

We welcome new nodes, code contributions, and classifier improvements. See [CONTRIBUTING.md](CONTRIBUTING.md) to get started.

---

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE).

Built on [BirdNET-Analyzer](https://github.com/kahst/BirdNET-Analyzer) by the Cornell Lab of Ornithology.
