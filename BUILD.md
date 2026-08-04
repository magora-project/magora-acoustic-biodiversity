# Build a Magora node

A Magora node is a small computer with a microphone that listens to one place, continuously, and
publishes what it hears. It needs no soldering, no electronics experience, and no prior time in a
terminal. If you can follow a recipe, you can build one.

This is the **promoted build** — the one to make if you're building your first node. A second,
older design is documented at the bottom for people who already own the parts.

**What you're signing up for:** about an hour of assembly, roughly $130–165 in parts, and a place
that will speak for itself from then on.

---

## Part 1 — The shopping list

One list. Buy all ten things.

> **Prices drift.** These were checked in August 2026 and are here to set expectations, not to be
> quoted back. Verify at purchase.

| # | Item | What to get | ~Price | Can I economize? |
|---|---|---|---|---|
| 1 | Single-board computer | **Raspberry Pi 4 Model B, 2GB** | $55 | **No.** See the note below — the cheaper board costs more. |
| 2 | microSD card | **64GB high-endurance** (e.g. Samsung PRO Endurance) | $15 | **No.** A node writes 24/7; ordinary cards die in months. |
| 3 | Power supply | **Official Raspberry Pi 15W USB-C** | $8–10 | **No.** Undervoltage corrupts the card and stalls detection. |
| 4 | Microphone | **Movo M1 USB lavalier** (omnidirectional, 20-ft cord) | $20 | Yes — Boya BY-LM40 is equivalent and interchangeable. |
| 5 | Enclosure | Gasketed **IP65 or IP67** ABS box, at least 65 mm deep | $12–28 | Not on the seal. Anything else is fine. |
| 6 | Mic weatherproofing | Rain shield + acoustic membrane + foam windscreen | $5–8 | **No.** This is the part that decides how well it hears. |
| 7 | Cable gland | IP68, sized to your cable's outer diameter | $5 | Yes — a tight grommet and sealant works. |
| 8 | Mounting | UV-resistant zip ties, or a pole clamp | $5–8 | Yes. |
| 9 | Cabling | Usually none — the mic's 20-ft cord is enough | $0–8 | Yes. Only needed if the Pi sits >2 m from the mic. |
| 10 | Desiccant | Reactivatable silica gel packs | $6 | **No.** Condensation kills more outdoor electronics than rain. |

**Roughly $128 at the cheapest, $155–165 comfortable.** Both are equally solder-free.

### Two things worth knowing before you buy

**Get the *USB* Movo M1, not the XLR one.** Movo sells two microphones under similar names. You
want the **M1 USB lavalier** — it plugs straight into a USB port. The **MV-M1** is a dynamic XLR
microphone and will not work here without an audio interface and phantom power.

**Why not the $17 Raspberry Pi Zero 2W?** Because the cheapest board makes everything else harder.
It has no full-size USB port, so the microphone needs an adapter — a well-documented source of
failures. And it overheats under continuous listening, which in practice means drilling vents and
wiring a cooling fan. The cheap board pushes you straight back into the soldering and enclosure
surgery this build exists to avoid. The Pi 4 runs cool enough for a sealed box on a passive
heatsink and has ordinary USB ports.

---

## Part 2 — Building it

### Step 1 — Assemble

1. Put the Pi in the enclosure. Leave room for the power cable.
2. Drill or punch one hole for the cable gland. Feed the microphone cable through it and seal it.
3. Fit the microphone in its rain shield, membrane over the capsule, windscreen outside. Point it
   **downward** so water runs off rather than pooling.
4. Drop a desiccant pack in the box.
5. Plug the microphone into any USB port on the Pi. That's the entire wiring step.

Don't seal the enclosure yet — you'll want access if something needs checking.

### Step 2 — Register your place

Go to **[the Magora portal](https://magora-portal.vercel.app/register)** and sign in (or make an
account — it's free).

Fill in where your node will listen: a name, its coordinates, and its habitat. When you submit, the
portal creates the place, shows you its credentials **once**, and downloads a file called
`magora-config.json`.

**Keep that file.** It's how your node knows who it is. It contains the node's credentials, your
Wi-Fi details, and its location.

### Step 3 — Flash the card

1. Download the **[Magora node image](https://github.com/magora-project/magora-acoustic-biodiversity/releases/latest/download/magora-node.img.xz)**.
2. Download and open the [Raspberry Pi Imager](https://www.raspberrypi.com/software/).
3. Choose **Use custom** and select the file you downloaded. Pick your microSD card. Write it.

When it finishes, unplug the card and plug it back in. A drive called **`bootfs`** appears.

### Step 4 — Drop your config on the card

Copy `magora-config.json` onto the **`bootfs`** drive.

Put it at the top level of that drive — not inside any folder. That's the whole configuration step.

### Step 5 — First boot

Put the card in the Pi, close the enclosure, and plug in the power.

**The first boot takes 25–40 minutes.** The node is connecting to Wi-Fi, installing the bird
identification model, and registering itself. This only happens once. Later boots take about a
minute.

Nothing visible happens during this time. That's expected. Leave it alone.

### Step 6 — Confirm it's listening

Go back to the portal and open your node's page. Within an hour of first boot you should see its
**first detection** — a species name, a time, and a confidence score.

That's it. Your place is on the record, and it will keep speaking without you.

---

## If something isn't working

**Nothing after an hour.** Check the `bootfs` drive: `magora-status.txt` is a running log the node
writes as it sets itself up, and it will usually say plainly what went wrong. The most common cause
is a Wi-Fi typo in `magora-config.json`.

**The log says "no audio capture device detected."** Some USB microphones take a moment to appear,
and the node retries on its own — but if it keeps saying this, unplug and replug the microphone,
then reboot the Pi. The node detects the microphone by itself; there is nothing to configure.

**Detections, but very few.** Check the microphone is pointed away from a wall and isn't wrapped too
tightly in its windscreen. A muffled capsule loses quiet, distant birds first.

**Getting a closer look.** If you set an SSH password during registration, you can connect to the
node and watch it work in real time:

```bash
ssh pi@<your-node's-ip>
journalctl -u birdnet -f
```

---

## A note on what your node hears

Every detection in Magora's record so far arrived through a different microphone — an INMP441, a
small MEMS capsule wired directly to the board. The promoted build uses a USB electret instead,
because it needs no soldering.

Both are omnidirectional and both cover the frequencies birds sing in, so this isn't a break in the
record. But they aren't identical: they differ in self-noise, sensitivity, and how they roll off at
high frequencies. Where that's most likely to show is at the margins — the faintest, most distant,
highest-pitched calls, which is exactly where a detection is most marginal anyway. The common,
close, loud species will look the same.

We're flagging it because it's the honest thing to do with a dataset meant for research, and
because knowing which microphone heard a thing is the kind of detail that's very cheap to record
now and impossible to reconstruct later.

---

## The reference build (INMP441 + I2S)

The original design uses an **INMP441 I2S MEMS microphone** wired to the Pi's GPIO header, on a
Raspberry Pi Zero 2W. It's cheaper (~$38 all in) and it's what the network's existing nodes run.

It is **supported but not promoted**: it requires soldering or careful jumper wiring, an I2S device
tree overlay, and it runs hot enough under continuous load to need thermal attention.

Wiring is documented in [hardware/WIRING.md](hardware/WIRING.md). The image enables the
`adau7002-simple` overlay and the firmware captures from `hw:adau7002,0` — if you're adapting this,
match those two, not the older instructions floating around for other overlays.

If you already own an INMP441, this build works and your data is just as welcome.
