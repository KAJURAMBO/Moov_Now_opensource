# Moov Now — Reverse-Engineered BLE Protocol (verified)

Derived from live device inspection (MAC `A0:E6:F8:67:C4:6E`) plus decompilation of the
official **Moov Coach** Android app (package `cc.moov.one`, APK 5.2.5492, decompiled with jadx).

> Earlier versions of this file contained a fabricated service map (`00002b00` / `2b01` / `2b02`).
> That was wrong. The real sensor service is `f000cd50`. See "Corrections" at the bottom.

---

## GATT Services on the Moov Now

| Service | UUID | Notes |
|---|---|---|
| Generic Access | `00001800-...` | Device name, appearance |
| Generic Attribute | `00001801-...` | Service changed |
| Device Information | `0000180a-...` | Manufacturer "Moov Inc.", model, firmware revs |
| **Sensor / "gyroscope" service** | `f000cd50-0451-4000-b000-000000000000` | **Primary data + control service** |
| Nordic UART | `0000ffe0-...` | `ffe1` notify (secondary, unused by us) |
| LED service | `f000cd70-0451-4000-b000-000000000000` | `cd72` config |
| Cloud / user service | `f000cd80-0451-4000-b000-000000000000` | `cd81` device name, `cd82` device id |
| OAD (firmware update) | `f000ffc0-...` | Not used |

### `f000cd50` characteristics

Names come from the app's own `cc.moov.ble.SampleGattAttributes` class.

| Char | App name | Properties | Purpose |
|---|---|---|---|
| `f000cd51` | `GYROSCOPE_DATA` | notify, read | **Sensor data stream — subscribe here** |
| `f000cd52` | `GYROSCOPE_ENABLE_CONFIG` | write, read | **Write `0x01` to start the stream** |
| `f000cd53` | `gyroscope_interval` | write, read | Sample interval (u16 LE ms). Avoid writing — see below |
| `f000cd54` | `gyroscope_command` | write, read | Command channel. Avoid writing — see below |
| `f000cd55` | — | notify, read | Secondary stream |
| `f000cd56` | `gyroscope_blob` | notify, read | Blob/offline buffer. CCCD write is refused (`Write Not Permitted`) |
| `f000cd60` | `gyroscope_max_acc` | — | Max acceleration store |
| `f000cd61` | `gyroscope_address` | write (write-only) | Device address config |
| `f000cd62` | `gyroscope_offline_blob` | write, read | Offline recording buffer |
| `f000cd63` | — | read | Status/version read |
| `f000cd64` | `gyroscope_offline_compression` | — | Offline compression flag |

---

## Connecting and streaming

The verified-minimal sequence. **Do not add to it** — extra writes destabilise the device.

1. Connect (BLE, no bonding/pairing — attempting `pair()` fails and drops the link).
2. `start_notify` on **`f000cd51` only**. Subscribing to `cd55` / `ffe1` as well is harmless
   but unnecessary; it was removed to reduce variables.
3. Write **`0x01`** to **`f000cd52`**. Data starts flowing on `cd51` within ~100 ms.

### Device power behaviour (important)

The Moov Now runs on a coin cell and its firmware **sleeps the stream after roughly
10–20 seconds**. The BLE link may stay up, but notifications stop. This is device firmware
power management, not a bug in the client.

Two mitigations are implemented in `backend/ble_bridge.py`:

- **Keep-alive resume** — when no packet has arrived for >3 s, re-write `0x01` to `cd52`.
  The device resumes streaming without any user action.
- **Drop recovery** — if that write fails, the device has genuinely disconnected; the bridge
  marks itself disconnected and the background auto-connect engine re-establishes the link
  the next time the device advertises.

Writing to `cd53` (interval) or `cd54` (command) noticeably **shortens** the streaming session —
the device drops the link within a few seconds. Both writes were removed.

---

## Data packet format

Notifications on `f000cd51` are **20 bytes**, little-endian.

```
offset  size  content
[0:2]   2     header, always 00 00
[2:8]   6     3 x int16 — varies; NOT a clean rate-gyro (swings full-range even when
              stationary). Purpose not yet identified; likely magnetometer / raw fusion output
[8:12]  4     always 00 00 00 00
[12:18] 6     ACCELEROMETER — 3 x int16 LE, scale 16384 LSB per g  (±2 g range)
[18]    1     sequence counter, 0-255 wrapping (increments once per packet)
[19]    1     always 00
```

### Accelerometer (verified)

