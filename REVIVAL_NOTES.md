# Moov Now Revival — Work Log

Record of the reverse-engineering and fixes applied to get the Moov Now streaming into
the dashboard. Read alongside `ble_tools/protocol_notes.md`, which holds the verified
device protocol.

---

## Summary

The device now: auto-connects on button press with no UI interaction, streams real
accelerometer data, survives the firmware's ~20 s stream sleep via keep-alive resume, and
feeds live motion + step/calorie/distance figures to the dashboard. The decoder produces
physically meaningful values (≈1 g at rest, 1.3–3.2 g walking/running).

---

## Problems found and fixed

### 1. `gatt_dump.json` was not the Moov at all

The file, and `protocol_notes.md` derived from it, described a **different device** — it is a
dump of the user's iPhone (`Rahman's iPhone`, `Apple Inc.`, `iPhone14,5`). Every UUID and
command sequence derived from it was wrong. Replaced with a protocol established from live
inspection and from the official app's own source (see `protocol_notes.md`).

### 2. The activation command was never sent

`connect_to_device()` decided which characteristic to write the "start stream" command to by
substring-matching the **characteristic** UUID against `["2b02", "d061", "9fa4", "9a3f"]`.
The real control characteristic is `f000cd52`, which matches none of those patterns — so the
device was connected and subscribed, but never told to stream. Result: "connected but no
tracking".

Fixed by matching on the **service** UUID (`f000cd50`) and targeting `cd52` explicitly.

### 3. Auto-connect was a lottery

The environment has many BLE devices that advertise continuously but are not connectable
(symptom: `Device with address ... was not found` on connect — iPhones, watches, earbuds,
routers). The old latch logic grabbed whichever non-excluded device had the strongest signal,
so the real Moov was starved.

Fixed with three layers:
- **Tiered candidate selection** — a Moov-signature device (advertised name containing
  "moov", or a known Moov service UUID) locks in immediately and always beats a generic
  strong signal. The Moov advertises as "Unknown Device" with no service UUIDs, so a generic
  strong device is still used as a fallback.
- **Static excludes** for known nuisance MACs.
- **3-strike runtime blacklist** — any device that fails to connect three times is banned for
  the session, so nuisances do not consume every scan cycle.

### 4. The device kept dropping the link

Writing `cd53` (interval) and `cd54` (command) after enabling the stream caused the device to
disconnect within seconds. The handshake was reduced to the verified minimum:
subscribe `f000cd51`, write `0x01` to `f000cd52`. Service subscriptions were also narrowed
from "all notify characteristics" to `cd51` only.

### 5. The server deadlocked (this caused the "UI stuck" reports)

The Bleak notification callback runs on a **separate OS thread**, not the asyncio event loop.
It was calling `models.update_today_steps()` — a SQLite write — from that thread. Under load
this deadlocked against the event loop's own database reads and froze the entire server: every
endpoint, including `/` and `/api/status`, timed out while packets kept arriving.

Fixed by moving all SQLite access to the event loop thread. The BLE callback only updates
in-memory state and buffers step deltas; the broadcaster loop flushes them to the database.

### 6. Per-packet broadcast task storm

The notification handler created an asyncio task per packet (throttled, but the stream runs at
50–100 Hz and the throttle was mis-counted). This saturated the event loop. Replaced with a
single **20 Hz broadcaster task**, started on connect and stopped on disconnect. `broadcast()`
also wraps each websocket send in a 1 s timeout so one stale client cannot stall the loop.

### 7. Decoder produced impossible values

The decoder parsed packets as an 18-byte `<hhhhhhHhh` frame, yielding accelerations of 15 g+
at rest. Replaced with the real 20-byte layout: accelerometer is bytes `[12:18]`, three
int16 little-endian, **16384 LSB per g**. Verified against a flat-stationary capture
(gravity ≈ 1.0 g on z).

Activity classification and step detection were re-derived from the accelerometer only, since
the gyro channel is not yet identified.

### 8. Steps counted erratically

The old rule (`magnitude > 1.35 AND |magnitude − 1.0| > 0.45`, evaluated per packet) produced
bursts of counts at stream rate and missed ordinary walking. Replaced with an
**edge-triggered** counter: a step is counted the first time magnitude rises above 1.45 g, and
the detector re-arms once it falls below 1.15 g. One step per bounce, at any stream rate.

### 9. Dashboard statistics only updated on page reload

The steps / calories / distance / active-minutes cards were populated by a single
`fetch('/api/daily_stats')` on page load. The WebSocket updates motion only, so those cards
appeared frozen until a manual refresh. Added a 3-second poll in `frontend/app.js`.

### 10. Server crashed on startup under redirected output

`start_app.py` prints an emoji banner. When stdout is not a real console (redirected to a
file), Python picks the cp1252 codec and the emoji raises `UnicodeEncodeError`, killing the
process before uvicorn binds. Run with UTF-8 forced — see "Running" below.

---

## Device power behaviour (not a bug)

The Moov Now's firmware **sleeps the stream after roughly 10–20 seconds**. The link may stay
up while notifications stop. The bridge re-writes the enable command after 3 s of silence and
the device resumes by itself — so data arrives in bursts without any user action. A genuinely
dropped link is detected when that write fails, and the background auto-connect engine
re-establishes it.

Truly gapless streaming would require the firmware's internal "start session" command. That
logic is compiled into `libbridge.so` with no usable symbols; the current burst + resume
behaviour is the practical optimum until it is extracted.

---

### 11. Simulation and synthetic data removed entirely

The dashboard originally shipped a synthetic motion generator, seeded demo workouts, and UI
controls to switch between "live" and "simulated" modes. With a working device these only
served to make real behaviour hard to read, so all of it was removed:

- Backend: the simulation loop, `start_simulation` / `stop_simulation`, the
  `/api/simulation/toggle` endpoint, and every synthetic fallback (a failed connect now simply
  stays disconnected and lets the auto-connect engine retry).
- Database: the `seed_initial_data()` demo workouts and the seeded daily-stats row.
- Frontend: the "⚡ Toggle Mode" header button, the "⚡ Use Simulation Mode" button, and the
  simulated-status branch. The header now reads "Waiting for Moov" until the device connects.
- The `simulation` field was dropped from the telemetry payload.

### 12. Daily totals never advanced (calories, distance, active minutes)

`update_today_steps()` rounded the running total on every call:

```python
new_calories = round(current + calories_delta, 1)   # 0.0 + 0.04 -> 0.0
new_dist     = round(current + distance_delta, 2)   # 0.0 + 0.0008 -> 0.0
new_active_min = current + int(active_sec_delta/60) # int(1/60) -> always 0
```

Each per-step increment was smaller than the rounding step, so it was discarded before it could
accumulate — steps (integers) moved, everything derived from them stayed at zero. Totals are now
stored at full precision (`calories` 4 dp, `distance` 6 dp) and rounded only for display, and a
new `active_seconds` column accumulates real elapsed time so active minutes can actually reach 1.

### 13. Orientation and activity bugs

- `roll` used `atan2(-ax, az)`, which flips to ±180° whenever `az` is negative — a resting
  device reported roll ≈ -142°. Both angles are now measured from `-az` (the device's flat
  reference), keeping them inside ±90°.
- Activity classification treated anything above 0.6 g as "Cycling", so a stationary device
  (magnitude ≈ 1 g) reported Cycling. Thresholds reworked around gravity: below 1.15 g is Idle.
  Note this makes automatic Cycling detection impossible without the gyroscope — the activity
  tabs still start a Cycling session manually.

---

## Files changed

| File | Change |
|---|---|
| `backend/ble_bridge.py` | Auto-connect engine, tiered candidate selection, nuisance blacklist, minimal handshake, keep-alive resume, drop recovery, 20 Hz broadcaster, thread-safe step handling, edge-triggered step detection, real-state broadcast on connect |
| `backend/main.py` | Starts the background auto-connect engine on startup |
| `ble_tools/decoder.py` | Real 20-byte packet format; accelerometer from bytes `[12:18]` at 16384 LSB/g; accelerometer-only activity and step logic |
| `ble_tools/protocol_notes.md` | Rewritten with the verified protocol; fabricated content marked as such |
| `frontend/app.js` | Daily statistics polled every 3 s |

---

## Running

The server must run with UTF-8 forced, otherwise the emoji banner crashes startup when output
is redirected:

```bash
PYTHONUTF8=1 PYTHONIOENCODING=utf-8 python -u start_app.py
```

Then open <http://localhost:8000>. Press the Moov button to wake the device — the app connects
on its own; no button in the UI is required.

To inspect the raw stream:

```bash
PYTHONUTF8=1 python run_listener.py A0:E6:F8:67:C4:6E
```

---

## Known limitations

- **Gyroscope / magnetometer not decoded.** Bytes `[2:8]` are high-variance and do not behave
  like a rate gyro; yaw is reported as 0. Orientation is accelerometer-derived (pitch/roll).
- **Streaming is bursty** (~20 s of data, brief gap, automatic resume) due to device firmware.
- **Battery percentage is not decoded** — the payload reports a fixed placeholder value.
- **Activity classification** uses accelerometer magnitude thresholds only; cycling in
  particular is approximated and will misfire.
- The environment contains many non-connectable BLE devices; the blacklist handles them, but a
  very noisy location can still slow the first connection.
