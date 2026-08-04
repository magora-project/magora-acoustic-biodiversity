import subprocess
import requests
import json
import os
import re
import time
import math
import numpy as np
from datetime import datetime, timedelta, timezone
from astral import LocationInfo
from astral.sun import sun
from birdnetlib import Recording
from birdnetlib.analyzer import Analyzer

# Legacy Google Sheets mirror. OFF unless SHEETS_WEBHOOK_URL is set — a public build must never
# post to it. The endpoint takes unauthenticated writes, so shipping a hardcoded URL to every
# external builder would hand out an open write surface. Supabase is the system of record either
# way; this is a personal dashboard mirror, so leaving it unset costs a node nothing.
SCRIPT_URL = os.environ.get("SHEETS_WEBHOOK_URL", "")
LOCATION_FILE = "/home/magora/location.json"
QUEUE_FILE = "/home/magora/retry_queue.json"
ACI_QUEUE_FILE = "/home/magora/aci_queue.json"
MIN_CONF = 0.25      # detection floor; BOU study: 0.1–0.3 = "detect as many as possible"
SENSITIVITY = 1.25   # sigmoid sensitivity; BirdNET-Pi high-sensitivity default (range 0.5–1.5)
OVERLAP = 1.5        # seconds of overlap between BirdNET's 3s windows. BOU study found ~2.0
                     # optimal; 1.5 balances detection richness against Pi Zero 2W analysis time.
WHITELIST_BYPASS_CONF = 0.70  # species absent from the regional eBird whitelist are kept only
                              # above this confidence (catches genuine local rarities/lump
                              # victims like Cordilleran Flycatcher while suppressing exotic
                              # false positives — Torresian Crow, Black Scoter, etc.)

SUPABASE_URL     = "https://wqxmmuwrfltpaxnuddwk.supabase.co"
SUPABASE_ANON_KEY = os.environ.get("SUPABASE_ANON_KEY", "")
NODE_EMAIL       = os.environ.get("NODE_EMAIL", "")
NODE_PASSWORD    = os.environ.get("NODE_PASSWORD", "")
NODE_ID          = os.environ.get("NODE_ID", "")

_token = None

def sign_in():
    global _token
    r = requests.post(
        f"{SUPABASE_URL}/auth/v1/token?grant_type=password",
        headers={"apikey": SUPABASE_ANON_KEY, "Content-Type": "application/json"},
        json={"email": NODE_EMAIL, "password": NODE_PASSWORD},
        timeout=15
    )
    r.raise_for_status()
    _token = r.json()["access_token"]
    print("Signed in to Supabase.")

def get_headers():
    return {
        "apikey": SUPABASE_ANON_KEY,
        "Authorization": f"Bearer {_token}",
        "Content-Type": "application/json",
        "Prefer": "return=minimal"
    }

def _post_supabase(url, payload):
    r = requests.post(url, headers=get_headers(), json=payload, timeout=10)
    if r.status_code == 401:
        sign_in()
        r = requests.post(url, headers=get_headers(), json=payload, timeout=10)
    return r


EXCLUDE = {
    "Human vocal", "Human non-vocal", "Human whistling", "Crowd",
    "Dog", "Cat",
    "Engine", "Siren", "Power tools", "Gun",
    "Fireworks", "Hand saw", "Chainsaw",
    "Car", "Truck", "Motorcycle",
    # Seabirds BirdNET confuses with Common Raven calls
    "Laysan Albatross", "Black-footed Albatross",
}

def get_location():
    try:
        with open(LOCATION_FILE) as f:
            data = json.load(f)
            return data.get("lat", 43.4), data.get("lon", -110.7), data.get("name", "Jackson WY")
    except:
        return 43.4, -110.7, "Jackson WY"

def load_queue(path):
    try:
        with open(path) as f:
            return json.load(f)
    except:
        return []

def save_queue(path, queue):
    with open(path, 'w') as f:
        json.dump(queue, f)

def post_data(data):
    # No-op when the Sheets mirror is disabled (the default). Returning rather than raising
    # matters: every caller treats an exception as "network down, queue it for retry", so raising
    # here would grow retry_queue.json forever on a node that is working perfectly.
    if not SCRIPT_URL:
        return
    requests.post(SCRIPT_URL, json=data, timeout=10)

