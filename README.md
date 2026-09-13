# 🏃 Moov Now Fitness Tracker — Revival Application & Suite

A complete replacement application and protocol discovery suite for the **Moov Now** 9-axis Omni Motion™ fitness tracker.

---

## 🌟 Features

- 📡 **BLE Device Discovery & Explorer**: Python Bleak tools for scanning nearby BLE hardware, enumerating GATT services/characteristics, and streaming raw notifications.
- 🧭 **Real-Time 3D Motion Orientation**: Three.js WebGL viewport rendering a 3D Moov Now puck that responds live to sensor pitch, roll, and yaw angles.
- 📈 **20 Hz Real-Time Telemetry Graphs**: Multi-dataset Chart.js line charts streaming 9-axis acceleration ($a_x, a_y, a_z$) and landing impact force ($g$).
- ⏱️ **Live Workout Coach**: Session recorder supporting **Running, Cycling, Swimming, Boxing, and Walking** with cadence counters, step tracking, and impact force monitoring.
- 🗄️ **SQLite Data Storage**: Persistent workout history log and daily metrics tracking (steps, calories burned, distance, active minutes).

---

## 📁 Directory Structure

```
d:\MOOV DEVICE CONNECT\
├── ble_tools/
│   ├── scanner.py              # Find Moov Now BLE devices
│   ├── listener.py             # Subscribe to notifications & raw byte dumps
│   ├── decoder.py              # Sensor packet decoder (required by the backend)
│   └── protocol_notes.md       # Verified GATT map & packet format
├── backend/                    # Phase 3 Python FastAPI backend
│   ├── main.py                 # Web server & WebSocket endpoint
│   ├── ble_bridge.py           # Bleak BLE client, auto-connect engine & telemetry broadcaster
│   └── models.py               # SQLite database layer
├── android_app/                # Local-only native Android tracker (Flutter)
│   ├── lib/moov/               # BLE manager, packet decoder, protocol constants
│   ├── lib/data/               # Local SQLite storage
│   └── lib/main.dart           # UI: Today, Live, Workout, History
├── frontend/                   # Phase 3 Cyberpunk/Neon UI
│   ├── index.html              # Dashboard shell
│   ├── styles.css              # Custom design system with glassmorphic cards
│   └── app.js                  # Three.js + Chart.js + WebSocket client
├── run_scanner.py              # Launcher: Scan for devices
├── run_listener.py             # Launcher: Stream live raw notifications
├── start_app.py                # Launcher: Start Web Application Server
├── requirements.txt
├── REVIVAL_NOTES.md
└── README.md
```

---

## 🚀 Quick Start Guide

### 1. Requirements

- Python 3.10+
- Installed dependencies: `bleak`, `fastapi`, `uvicorn`, `websockets`

> **Note:** run the server with UTF-8 forced (`PYTHONUTF8=1`). The emoji banner crashes startup
> with a `UnicodeEncodeError` when stdout is redirected and Python falls back to cp1252.

### 2. Phase 1: Scan for your Moov Now Hardware

1. Press or shake your Moov Now device to wake it up.
2. Run the scanner:

```bash
python run_scanner.py
```

Look for a MAC address printed next to `[MOOV MATCH]` or an un-named device with high RSSI.

### 3. Inspect the live data stream (optional)

```bash
python run_listener.py <DEVICE_MAC>
```

Prints raw notification packets from the sensor characteristic, useful when checking the
decoder against the device.

### 4. Phase 3: Launch the Full Web Application

Start the web server:

```bash
PYTHONUTF8=1 PYTHONIOENCODING=utf-8 python start_app.py
```

Open your browser and navigate to:
👉 **[http://localhost:8000](http://localhost:8000)**

The server scans for the Moov in the background — press the device's button and it connects on
its own, no UI interaction needed.

---

## 📖 Documentation

| Document | Contents |
|---|---|
| `REVIVAL_NOTES.md` | Work log: every bug found and fixed, device power behaviour, known limitations |
| `ble_tools/protocol_notes.md` | Verified BLE protocol — GATT map, connect/stream sequence, packet format |
| `ANDROID_PORT.md` | Spec for a local-only native Android tracker (no backend, no cloud) |
| `android_app/README.md` | Android app: layout, how it talks to the device, releasing |

---

## 🎮 Web Application Controls

- **3D Motion Visualizer**: Rotates in real time matching orientation angles from the sensor.
- **Scan Devices Modal**: Click **"📡 Scan Devices"** in the top right header to scan and connect directly to your physical Moov device via Bluetooth.
- **Workout Sessions**: Choose an activity tab (Run, Cycle, Swim, Box, Walk) and click **"Start Workout Session"**. The timer, step counter, cadence (RPM), and impact force ($g$) will update live.
