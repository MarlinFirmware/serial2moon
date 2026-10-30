# serial2moon

Run the modern Klipper web frontends (**Mainsail** / **Fluidd**) on a **legacy Marlin
printer** — no firmware change.

serial2moon is a small Rust daemon for a Raspberry Pi (or any Linux host). It talks
**Marlin G-code over USB serial** to the printer while pretending to be a **Klipper API
server** on a Unix socket. Moonraker connects to that socket thinking it's Klipper, so the
whole Mainsail/Fluidd + Moonraker stack just works against a printer that only speaks plain
Marlin G-code.

```
 Mainsail/Fluidd ──HTTP/WS──▶ Moonraker ──UDS (Klipper API)──▶ serial2moon ──USB serial──▶ Marlin printer
```

Tested end-to-end on an **Original Prusa i3 MK3S** with real Moonraker + Mainsail.

## Using it with Marlin (MarlinFirmware fork)

This fork is where serial2moon is made to work with **plain Marlin** (not just Prusa firmware), and
with the **Marlin simulator**. The work lives on the
[`marlin-connector`](https://github.com/MarlinFirmware/serial2moon/tree/marlin-connector) branch
while it goes upstream as separate pull requests
([#3](https://github.com/Lukas-Heiligenbrunner/serial2moon/pull/3),
[#4](https://github.com/Lukas-Heiligenbrunner/serial2moon/pull/4),
[#5](https://github.com/Lukas-Heiligenbrunner/serial2moon/pull/5),
[#6](https://github.com/Lukas-Heiligenbrunner/serial2moon/pull/6),
[#7](https://github.com/Lukas-Heiligenbrunner/serial2moon/pull/7)).
**Use the `marlin-connector` branch and its image for Marlin**; this `master` branch is upstream's
code plus this note. When those PRs are released, use upstream's `:stable` image instead.

What `marlin-connector` adds over upstream:

- **TCP transport** (`--transport tcp`, `S2M_TCP_ADDR`) for the Marlin simulator and network serial bridges.
- **Printer limits from the printer**: travel limits from the `M115` geometry report and speed /
  acceleration from `M503`, instead of command-line defaults. `--bed-size`, `--max-velocity` and
  `--max-accel` still override.
- **Prusa-only commands are skipped on other firmware** (`M601`/`M602`/`M603`, `M79`, `M850`).
- The firmware name is reported as **`app`** in `printer.info` (`Marlin`, `Prusa-Firmware`, ...).
- `RESPOND` prints to the console; a real config file and Klipper path are reported to Moonraker
  (no more missing-folder warnings).

### 1. Set up Marlin (optional but recommended)

No firmware change is required. These options make Mainsail more accurate. From a Marlin checkout:

```bash
buildroot/bin/opt_enable EMERGENCY_PARSER ADVANCED_OK AUTO_REPORT_POSITION AUTO_REPORT_REAL_POSITION \
  REPORT_FAN_CHANGE M114_REALTIME M115_GEOMETRY_REPORT CANCEL_OBJECTS SET_PROGRESS_MANUALLY
buildroot/bin/opt_set BUFSIZE 8
```

- `EMERGENCY_PARSER` makes `M112` (the emergency stop button) work while a print streams.
- `M115_GEOMETRY_REPORT` lets serial2moon read the machine's travel limits at connect.
- `ADVANCED_OK` and a larger `BUFSIZE` let the host keep more lines in flight.
- `HOST_ACTION_COMMANDS` and `HOST_PROMPT_SUPPORT` (on by default) pass pause, resume, cancel and
  filament prompts from the printer's LCD to Mainsail.
- Leave `AUTO_REPORT_FANS` **off**: it reports fan tachometer RPM, not fan speed, and needs a tach pin.

### 2. Run the stack with Docker

```bash
mkdir serial2moon && cd serial2moon
curl -fsSLO https://raw.githubusercontent.com/MarlinFirmware/serial2moon/marlin-connector/install/compose.yml
docker compose up -d
# Mainsail:  http://localhost:8088      Moonraker: http://localhost:7125
```

A USB printer is autodetected; this needs a **Linux** host (Docker Desktop on macOS/Windows can't pass
USB through). Settings go in a `.env` file next to `compose.yml`; the comments at the top of the file
list them (`S2M_SERIAL_PORT`, `S2M_BAUD`, `MAINSAIL_PORT`, `PRINTER_NAME`, `S2M_IMAGE`, any `S2M_*`).
Needs Docker Compose v2.24 or newer. Update with `docker compose pull && docker compose up -d`, never
during a print. The image is `ghcr.io/marlinfirmware/serial2moon:marlin-connector`.

The same stack, plus an OctoPrint file, is also in the Marlin repository under
`buildroot/share/hosts/` (`mainsail.yml`, `octoprint.yml`), once MarlinFirmware/Marlin#28759 is merged.

The ready-made Raspberry Pi image from upstream's Releases page still works with Marlin, but it
carries upstream's serial2moon, so it lacks the changes above until they are released.

### 3. Try it with the Marlin simulator (no printer)

1. Build the simulator from the *Simulator* example configuration and **enable `SERIAL_PORT_2`**
   (`buildroot/bin/opt_enable SERIAL_PORT_2`). Without it the simulator's G-code socket accepts
   connections but Marlin never reads them. Add the options from step 1.
2. Run it: `MarlinSimulator --serial-port 8099`.
3. Point the stack at it, in `.env` next to `compose.yml`:

   ```
   S2M_TRANSPORT=tcp
   S2M_TCP_ADDR=host.docker.internal:8099
   ```

   then `docker compose up -d`, and open http://localhost:8088.

The simulator's socket serves **one client at a time**, and a new connection *replaces* the old one.
Give each host (serial2moon, OctoPrint, ...) its own simulator with its own `--serial-port`. The
simulator runs at real time by default, so a `G28` can take minutes; raise the speed with
`curl -X POST localhost:<agent-port>/kernel/control -d '{"realtime_scale":30}'` (start the simulator
with `--agent-port <n>`).

### Limits with Marlin

- Marlin has no command that reports which axes are homed, so the web UI's homed axes are inferred
  from the `G28` commands serial2moon sent.
- Klipper-only features (input shaper calibration, `BED_MESH_CALIBRATE`, Klipper macros) are accepted
  but don't map to Marlin. Use Marlin's G-codes in the console.
- Mainsail labels the backend "Klipper" in its connection screens. That text is Mainsail's.
- Tested with the Marlin simulator and Prusa firmware; not yet with other real printers over USB.

More: the Marlin repository's `buildroot/skills/marlin-hosts-in-docker` and
`buildroot/skills/marlin-mainsail-connector` describe running Mainsail and OctoPrint against the
simulator.

## What works

- Live temperatures, fan, and toolhead position / homed axes (tracked from the G-code we
  send, since Marlin doesn't stream position).
- Print **start / pause / resume / cancel** with byte-accurate progress. On Prusa firmware,
  pause is the printer's own (`M601`/`M602`): it parks, cools the nozzle, shows *Print
  paused* with *Resume* on its LCD, and reheats and continues exactly where it left off.
  Other Marlin printers are parked from the host (lift + present bed).
- **Filament change and runout**: `M600` in the G-code and a runout detected by the
  printer's sensor show as *paused* while you swap filament on the LCD; lines the printer
  discards on runout (or crash recovery) are re-sent, so nothing is skipped.
- File upload, print queue, and the console — driven straight from Mainsail.
- Pause/resume/cancel from the **printer's own LCD** too.
- **Steel sheets** (Prusa `M850`) auto-discovered and shown as selectable macro buttons.
- **Klipper / Firmware restart** from the UI, and optional **host reboot/shutdown** macros.
- Robust serial: line numbers + checksums, automatic resend on a lost/garbled line, and
  automatic reconnect if the printer is unplugged or power-cycled.
- A built-in **mock printer**, so you can try the whole stack with no hardware.

## Getting started

Pick the option that fits you. Most people want option 1.

### 1. Flash the ready-made Raspberry Pi image (easiest)

A complete image with serial2moon + Moonraker + Mainsail pre-installed and starting at boot.

1. Download `serial2moon-rpi-arm64.img.xz` from the
   [**Releases**](https://github.com/Lukas-Heiligenbrunner/serial2moon/releases) page.
2. Flash it with [Raspberry Pi Imager](https://www.raspberrypi.com/software/). In the
   **⚙ OS customisation** step, set a username + password, your Wi-Fi, a hostname, and
   enable **SSH**.
3. Plug the printer into a USB port, boot the Pi, and open `http://<hostname>/` for Mainsail
   (Moonraker is on `:7125`).

The printer is **autodetected** — no config needed in the common case. For tuning options
and how host reboot/shutdown works, see [`image/README.md`](image/README.md).

Targets **arm64** (Pi 3 / 4 / 5 / Zero 2 W). To update, run the **`HOST_UPDATE_CHECK`** and
**`HOST_UPDATE`** macros in Mainsail (updates only ever install when you ask; see
[`image/README.md`](image/README.md#updating)).

### 2. Docker Compose on an existing Pi / Linux host

If you already run Docker, one self-contained file brings up the whole stack from the
published images (`ghcr.io/marlinfirmware/serial2moon`, Moonraker, Mainsail). It
needs Docker Compose v2.24 or newer.

```bash
mkdir serial2moon && cd serial2moon
curl -fsSLO https://raw.githubusercontent.com/MarlinFirmware/serial2moon/marlin-connector/install/compose.yml
docker compose up -d
# Mainsail:  http://localhost:8088
# Moonraker: http://localhost:7125
```

The USB printer is autodetected. Settings go in a `.env` file next to `compose.yml`
(`S2M_SERIAL_PORT=/dev/serial/by-id/...`, `S2M_BAUD`, `MAINSAIL_PORT`, `PRINTER_NAME`; any
`S2M_*` option works). The comments at the top of [`install/compose.yml`](install/compose.yml)
list them. USB printers need a Linux host; Docker Desktop on macOS/Windows can't pass USB
through. To drive a printer or simulator over the network instead, set `S2M_TRANSPORT=tcp`
and `S2M_TCP_ADDR=<host>:<port>`.

**Update** (not while printing): `docker compose pull && docker compose up -d`.

**Try it with the mock printer (no hardware), from a clone:**

```bash
git clone https://github.com/Lukas-Heiligenbrunner/serial2moon.git
cd serial2moon
docker compose up --build
# Mainsail:  http://localhost:8088
# Moonraker: http://localhost:7125
```

Upload a `.gcode` in Mainsail and print it — progress, pause/resume, and temperatures all
work against the simulated printer. This `compose.yml` builds serial2moon from source, for
development; `compose.sim.yml` points it at the Marlin simulator instead (see Development).

#### Versions

The stack follows Moonraker's and Mainsail's releases (`mkuf/moonraker:latest`, Mainsail
`v2`). Tested with **Moonraker v0.11.0-4-gb559b9a** and **Mainsail v2.19.0** or newer; the
Pi image ships exactly these.

### 3. Run the binary directly (advanced / development)

```bash
# Mock printer, no hardware:
cargo run -- --transport mock --uds-path /tmp/klippy_uds --gcode-dir ./gcodes

# Real printer:
cargo run -- --transport serial \
  --serial-port /dev/serial/by-id/usb-YOUR-PRINTER \
  --uds-path /home/pi/printer_data/comms/klippy.sock \
  --gcode-dir /home/pi/printer_data/gcodes
```

Then point Moonraker at the socket with `klippy_uds_address: <your --uds-path>`.

## Configuration

Set options via CLI flags or environment variables (a `.env` file is auto-loaded; see
[`.env.example`](.env.example)). On the prebuilt image, the same settings live in an
editable `serial2moon.conf` shown next to `moonraker.conf` in Mainsail.

| Flag / env | Default | Meaning |
|---|---|---|
| `--transport` / `S2M_TRANSPORT` | `mock` | `mock`, `serial` or `tcp` |
| `--serial-port` / `S2M_SERIAL_PORT` | autodetect | serial device (serial mode) |
| `--tcp-addr` / `S2M_TCP_ADDR` | `127.0.0.1:8099` | `host:port` of a raw G-code socket (tcp mode) |
| `--baud` / `S2M_BAUD` | autodetect | serial baud (probes + gates on `M115`) |
| `--uds-path` / `S2M_UDS` | `/tmp/klippy_uds` | socket Moonraker connects to |
| `--gcode-dir` / `S2M_GCODE_DIR` | `./gcodes` | gcode files (must match Moonraker) |
| `--bed-size` / `S2M_BED_SIZE` | from printer, else `220,220,250` | advertised X,Y,Z limits (overrides the printer's M115 geometry report) |
| `--max-velocity` / `S2M_MAX_VELOCITY` | from printer, else `300` | advertised max velocity (overrides `M203` X/Y) |
| `--max-accel` / `S2M_MAX_ACCEL` | from printer, else `3000` | advertised max accel (overrides `M204 P`) |
| `--config-file` / `S2M_CONFIG_FILE` | — | editable settings file; reported to Moonraker as the config file |
| `--klipper-path` / `S2M_KLIPPER_PATH` | `/opt/serial2moon` | path Moonraker serves `config/` and `docs/` from |
| `--extruder-max-temp` / `S2M_EXTRUDER_MAX_TEMP` | `300` | bounds the UI temp input |
| `--bed-max-temp` / `S2M_BED_MAX_TEMP` | `120` | bounds the UI temp input |
| `--pause-lift` / `S2M_PAUSE_LIFT` | `5` | Z lift (mm) on pause/cancel (Prusa: passed to `M601`) |
| `--pause-retract` / `S2M_PAUSE_RETRACT` | `1` | retract (mm) on pause/cancel (Prusa pause: the firmware's own) |
| `--log-dir` / `S2M_LOG_DIR` | — | also write logs to this dir |
| `--log-max-size-mb` / `S2M_LOG_MAX_SIZE_MB` | `20` | rotate `serial2moon.log` at this size |
| `--log-max-files` / `S2M_LOG_MAX_FILES` | `10` | rotated logs kept, gzip-compressed (`0` = none) |
| `RUST_LOG` | `info,serial2moon=debug` | log verbosity |

## Limitations

- Marlin G-code only; developed and tested against Prusa firmware (MK3S). Other Marlin
  printers should work but aren't verified.
- Klipper-only features (pressure advance, input shaping, bed mesh, etc.) are accepted but
  do nothing — they don't apply to a Marlin printer.
- Single extruder + single bed.
- G-code is streamed one line at a time (depth-1 handshake). A lost line/`ok` is recovered
  by resending, which can cause a brief pause; very dense moves over a slow/noisy USB link
  may not feed fast enough.
- **No power-loss recovery** — an interrupted print can't be resumed.

## Development

```bash
cargo test       # unit tests + a real-PTY serial integration test
cargo clippy
cargo fmt
```

The PTY test uses Linux-only `nix` calls, so on macOS run the suite in a container:

```bash
docker run --rm -v "$PWD":/src -w /src -v s2m-cargo:/usr/local/cargo/registry \
  -v s2m-target:/src/target rust:1-slim-bookworm cargo test
```

**Against the Marlin simulator:** run [MarlinSimUI](https://github.com/MarlinFirmware/MarlinSimUI)'s
`MarlinSimulator` on the host (raw G-code socket on TCP 8099), then:

```bash
docker compose -f compose.yml -f compose.sim.yml up -d --build   # Mainsail on :8088
```

Layout: `src/state` is the single source of truth (one actor task, `watch` snapshots).
`src/transport` is the byte stream (`serial.rs` real port, `mock.rs` in-process Marlin sim).
`src/serial_session` is the sole writer to the printer (priority inbox + `ok` handshake).
`src/klipper_api` is the Unix-socket server (0x03 framing, method dispatch, subscription
deltas). `src/gcode` translates commands; `src/print_job` streams files to the printer.

## License

[MIT](LICENSE) © Lukas Heiligenbrunner