def post_supabase_detection(name, scientific_name, confidence, lat, lon, dawn, aci, time_category, now, temporal):
    try:
        payload = {
            "node_id":             NODE_ID,
            "species_name":        name,
            "raw_label":           scientific_name,
            "confidence":          confidence,
            "detected_at":         now.isoformat(),
            "location":            f"POINT({lon} {lat})",
            "is_dawn_chorus":      temporal.get("dawn_chorus_window") or dawn,
            "minutes_from_sunrise": temporal.get("minutes_from_sunrise"),
            "dawn_chorus_window":  temporal.get("dawn_chorus_window"),
            "phenological_week":   temporal.get("phenological_week"),
            "season":              temporal.get("season"),
        }
        r = _post_supabase(f"{SUPABASE_URL}/rest/v1/detections", payload)
        if r.status_code not in (200, 201):
            print(f"  Supabase detection error: {r.status_code} {r.text}")
    except Exception as ex:
        print(f"  Supabase detection exception: {ex}")

def post_supabase_aci(aci, time_category, dawn, now):
    try:
        payload = {
            "node_id": NODE_ID,
            "recorded_at": now.isoformat(),
            "aci_score": aci,
            "time_category": time_category,
            "dawn_chorus": dawn,
            "duration_secs": 15
        }
        r = _post_supabase(f"{SUPABASE_URL}/rest/v1/aci_logs", payload)
        if r.status_code not in (200, 201):
            print(f"  Supabase ACI error: {r.status_code} {r.text}")
    except Exception as ex:
        print(f"  Supabase ACI exception: {ex}")

def flush_queue(path):
    # Leave any pre-existing queue alone when the mirror is off — post_data() is a no-op there, so
    # draining would silently discard rows a node had saved from before it was disabled.
    if not SCRIPT_URL:
        return
    queue = load_queue(path)
    if not queue:
        return
    remaining = []
    for item in queue:
        try:
            post_data(item)
        except:
            remaining.append(item)
    save_queue(path, remaining)
    flushed = len(queue) - len(remaining)
    if flushed > 0:
        print(f"Flushed {flushed} queued items from {os.path.basename(path)}")

def get_time_category(now_utc, lat, lon):
    now_local = now_utc.replace(tzinfo=None)
    try:
        loc = LocationInfo(latitude=lat, longitude=lon)
        s = sun(loc.observer, date=now_local.date())
        sunrise = s['sunrise'].replace(tzinfo=None)
        sunset  = s['sunset'].replace(tzinfo=None)
        dawn_start = sunrise - timedelta(minutes=30)
        dawn_end   = sunrise + timedelta(minutes=60)
        dusk_start = sunset  - timedelta(minutes=30)
        dusk_end   = sunset  + timedelta(minutes=60)

        if dawn_start <= now_local <= dawn_end:
            return "Dawn"
        elif dawn_end < now_local <= sunrise + timedelta(hours=4):
            return "Morning"
        elif sunrise + timedelta(hours=4) < now_local <= sunset - timedelta(hours=2):
            return "Midday"
        elif sunset - timedelta(hours=2) < now_local < dusk_start:
            return "Afternoon"
        elif dusk_start <= now_local <= dusk_end:
            return "Dusk"
        else:
            return "Night"
    except:
        hour = now_local.hour
        if 5 <= hour < 9:   return "Dawn"
        elif 9 <= hour < 12:  return "Morning"
        elif 12 <= hour < 16: return "Midday"
        elif 16 <= hour < 19: return "Afternoon"
        elif 19 <= hour < 21: return "Dusk"
        else:                 return "Night"

def get_temporal_context(now, lat, lon):
    """Calculate all Phase 1 temporal fields for a detection."""
    now_local = now.replace(tzinfo=None)
    try:
        loc = LocationInfo(latitude=lat, longitude=lon)
        s = sun(loc.observer, date=now_local.date())
        sunrise = s['sunrise'].replace(tzinfo=None)

        minutes_from_sunrise = int((now_local - sunrise).total_seconds() / 60)
        dawn_chorus_window   = -30 <= minutes_from_sunrise <= 120

        day_of_year      = now.timetuple().tm_yday
        phenological_week = min(52, math.ceil(day_of_year / 7))

        if phenological_week <= 10:   season = "winter"
        elif phenological_week <= 18: season = "early_spring"
        elif phenological_week <= 26: season = "breeding"
        elif phenological_week <= 34: season = "post_breeding"
        elif phenological_week <= 44: season = "fall_migration"
        else:                         season = "late_fall"

        return {
            "minutes_from_sunrise": minutes_from_sunrise,
            "dawn_chorus_window":   dawn_chorus_window,
            "phenological_week":    phenological_week,
            "season":               season,
        }
    except Exception as ex:
        print(f"  Temporal context error: {ex}")
        return {
            "minutes_from_sunrise": None,
            "dawn_chorus_window":   None,
            "phenological_week":    None,
            "season":               None,
        }

