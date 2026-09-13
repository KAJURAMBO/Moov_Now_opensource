# Moov Now — Android app

A **local-only** personal tracker for the Moov Now. The phone talks to the device over BLE
directly; there is no backend, no server, no account and no cloud. The app requests no
`INTERNET` permission — everything is parsed and stored on the device.

That is deliberate. The original Moov Coach app depended on Moov's servers, so shutting them
down in 2022 bricked the product even though the hardware still worked.

## Status

Early but functional. It connects, streams, decodes and stores. It has **not been run against
hardware from this repo yet** — the protocol and decoder were established on the desktop build
(`backend/`), and this app is a port of them.

## Layout

```
lib/
├── main.dart                  UI: Today, Live, Workout, History
├── moov_controller.dart       app state — wires BLE frames to storage and UI
├── moov/
│   ├── moov_protocol.dart     GATT UUIDs, packet constants (the spec, in code)
│   ├── moov_decoder.dart      sensor frame decoder (port of ble_tools/decoder.py)
│   └── moov_ble_manager.dart  scan / connect / subscribe / enable / keep-alive / reconnect
└── data/
    └── moov_database.dart     local SQLite (port of backend/models.py)
```

## Running

```bash
flutter pub get
flutter run            # device attached
flutter test           # decoder unit tests — no hardware needed
```

On first launch the app asks for Bluetooth (and location on older Android) permission. It then
scans continuously. **Press the Moov's button** — the device only advertises for a few seconds
after a press, so the status chip reads "Press Moov" until it catches one.

## How it talks to the device

The short version; the full spec is in `../ble_tools/protocol_notes.md`.

1. Scan for a device named "Moov", advertising a Moov service UUID, or — as usually happens —
   an unnamed device with a strong signal.
2. Connect (never pair — pairing fails on this hardware and drops the link).
3. Subscribe to `f000cd51`.
4. Write `0x01` to `f000cd52` to start the stream. **Only** that characteristic — writing
   `cd53` or `cd54` makes the device disconnect.
5. Decode 20-byte frames: accelerometer is bytes `[12:18]`, `int16` LE, `÷16384` → g.
6. The firmware sleeps the stream after ~10–20 s; the manager re-writes the enable byte after
   3 s of silence, which resumes it with no user action.

## Known limitations

- Wake the device with its button when it sleeps; there is no way around this from the app.
- The gyroscope and magnetometer channels are not decoded yet, so there is no yaw and Cycling
  cannot be auto-detected — pick it from the workout tabs.
- The step counter is an edge-triggered accelerometer heuristic, not the vendor's algorithm.
  It is plausible, not validated.
- Tracking continues with the screen off via a foreground service, at the cost of a persistent
  notification (Android requires one for background BLE).

## Releasing

`.github/workflows/play_store_deploy.yml` builds and uploads to Play closed testing when a tag
is pushed:

```bash
git tag v1.0.0
git push origin v1.0.0
```

`versionName` comes from the tag and `versionCode` from the workflow run number, so successive
tags always produce an increasing build.

Required repository secrets (Settings → Secrets and variables → Actions):

| Secret | Purpose |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | upload keystore, base64-encoded |
| `ANDROID_KEYSTORE_PASSWORD` | keystore password |
| `ANDROID_KEY_PASSWORD` | key password |
| `ANDROID_KEYSTORE_ALIAS` | key alias |
| `PLAY_SERVICE_ACCOUNT_JSON` | Google Play service account JSON |
