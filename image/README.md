# serial2moon Raspberry Pi image

A flash-and-go Raspberry Pi OS (arm64) image with the whole stack — serial2moon +
Moonraker + Mainsail — pre-installed and started at boot. No terminal setup required.

## Use it (for end users)

1. Download `serial2moon-rpi-arm64.img.xz` from the project's **Releases**.
2. Flash it with Raspberry Pi Imager and use the **⚙ OS-customization** step to set a
   username + password, enable **SSH**, and configure **Wi-Fi**/hostname.
3. Connect your printer's USB cable, boot the Pi, and open `http://<pi-hostname>/`
   (Mainsail). Moonraker is on `:7125`.

serial2moon **autodetects** the printer among the connected USB serial devices — no
configuration needed in the common case. If no printer is found it reports an error and
keeps retrying (there is no demo/mock mode in this image).

Optional tuning lives in **`serial2moon.conf`**, editable right in **Mainsail → Machine →
Configuration Files** (next to `moonraker.conf`). It's created automatically on first boot.
After editing, **restart serial2moon** to apply (reboot, or `sudo systemctl restart serial2moon`):
```
RUST_LOG=info,serial2moon=debug   # default: every serial line + diagnostics. "info" = quieter
S2M_EXTRUDER_MAX_TEMP=300    # match your firmware; bounds the UI temp inputs
S2M_BED_MAX_TEMP=120
S2M_PAUSE_LIFT=5             # pause/cancel lift (mm); S2M_PAUSE_RETRACT for retract
#S2M_SERIAL_PORT=...         # pin a /dev/serial/by-id/... path (else autodetect)
#S2M_BAUD=115200             # pin a baud (else autodetect via M115)
```
Steel sheets are auto-discovered from the printer (`M850`) and appear as macro buttons.

**Restarting:**
- **Restart / Firmware Restart** (the dropdown by the emergency-stop button) work as
  expected: *Restart* re-initializes the printer over the existing link, *Firmware Restart*
  drops and reopens the serial connection.
- **Reboot / shut down the Pi:** use the **`HOST_REBOOT`** / **`HOST_SHUTDOWN`** macro
  buttons. (Mainsail's own *Machine → Power* host buttons can't work here — Moonraker runs
  in a container and refuses to reboot the host from inside one. serial2moon instead drops a
  request that a privileged host-side systemd unit acts on.) Anyone with UI access can
  trigger these, just like the physical power button.

Logs are written to Moonraker's logs dir, so `serial2moon.log` is downloadable from
Mainsail's **Machine → Logfiles**. It rotates at 20 MB and keeps the last 10 rotations
gzip-compressed (`serial2moon.log.1.gz` = newest): about 9 print hours in ~55 MB. Adjust via
`S2M_LOG_MAX_SIZE_MB` / `S2M_LOG_MAX_FILES` in `serial2moon.conf`. The containers' stdout
logs (`docker logs`) are capped at 3 × 10 MB each.

Targets **arm64** (Pi 3 / 4 / 5 / Zero 2 W).

## Updating

Updates only install when you ask. Two macros (next to `HOST_REBOOT`) handle them:

- **`HOST_UPDATE_CHECK`** asks the registries whether serial2moon, Moonraker or Mainsail have
  a newer version and reports in the Mainsail console. It changes nothing. The same check runs
  once at boot, and posts a note only when something is newer.
- **`HOST_UPDATE`** downloads the newer images and restarts just those containers; Mainsail
  reconnects by itself. It refuses while a print is running or paused.

Both need internet access. Progress and results show in the console; the full output is in
the journal (`journalctl -u 'serial2moon-update*'`). Re-flashing a newer `.img` also works.

The `.img` ships pinned versions (the minimum a fresh Pi starts with): the serial2moon
release it was built for, Moonraker `v0.11.0-4-gb559b9a`, and Mainsail `v2.19.0`. Updates move
each one forward along the tags in `files/opt/serial2moon/compose.yml`: serial2moon
`stable` (follows releases), Moonraker `latest`, Mainsail `v2`.

## How it's built

`../.github/workflows/image.yml` runs on a published release:

1. Waits for the docker workflow to publish this release's serial2moon image, pulls it plus
   the pinned Moonraker and Mainsail (arm64), tags each with the floating tag the compose file
   uses, and saves them as `*.tar` into `files/opt/serial2moon/images/` (so the Pi loads them
   offline at first boot). Their registry digests go in `images/digests.txt` for the update
   check, since `docker load` drops them.
2. Uses [`pguyot/arm-runner-action`](https://github.com/pguyot/arm-runner-action) to run
   `provision.sh` inside a Raspberry Pi OS image (installs Docker, disables ModemManager,
   installs the stack, `serial2moon.service` and the host-control units).
3. Compresses and attaches `serial2moon-rpi-arm64.img.xz` to the release.

To ship newer Moonraker/Mainsail versions in the image, test them, then bump `MOONRAKER_PIN`
and `MAINSAIL_PIN` in the workflow.

A udev rule (`files/etc/udev/rules.d/99-serial2moon-latency.rules`) drops the USB-serial
latency timer to 1 ms so dense G-code (curves) keeps the printer's planner fed. It applies
to FTDI/CH340 adapters; CDC-ACM devices (e.g. Prusa native USB) have no such knob and are
unaffected.

## Layout

- `provision.sh` — runs inside the image at build time.
- `files/opt/serial2moon/` — the stack: `compose.yml`, `start.sh`
  (boot launcher), `update.sh` (update check/apply), and `images/` (baked container tars).
- `serial2moon.conf` — created in Moonraker's config dir on first run, edited via Mainsail.
- `files/etc/systemd/system/serial2moon.service` — starts the stack at boot.
- `files/etc/systemd/system/serial2moon-{reboot,poweroff,update,update-check}.*` — act on
  the HOST_* macros' request files; `serial2moon-update-notify.service` is the boot check.

## Build locally

You don't need CI. On an x86-64 Linux box with Docker + buildx:

```bash
mkdir -p image/files/opt/serial2moon/images
# arm64 serial2moon image from source, saved under the tag the Pi's compose.yml uses
docker buildx build --platform linux/arm64 -f Dockerfile -t ghcr.io/lukas-heiligenbrunner/serial2moon:stable \
  -o type=docker,dest=image/files/opt/serial2moon/images/serial2moon.tar .
docker pull --platform linux/arm64 mkuf/moonraker:v0.11.0-4-gb559b9a && docker tag mkuf/moonraker:v0.11.0-4-gb559b9a mkuf/moonraker:latest
docker save mkuf/moonraker:latest -o image/files/opt/serial2moon/images/moonraker.tar
docker pull --platform linux/arm64 ghcr.io/mainsail-crew/mainsail:v2.19.0 && docker tag ghcr.io/mainsail-crew/mainsail:v2.19.0 ghcr.io/mainsail-crew/mainsail:v2
docker save ghcr.io/mainsail-crew/mainsail:v2 -o image/files/opt/serial2moon/images/mainsail.tar
# then run pguyot/arm-runner-action's CLI, or replicate provision.sh against a mounted Pi OS image.
```
A locally built serial2moon image has no registry digest, so `HOST_UPDATE_CHECK` will list it
as updatable until it is replaced by a published one.
(The CI workflow is the supported path; local baking needs loop-mount/qemu privileges.)