def is_dawn_chorus(time_category):
    return time_category == "Dawn"

def calculate_aci(wav_file):
    try:
        # Read via soundfile (same robust path BirdNET uses). The stdlib `wave`
        # module misreads arecord's S32_LE WAVE_FORMAT_EXTENSIBLE files and
        # returns digital silence, which zeroed out ACI.
        import soundfile as sf
        data, framerate = sf.read(wav_file)  # float64, normalized to [-1, 1]

        if data.ndim > 1:
            # ADAU7002 can leave one channel dead — use the channel with signal.
            energies = np.sum(np.abs(data), axis=0)
            samples = data[:, int(np.argmax(energies))]
        else:
            samples = data

        max_val = np.max(np.abs(samples))
        if max_val == 0:
            return 0.0
        samples = samples / max_val

        chunk_size = framerate // 4
        n_chunks = len(samples) // chunk_size
        if n_chunks < 2:
            return None

        aci_values = []
        for i in range(n_chunks):
            chunk = samples[i * chunk_size:(i + 1) * chunk_size]
            spectrum = np.abs(np.fft.rfft(chunk))
            if np.sum(spectrum) > 0:
                aci = np.sum(np.abs(np.diff(spectrum))) / np.sum(spectrum)
                aci_values.append(aci)

        if not aci_values:
            return None

        return round(float(np.mean(aci_values)), 3)

    except Exception as ex:
        print(f"ACI calculation error: {ex}")
        return None

def get_insect_activity_label(aci, time_category):
    if aci is None:
        return ""
    if time_category == "Night":
        if aci > 0.65: return "High insect activity"
        elif aci > 0.50: return "Moderate insect activity"
        else: return "Low insect activity"
    elif time_category in ["Dusk", "Dawn"]:
        if aci > 0.60: return "Active transition chorus"
        else: return "Quiet transition period"
    return ""

WHITELIST_FILE = "/home/magora/species_whitelist.json"

def fetch_whitelist():
    # Retry the network fetch: the service often starts before WiFi is up, and a
    # single failed fetch with no cache would silently disable species filtering
    # for the whole session (observed: exotic false positives flooding in at >0.20).
    for attempt in range(6):
        try:
            r = requests.get(
                f"{SUPABASE_URL}/rest/v1/nodes",
                headers={"apikey": SUPABASE_ANON_KEY, "Authorization": f"Bearer {SUPABASE_ANON_KEY}"},
                params={"id": f"eq.{NODE_ID}", "select": "species_whitelist"},
                timeout=10
            )
            rows = r.json()
            wl = rows[0].get("species_whitelist") if rows else None
            if wl and len(wl) > 0:
                with open(WHITELIST_FILE, "w") as f:
                    json.dump(wl, f)
                print(f"Whitelist loaded: {len(wl)} species from eBird")
                return set(s.lower() for s in wl)
            # Reached Supabase but column empty/null — retrying won't help.
            print("Whitelist fetch: node has no species_whitelist set")
            break
        except Exception as ex:
            print(f"Whitelist fetch error (attempt {attempt + 1}/6): {ex}")
            time.sleep(10)
    # Fall back to cached file
    try:
        with open(WHITELIST_FILE) as f:
            wl = json.load(f)
        if wl:
            print(f"Whitelist loaded from cache: {len(wl)} species")
            return set(s.lower() for s in wl)
    except:
        pass
    print("No whitelist — running without species filtering")
    return None

def list_capture_cards():
    """Return [(card_number, full_lowercased_arecord_line)] for each capture card.
    The whole line is kept (not just the card name) because the 'USB' marker
    often appears in the device half, e.g.:
      "card 1: Microphone [UAC 1.0 Microphone], device 0: USB Audio [USB Audio]"
    """
    try:
        out = subprocess.run(
            ["arecord", "-l"], capture_output=True, text=True, timeout=10
        ).stdout
    except Exception as ex:
        print(f"arecord -l failed: {ex}")
        return []
    cards = []
    for line in out.splitlines():
        m = re.match(r"card (\d+):", line)
        if m:
            cards.append((int(m.group(1)), line.lower()))
    return cards

