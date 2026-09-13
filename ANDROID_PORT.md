# Moov Now — Android Port Spec

Target: a **local-only native Android app**. No backend, no server, no cloud, no account.
The phone talks to the Moov over BLE directly, parses and stores everything on-device, and
never needs a network connection. This is the architecture the original Moov Coach app lacked —
it depended on Moov's servers, so shutting them down bricked the product.

```
Moov Now ──BLE──► Android app ──► local SQLite (Room) ──► UI
                   (single process: scan, connect, parse, store, render)
```

Nothing else is required at runtime. The Python backend and dashboard in this repo are the
reference implementation — they are how the protocol was established, not a component the
Android app depends on.

---

## 1. What ports over unchanged

The hard part (the protocol) is already solved. These are direct ports.

| Thing | Value / behaviour |
|---|---|
| Sensor service | `f000cd50-0451-4000-b000-000000000000` |
| Data characteristic (subscribe) | `f000cd51` — notify |
| Enable characteristic (write) | `f000cd52` — write `0x01` to start streaming |
| Do **not** write | `f000cd53` (interval), `f000cd54` (command) — these make the device drop the link |
| Packet length | 20 bytes, little-endian |
| Accelerometer | bytes `[12:18]`, 3 × int16 LE, **÷16384 → g** (±2 g range) |
| Sequence counter | byte `[18]`, 0–255 wrapping (app validates continuity) |
| Device quirk | firmware sleeps the stream after ~10–20 s → re-write `0x01` to `cd52` after 3 s of silence |
| Advertising | device often appears as `Unknown Device` with no service UUIDs; name may contain "Moov" |

Full reference: `ble_tools/protocol_notes.md`.

### Decoder (port of `ble_tools/decoder.py`)

```
ax, ay, az = int16le(pkt[12:18]) / 16384.0        # g
magnitude  = sqrt(ax² + ay² + az²)                # impact_g
pitch      = atan2(-ax, sqrt(ay² + az²)) * 180/π
roll       = atan2(ay, -az) * 180/π
yaw        = 0   (needs the gyro channel, not yet decoded)

step:  edge-triggered — count one step when magnitude rises above 1.45 g,
       re-arm once it falls below 1.15 g

activity (magnitude):
       < 1.15 g  → Idle
       < 1.75 g  → Walking
       < 2.60 g  → Running
       else      → Boxing
```

Note bytes `[2:8]` are not yet identified (they swing full-range even when stationary, so they
are not a clean rate gyro). Gyroscope and magnetometer axes are still undecoded — yaw is
therefore 0 and Cycling cannot be auto-detected.

---

## 2. BLE mapping (Python/Bleak → Android)

| Python (Bleak) | Android |
|---|---|
| `BleakScanner(detection_callback=…)` | `BluetoothLeScanner.startScan(callback)` |
| `BleakClient(device)` | `device.connectGatt(context, false, gattCallback)` |
| `start_notify(uuid, handler)` | `setCharacteristicNotification(char, true)` + write `0x2902` CCCD = `ENABLE_NOTIFICATION_VALUE` |
| `write_gatt_char(uuid, b"\x01")` | `gatt.writeCharacteristic(char.apply { value = byteArrayOf(1) })` |
| notification callback | `onCharacteristicChanged(gatt, char)` |

Android writes are asynchronous and serialised — queue GATT operations (one at a time) or later
writes return `false`. This is the most common BLE bug on Android.

---

## 3. Data model (port of `backend/models.py`)

```
workouts(id, activity_type, start_time, end_time, duration_sec, total_steps,
         avg_cadence_rpm, max_impact_g, calories_burned, distance_km, notes)

daily_stats(date PK, total_steps, active_minutes, active_seconds,
            calories_burned, distance_km, last_updated)

telemetry_snapshots(id, timestamp, workout_id, accel_x/y/z, gyro_x/y/z,
                    impact_g, cadence_rpm, activity)
```

Totals are accumulated at full precision and rounded only for display — rounding a running
total discards the small per-step increments and the values never move off zero.

Derived values: calories = steps × 0.045 kcal, distance = steps × 0.0008 km.

---

## 4. Screens

1. **Dashboard** — today's steps / active minutes / calories / distance + goal progress
2. **Live** — 3D orientation, real-time chart, current activity, step count
3. **Workout** — start/stop a session (Run, Cycle, Swim, Box, Walk), live timer and metrics
4. **History** — past sessions with date, duration, steps, cadence, impact, calories
5. **Device** — connection status, scan/connect, battery

---

## 5. Android specifics

**Permissions**
- Android 12+: `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`
- Android ≤ 11: `BLUETOOTH`, `BLUETOOTH_ADMIN`, plus `ACCESS_FINE_LOCATION` for scanning
- `FOREGROUND_SERVICE` (+ `FOREGROUND_SERVICE_CONNECTED_DEVICE` on 14+) to survive screen-off

**Reliability**
- Run scanning/streaming in a **foreground service** with a persistent notification — a plain
  Activity gets killed in the background and tracking stops
- Ask the user to exempt the app from battery optimisation, otherwise long sessions are killed
- Auto-reconnect on `onConnectionStateChange` disconnect
- Keep-alive: if no notification for ~3 s, re-write `0x01` to `cd52`

**Avoid**
- Requesting bonding/pairing — it fails on this device and drops the link
- Writing `cd53`/`cd54` — causes disconnects
- Assuming the device stops advertising: it only advertises briefly after a button press, so the
  UI should tell the user to press the puck when it goes silent

---

## 6. Suggested stack

- **Kotlin** + Jetpack Compose
- **Room** for storage, **Coroutines/Flow** for the BLE stream
- Single `MoovBleManager` class owning scan/connect/notify/keep-alive, exposing a
  `Flow<SensorFrame>` — this is the direct analogue of `backend/ble_bridge.py`
- `MoovPacketDecoder` as a pure Kotlin object — a line-by-line port of `ble_tools/decoder.py`

Keep the BLE layer, the decoder, and the storage layer three separate modules. That is what made
the desktop version debuggable, and it will make the Android version testable without a device.

---

## 7. Port checklist

- [ ] `MoovPacketDecoder.kt` — port decoder.py, unit-test against captured packets
- [ ] `MoovBleManager.kt` — scan, connect, subscribe `cd51`, enable `cd52`, keep-alive, reconnect
- [ ] Room entities + DAO matching the three tables
- [ ] Daily totals accumulator (full precision, rounded for display only)
- [ ] Step edge-trigger + activity classifier
- [ ] Dashboard / Live / Workout / History / Device screens
- [ ] Foreground service + battery-optimisation exemption prompt
- [ ] Instrumented test: press puck → connects → steps increment

---

## 8. Open items

- Gyroscope / magnetometer channels (`[2:8]`) undecoded — would give yaw and real cycling detection
- Offline data recorded on the device (`cd62` offline blob) not yet reverse-engineered — the
  original app synced these, and they are how a full workout is recovered if the live stream
  dropped. Worth revisiting once the live path is solid.
- Battery percentage is a placeholder; the Battery Service (`0x180F`, `0x2A19`) reads but is
  not wired up