`value_g = int16_le(bytes[12:18]) / 16384.0`

Verification: with the device lying flat and stationary, the decoded vector is
`(≈0, ≈0, ≈-1.0) g` — magnitude 1.0 g, gravity on the z axis. During walking/running the
magnitude rises to 1.3–3.2 g. Axes respond correctly to rotation.

Derived in `ble_tools/decoder.py`:
- `pitch = atan2(ay, sqrt(ax² + az²))`
- `roll  = atan2(-ax, az)`
- `impact_g = |accel|`
- Activity classification is accelerometer-only (see caveat below).

### Not yet decoded

- Bytes `[2:8]` — three high-variance channels. They do not behave like a rate gyro: they swing
  across the full ±32768 range even while the accelerometer is perfectly stable. They may be
  magnetometer readings affected by nearby electronics, or a fused/raw intermediate. Activity
  detection deliberately ignores them.
- Magnetometer and true gyroscope axes have not been identified.

The authoritative parser lives in the app's native library (`libbridge.so`, ~21 MB per ABI,
exposed via JNI as `BleBridge.nativeCharacteristicNotifyHandler`). Its logic is compiled C++
with no useful exported names, so the layout above was established empirically instead.

---

## App architecture (from `libbridge.so`)

Symbols extracted from the app's native library clarify how the official app drives the device.

```
c_sensor_tag                          per-device manager
 └── c_ble_gyro_service               BLE wrapper for the f000cd50 service
      ├── turn_on() / turn_off()
      ├── toggle_gyro_data_notification(bool)
      └── on_characteristic_notify(uuid, pkt, len, ...)   <- packet parser entry
 └── c_gyro_service_logic             logic layer
      ├── init(adapter) / turn_on() / turn_off()
      ├── toggle_data_notification(bool)
      └── notify_characterstic_update(key, pkt, len, ...)  <- packet parse logic
 └── c_ble_led_service, c_ble_cloud_service, c_ble_battery_service,
     c_ble_heart_rate_service, c_ble_oad_service, c_ble_device_info_service,
     c_ble_simple_keys_service
```

**Enable semantics:** `turn_on()` writes the value `1`, `turn_off()` writes `0`, and
`toggle_data_notification(bool)` writes the boolean. Writing `1` is therefore **idempotent** —
re-sending it does not toggle the stream back off. This validates the keep-alive approach used
by our bridge.

**No keep-alive exists in the app.** There is no ping/heartbeat loop anywhere in the gyro
service. The app turns the sensors on when a live workout screen is open and off afterwards.
In other words the official app does not fight the device's stream sleep either — it works in
sessions.

**The device also records offline.** Alongside live streaming, the app has a full offline path:
`gyroscope_offline_blob` (`cd62`), `BleActivityIntendToSyncEvent`,
`BleActivitySyncProgressEvent`, `BleDeviceDidGetOfflineAndCollectDataEvent`,
`ActivityDataSyncManager`, and swim/erase-flash routines. The device buffers activity data on
board and the app syncs it after the fact. This is the mechanism that yields complete workouts
even when the live stream is intermittent.

---

## Hardware capabilities

| Feature | Present? |
|---|---|
| 3-axis accelerometer | Yes |
| Gyroscope / magnetometer | Sensor present (9-axis part), channels not yet mapped |
| Heart rate | **No** — the device has no HR service (`0x180D` absent) |
| GPS | No |
| Battery | Yes, standard Battery Service (`0x180F`, `2a19`) — read-only value observed: 30 (raw) |

The Moov Coach app *does* reference `0000180d` (Heart Rate Service) and `00002a37`
(Heart Rate Measurement) — that is for pairing an **external chest strap**, not for the Moov Now.

---

## Corrections to earlier notes

| Earlier claim | Reality |
|---|---|
| Sensor service `00002b00`, data `2b01`, control `2b02`, summary `2b03` | Fabricated. Real service is `f000cd50`; data `cd51`, enable `cd52` |
| 18-byte frame, `<hhhhhhHhh`, accel scale 16/32768 | Wrong. 20-byte frame; accel is bytes `[12:18]` at 16384 LSB/g |
| Command sequences `0x01 0x01 0x32`, `0x02 0x00`, etc. | Not real. Only `0x01` → `cd52` is verified |
| `gatt_dump.json` describes the Moov Now | It is a dump of the user's **iPhone** (name "Rahman's iPhone", Apple Inc., `iPhone14,5`) |