def is_usb_card(num, line):
    """True if the card is a USB device. The kernel exposes
    /proc/asound/card<N>/usbid only for USB sound cards — a definitive test
    that doesn't depend on how the mic names itself. Fall back to scanning the
    full arecord line for 'usb'."""
    return os.path.exists(f"/proc/asound/card{num}/usbid") or "usb" in line

def detect_audio_device():
    """Auto-detect a capture device so any attached mic 'just works'.

    Returns (device_string, is_i2s). Priority:
      1. USB audio mic -> plughw:<card>,0  (ALSA converts any rate/format/ch)
      2. I2S adau7002  -> hw:adau7002,0    (bit-exact path for existing nodes)
      3. any other non-onboard capture card -> plughw:<card>,0
    USB is preferred over adau7002 because the image always loads the adau7002
    overlay, which presents a phantom capture card even when no I2S mic is wired
    — so a real USB mic should win. Returns (None, False) if nothing has
    enumerated yet.
    """
    cards = list_capture_cards()
    if not cards:
        return (None, False)
    for num, line in cards:
        if is_usb_card(num, line):
            return (f"plughw:{num},0", False)
    for num, line in cards:
        if "adau7002" in line:
            return ("hw:adau7002,0", True)
    for num, line in cards:
        if "bcm2835" not in line:
            return (f"plughw:{num},0", False)
    return (f"plughw:{cards[0][0]},0", False)

def select_audio_device():
    """Detect the mic at startup, retrying — a USB mic can enumerate a few
    seconds after the service starts."""
    for attempt in range(6):
        device, is_i2s = detect_audio_device()
        if device:
            print(f"Audio device: {device} ({'I2S adau7002' if is_i2s else 'USB/generic'})")
            return device, is_i2s
        print(f"No capture device yet (attempt {attempt + 1}/6), waiting for mic...")
        time.sleep(5)
    print("WARNING: no audio capture device detected — will keep retrying in the loop")
    return None, False

def arecord_cmd(device, is_i2s, filename):
    """Build the arecord command for the detected device."""
    if is_i2s:
        # adau7002 I2S: native 2ch/32-bit; calculate_aci() picks the live channel.
        return ["arecord", "-D", device, "-c2", "-r", "48000", "-f", "S32_LE",
                "-d", "15", filename]
    # USB / generic: plughw lets ALSA convert any mic's native rate/format/
    # channels down to mono 48kHz 16-bit, which soundfile + BirdNET read cleanly.
    return ["arecord", "-D", device, "-c1", "-r", "48000", "-f", "S16_LE",
            "-d", "15", filename]

print("Loading model...")
analyzer = Analyzer()
sign_in()
whitelist = fetch_whitelist()
audio_device, audio_is_i2s = select_audio_device()
print("Ready. Listening continuously. Press Ctrl+C to stop.\n")

