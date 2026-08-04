# INMP441 Wiring Guide — Raspberry Pi Zero 2W

## Pin connections

| INMP441 pin | Pi Zero 2W physical pin | GPIO |
|---|---|---|
  | VDD | Pin 1 | 3.3V |
  | GND | Pin 6 | GND |
  | SD | Pin 38 | GPIO 20 |
  | SCK | Pin 12 | GPIO 18 |
  | WS | Pin 35 | GPIO 19 |
  | L/R | Any GND pin | GND |

  Any GND pin works for L/R — options are pins 6, 9, 14, 20, 25, 30, 34, 39.

  ## Pin layout reference

  Pin 1 is the corner pin nearest the SD card slot, marked with a small square solder pad.

```
SD card end
 [1] [2]
 [3] [4]
 [5] [6]
 ...
  [39][40]
  USB end
```

Odd numbers on the left column, even on the right.

## Enable I2S audio

Add these two lines to the bottom of `/boot/firmware/config.txt`:

```
dtparam=i2s=on
dtoverlay=adau7002-simple
```

> **This used to say `googlevoicehat-soundcard`, which was wrong.** Nothing in the project has ever
> used that overlay. `build/customize-image.sh` writes `adau7002-simple` into `config.txt`, and
> `firmware/detect.py` captures from `hw:adau7002,0` — those two agree, and this document was the
> odd one out. If you followed the old instructions and got no capture device, this is why.

  Then reboot:

```bash
sudo reboot
```

## Verify the microphone

After rebooting, check the I2S driver loaded:

```bash
  arecord -l
  ```

  You should see a capture device listed. If nothing appears, double-check the wiring and config.txt entries.

## Test recording

Use the same device and format the firmware uses, so a successful test means the node will work:

```bash
arecord -D hw:adau7002,0 -c2 -r 48000 -f S32_LE -d 5 test.wav
aplay test.wav
```

You should hear 5 seconds of ambient audio played back.