while True:
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    filename = f"/home/magora/recording_{timestamp}.wav"
    now = datetime.now(timezone.utc)

    # No mic found at startup (or it was unplugged) — keep trying to (re)detect
    # one before each capture so a hot-plugged mic gets picked up.
    if audio_device is None:
        audio_device, audio_is_i2s = detect_audio_device()
        if audio_device is None:
            print(f"{now.strftime('%H:%M:%S')} no audio device — retrying in 10s")
            time.sleep(10)
            continue
        print(f"Audio device: {audio_device} ({'I2S adau7002' if audio_is_i2s else 'USB/generic'})")

    try:
        result = subprocess.run(
            arecord_cmd(audio_device, audio_is_i2s, filename),
            capture_output=True, timeout=30)
    except subprocess.TimeoutExpired:
        # arecord wedged on the audio device (it should finish in ~15s). Kill it so
        # the device is released, skip this window, and keep looping instead of
        # hanging forever. Brief settle before the next capture attempt.
        subprocess.run(["pkill", "-9", "arecord"])
        print(f"{now.strftime('%H:%M:%S')} arecord timed out (audio device wedged) — killed it, skipping window")
        if os.path.exists(filename):
            os.remove(filename)
        # Mic may have been unplugged/swapped — re-detect before the next window.
        audio_device, audio_is_i2s = detect_audio_device()
        time.sleep(2)
        continue

    if result.returncode != 0:
        err = result.stderr.decode(errors="ignore").strip()[:200]
        print(f"{now.strftime('%H:%M:%S')} arecord failed (rc={result.returncode}): {err}")
        if os.path.exists(filename):
            os.remove(filename)
        # Device may have changed or re-enumerated (common right after boot) — re-detect.
        audio_device, audio_is_i2s = detect_audio_device()
        time.sleep(2)
        continue

    if not os.path.exists(filename):
        print(f"Recording failed, skipping")
        continue

    try:
        lat, lon, location_name = get_location()
        aci = calculate_aci(filename)
        time_category = get_time_category(now, lat, lon)
        temporal = get_temporal_context(now, lat, lon)
        dawn = temporal.get("dawn_chorus_window") or is_dawn_chorus(time_category)
        dawn_label = "Yes" if dawn else "No"
        insect_label = get_insect_activity_label(aci, time_category)

        if dawn:
            mins = temporal.get("minutes_from_sunrise")
            mins_str = f" (+{mins} min from sunrise)" if mins is not None else ""
            print(f"{now.strftime('%H:%M:%S')} DAWN CHORUS WINDOW{mins_str}")

        # ACI — post to both Sheets and Supabase
        aci_data = {
            "type": "aci",
            "timestamp": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "location": location_name,
            "lat": lat,
            "lon": lon,
            "aci_score": aci if aci is not None else "",
            "time_category": time_category,
            "dawn_chorus": dawn_label
        }
        try:
            post_data(aci_data)
            if insect_label:
                print(f"{now.strftime('%H:%M:%S')} {insect_label} | ACI: {aci} | {time_category}")
        except:
            queue = load_queue(ACI_QUEUE_FILE)
            queue.append(aci_data)
            save_queue(ACI_QUEUE_FILE, queue)

        if aci is not None:
            post_supabase_aci(aci, time_category, dawn, now)

        # Bird detection
        recording = Recording(
            analyzer, filename,
            min_conf=MIN_CONF,
            sensitivity=SENSITIVITY,
            overlap=OVERLAP,
        )
        recording.analyze()

        if recording.detections:
            for d in recording.detections:
                name = d['common_name']
                if name in EXCLUDE:
                    continue
                if any(k in name for k in ("Katydid", "Cricket", "Grasshopper", "Cicada")):
                    continue
                if whitelist is not None and name.lower() not in whitelist:
                    if d['confidence'] < WHITELIST_BYPASS_CONF:
                        continue
                    print(f"{now.strftime('%H:%M:%S')} UNUSUAL {name} - {d['confidence']:.2f} (not in regional eBird list)")
                print(f"{now.strftime('%H:%M:%S')} {name} - {d['confidence']:.2f} | ACI: {aci} | {time_category} | Dawn: {dawn_label}")
                bird_data = {
                    "type": "bird",
                    "timestamp": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "common_name": name,
                    "scientific_name": d['scientific_name'],
                    "confidence": round(d['confidence'], 2),
                    "lat": lat,
                    "lon": lon,
                    "location": location_name,
                    "dawn_chorus": dawn_label,
                    "aci_score": aci if aci is not None else ""
                }
                try:
                    post_data(bird_data)
                except:
                    queue = load_queue(QUEUE_FILE)
                    queue.append(bird_data)
                    save_queue(QUEUE_FILE, queue)
                    print(f"  Queued (no internet)")

                post_supabase_detection(
                    name, d['scientific_name'],
                    round(d['confidence'], 2),
                    lat, lon, dawn, aci, time_category, now, temporal
                )
        else:
            aci_str = f" | ACI: {aci}" if aci is not None else ""
            cat_str = f" | {time_category}"
            insect_str = f" | {insect_label}" if insect_label else ""
            print(f"{now.strftime('%H:%M:%S')} No birds detected{aci_str}{cat_str}{insect_str}")

    except Exception as ex:
        print(f"Analysis error: {ex}")
    finally:
        if os.path.exists(filename):
            os.remove(filename)

    flush_queue(QUEUE_FILE)
    flush_queue(ACI_QUEUE_FILE)
