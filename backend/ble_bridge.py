"""
BLE Bridge for Moov Now telemetry.
Manages the live Bleak connection and streams decoded sensor data to the UI.
"""

import asyncio
import json
import struct
import time
from typing import Set, Dict, Any, Optional
from bleak import BleakClient, BleakScanner, BleakError
import sys
import os

# Ensure ble_tools is importable
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
from ble_tools.decoder import MoovPacketDecoder
from backend import models

class MoovBLEBridge:
    def __init__(self):
        self.connected_device_mac: Optional[str] = None
        self.device_name: str = "Moov Now (Disconnected)"
        self.is_connected: bool = False
        self.battery_pct: int = 88
        self.rssi: int = -58

        self.ble_client: Optional[BleakClient] = None
        self.active_websockets: Set[Any] = set()

        # Telemetry State
        self.current_accel = {"x": 0.0, "y": 0.0, "z": 1.0, "magnitude": 1.0}
        self.current_gyro = {"x": 0.0, "y": 0.0, "z": 0.0, "magnitude": 0.0}
        self.current_mag = {"x": 0.0, "y": 0.0, "z": 0.0}
        self.current_orientation = {"pitch": 0.0, "roll": 0.0, "yaw": 0.0}
        self.current_activity = "Walking"
        self.impact_g = 1.0
        self.cadence_rpm = 110
        self.active_workout_id: Optional[int] = None
        self.workout_steps = 0
        self.workout_start_time = None
        # Always-on background auto-connect engine (like the real Moov app)
        self._auto_task: Optional[asyncio.Task] = None
        self._auto_scanner: Optional[object] = None
        self._connect_in_progress: bool = False
        self._last_connect_attempt: float = 0.0
        self._runtime_blacklist: set = set()
        self._fail_counts: dict = {}
        self._ble_broadcast_task: Optional[asyncio.Task] = None
        self._enable_char: Optional[object] = None

    async def scan_devices(self, timeout: float = 10.0) -> list:
        """Scan for nearby BLE devices with instant Moov hardware identification."""
        discovered_map = {}
        moov_uuids = ["2b00", "2b01", "2b02", "d0611e78", "9fa480e0", "7905f431", "89d3502b", "9a3f68e0"]

        EXCLUDED_MACS = ["6E:7A:A1:CF:45:09", "D4:15:72:42:3C:AE", "D3:CF:C7:CE:A6:E9", "9C:9E:6E:F1:A4:2D", "30:04:78:4F:CB:00", "0D:7D:32:7C:B7:17", "4C:74:40:55:49:87", "CD:D9:A0:82:3D:41"]

        def callback(device, adv_data):
            raw_name = device.name or adv_data.local_name or "Unknown Device"
            rssi = adv_data.rssi if hasattr(adv_data, 'rssi') else device.rssi
            service_uuids = [str(u).lower() for u in adv_data.service_uuids]
            
            has_moov_uuid = any(any(p in u for p in moov_uuids) for u in service_uuids)
            is_moov_name = "moov" in raw_name.lower()
            
            # Exclude known non-Moov devices like iPhone/Watch/Router
            is_apple_or_watch = device.address.upper() in EXCLUDED_MACS or any(ex in raw_name.lower() for ex in ["iphone", "watch", "apple", "versa", "livsmt", "washer"])

            # Mark as Moov if explicitly named OR has Moov UUIDs OR is close un-named device (> -75 dBm)
            is_moov = (is_moov_name or has_moov_uuid or (raw_name == "Unknown Device" and rssi > -75)) and not is_apple_or_watch

            display_name = raw_name
            if is_moov:
                display_name = f"🏃 MOOV NOW TRACKER ({device.address[-5:]})"

            discovered_map[device.address] = {
                "address": device.address,
                "name": display_name,
                "rssi": rssi,
                "is_moov": is_moov
            }

        scanner = BleakScanner(detection_callback=callback)
        await scanner.start()
        await asyncio.sleep(timeout)
        await scanner.stop()

        results = list(discovered_map.values())
        results.sort(key=lambda x: (not x["is_moov"], -x["rssi"]))
        return results

    async def connect_to_device(self, address: str, device=None) -> bool:
        """Connect to physical device via Bleak using instant dynamic advertisement capture.
        If `device` (a BLEDevice object) is passed, skip the re-scan and connect straight
        to it — the object retains the OS handle so a 2-3s button blink is enough."""
        print(f"\n[*] 🎯 DYNAMIC MOOV SNIPER ACTIVE: Listening for active Moov button press...")

        target_ble_device = device
        EXCLUDED_MACS = ["6E:7A:A1:CF:45:09", "D4:15:72:42:3C:AE", "D3:CF:C7:CE:A6:E9", "9C:9E:6E:F1:A4:2D", "30:04:78:4F:CB:00", "0D:7D:32:7C:B7:17", "4C:74:40:55:49:87", "CD:D9:A0:82:3D:41"]

        def adv_callback(device, adv_data):
            nonlocal target_ble_device
            raw_name = device.name or adv_data.local_name or "Unknown"
            rssi = adv_data.rssi if hasattr(adv_data, 'rssi') else device.rssi
            
            # Exclude known non-Moov electronics (iPhone, Watch, Fitbit, Router)
            is_excluded = device.address.upper() in EXCLUDED_MACS or any(ex in raw_name.lower() for ex in ["iphone", "watch", "apple", "versa", "livsmt", "washer"])
            
            # Match requested MAC OR any close active signal burst (> -75 dBm)
            if (device.address.upper() == address.upper() or (rssi > -75 and not is_excluded)):
                if target_ble_device is None:
                    target_ble_device = device
                    print(f"🔥 DYNAMIC MOOV SIGNAL SNIPED! MAC: {device.address} (RSSI: {rssi} dBm)")

        # Phase 1: Fast 5-second advertisement capture (skipped when a device object is supplied)
        if device is not None:
            client_target = device
            connect_address = device.address
            print(f"[✓] Connecting instantly to sniped device handle ({connect_address})...")
        else:
            scanner = BleakScanner(detection_callback=adv_callback)
            await scanner.start()
            for _ in range(50):  # 5 seconds max wait
                if target_ble_device is not None:
                    break
                await asyncio.sleep(0.1)
            await scanner.stop()

            if target_ble_device:
                actual_mac = target_ble_device.address
                print(f"[✓] Sniped active Moov hardware ({actual_mac})! Connecting instantly...")
                client_target = target_ble_device
                connect_address = actual_mac
            else:
                print(f"[!] Active signal burst not caught in 5s window. Trying direct connection to {address}...")
                client_target = address
                connect_address = address

        for attempt in range(1, 4):
            try:
                print(f"[*] Connection attempt {attempt}/3 to {connect_address}...")
                self.ble_client = BleakClient(client_target, timeout=8.0)
                await self.ble_client.connect()

                if self.ble_client.is_connected:
                    self.is_connected = True
                    self.connected_device_mac = connect_address
                    self.device_name = f"Moov Now ({connect_address})"
                    print(f"🎉 CONNECTED SUCCESSFULLY TO MOOV NOW ({connect_address})!")

                    # Give the stack time to finish service discovery
                    await asyncio.sleep(0.3)

                    # Full GATT dump so we can see every char + property
                    for service in self.ble_client.services:
                        for char in service.characteristics:
                            print(f"[GATT] svc={service.uuid} char={char.uuid} props={char.properties}")

                    async def activate():
                        # Known system/protected service UUIDs to ignore
                        SKIP_SERVICES = ["00001800", "00001801", "0000180a"]

                        # 1. Subscribe to notify characteristics — PRIMARY data char is f000cd51.
                        # Extra chars (cd55, ffe1) may destabilize the device; subscribe cd51 only.
                        for service in self.ble_client.services:
                            s_uuid = str(service.uuid).lower()
                            if any(skip in s_uuid for skip in SKIP_SERVICES):
                                continue
                            for char in service.characteristics:
                                if ("notify" in char.properties or "indicate" in char.properties) and "f000cd51" in str(char.uuid).lower():
                                    try:
                                        await self.ble_client.start_notify(char.uuid, self._ble_notification_handler)
                                        print(f"[✓] Subscribed to notify char: {char.uuid}")
                                    except Exception as e:
                                        print(f"[!] Skip notify char {char.uuid}: {e}")

                        # 2. Enable sensor stream. From Moov APK GATT map + empirical testing:
                        #   cd52 = enable config, cd53 = interval, cd54 = command.
                        #   cd52=0x01 starts the stream but the device drops it after the button
                        #   session; write interval + command to hold continuous streaming.
                        async def write_char(char, payload, label):
                            try:
                                await self.ble_client.write_gatt_char(char.uuid, payload, response=False)
                                print(f"🔥 [✓] {label} ({char.uuid} = {payload.hex()})")
                            except Exception as w_err:
                                print(f"[!] {label} ({char.uuid}): {w_err}")

                        for service in self.ble_client.services:
                            s_uuid = str(service.uuid).lower()
                            if "f000cd50" not in s_uuid:
                                continue
                            for char in service.characteristics:
                                c_uuid = str(char.uuid).lower()
                                if "write" not in char.properties and "write-without-response" not in char.properties:
                                    continue
                                if "f000cd52" in c_uuid:
                                    self._enable_char = char
                                    await write_char(char, bytes([0x01]), "Enable stream")

                    await activate()
                    # Push fresh state to UI immediately + start 20Hz broadcaster
                    await self.broadcast(self.get_telemetry_payload())
                    self._start_ble_broadcast()
                    return True
            except Exception as e:
                print(f"Attempt {attempt} failed: {e}")
                await asyncio.sleep(0.3)

        # No synthetic fallback — stay disconnected and let the auto-connect engine retry.
        self.is_connected = False
        self.device_name = "Moov Now (Waiting for device)"
        await self.broadcast(self.get_telemetry_payload())
        return False

    async def auto_latch_device(self, timeout: float = 12.0) -> bool:
        """Continuously listen for active Moov button press burst and auto-latch immediately."""
        print(f"\n[*] ⚡ AUTO-LATCH ENGINE ACTIVE: Press your Moov button NOW!")

        sniped_device = None
        moov_sig_device = None
        MOOV_ADV_IDS = ["9a3f68e0", "f000ffc0", "9fa480e0", "d0611e78", "2b00", "2b01"]
        EXCLUDED_MACS = ["6E:7A:A1:CF:45:09", "D4:15:72:42:3C:AE", "D3:CF:C7:CE:A6:E9", "9C:9E:6E:F1:A4:2D", "30:04:78:4F:CB:00", "0D:7D:32:7C:B7:17", "4C:74:40:55:49:87", "CD:D9:A0:82:3D:41"]

        def adv_callback(device, adv_data):
            nonlocal sniped_device, moov_sig_device
            raw_name = device.name or adv_data.local_name or "Unknown"
            rssi = adv_data.rssi if hasattr(adv_data, 'rssi') else device.rssi
            is_excluded = device.address.upper() in EXCLUDED_MACS or any(ex in raw_name.lower() for ex in ["iphone", "watch", "apple", "versa", "livsmt", "washer"])
            if rssi <= -75 or is_excluded:
                return

            svc_uuids = [str(u).lower() for u in adv_data.service_uuids]
            is_moov_sig = "moov" in raw_name.lower() or any(any(p in u for p in MOOV_ADV_IDS) for u in svc_uuids)

            # Prefer a real Moov-signature device over random strong signals.
            if is_moov_sig and moov_sig_device is None:
                moov_sig_device = device
                print(f"🔥 AUTO-LATCH MOOV-SIG: {device.address} ({raw_name}) RSSI: {rssi} dBm")
            if sniped_device is None:
                sniped_device = device
                print(f"🔥 AUTO-LATCH SNIPED DEVICE: {device.address} ({raw_name}) RSSI: {rssi} dBm")

        scanner = BleakScanner(detection_callback=adv_callback)
        await scanner.start()
        start_t = time.time()
        while time.time() - start_t < timeout:
            # Only a Moov-signature device is acceptable — random strong signals are BLE junk.
            if moov_sig_device is not None:
                break
            await asyncio.sleep(0.05)
        await scanner.stop()

        target = moov_sig_device
        if target is not None:
            return await self.connect_to_device(target.address)

        # No synthetic fallback — stay disconnected and let the auto-connect engine retry.
        self.is_connected = False
        self.device_name = "Moov Now (Waiting for device)"
        await self.broadcast(self.get_telemetry_payload())
        return False

    def start_auto_connect(self):
        """Start the always-on background Moov auto-connect engine."""
        if self._auto_task and not self._auto_task.done():
            return
        self._auto_task = asyncio.create_task(self._auto_connect_loop())

    @staticmethod
    def _is_moov_like(device, adv_data) -> bool:
        """Same heuristic as scan_devices: moov name, moov service UUID, or strong unknown."""
        raw_name = device.name or adv_data.local_name or "Unknown Device"
        rssi = adv_data.rssi if hasattr(adv_data, 'rssi') else device.rssi
        if rssi <= -75:
            return False
        if any(ex in raw_name.lower() for ex in ["iphone", "watch", "apple", "versa", "livsmt", "washer"]):
            return False
        svc_uuids = [str(u).lower() for u in adv_data.service_uuids]
        MOOV_UUIDS = ["2b00", "2b01", "2b02", "d0611e78", "9fa480e0", "7905f431", "89d3502b", "9a3f68e0"]
        has_moov_uuid = any(any(p in u for p in MOOV_UUIDS) for u in svc_uuids)
        return "moov" in raw_name.lower() or has_moov_uuid or raw_name == "Unknown Device"

    async def _auto_connect_loop(self):
        """Continuously listen for Moov button-press bursts and auto-connect, like the real app.
        Uses the continuous scan + poll pattern (same as the working auto-latch): a 2-3s Moov
        blink always lands inside the listening window."""
        while True:
            # Idle only when not already on a real device
            if self.is_connected or self._connect_in_progress:
                await asyncio.sleep(2.0)
                continue
            if time.time() - self._last_connect_attempt < 3.0:
                await asyncio.sleep(0.5)
                continue
            try:
                moov_sig = None
                best_unknown = None
                EXCLUDED = ["6E:7A:A1:CF:45:09", "D4:15:72:42:3C:AE", "D3:CF:C7:CE:A6:E9", "9C:9E:6E:F1:A4:2D", "30:04:78:4F:CB:00", "0D:7D:32:7C:B7:17", "4C:74:40:55:49:87", "CD:D9:A0:82:3D:41"]

                def cb(device, adv_data):
                    nonlocal moov_sig, best_unknown
                    if device.address.upper() in EXCLUDED or device.address.upper() in self._runtime_blacklist:
                        return
                    raw_name = device.name or adv_data.local_name or ""
                    rssi = adv_data.rssi if hasattr(adv_data, 'rssi') else device.rssi
                    svc_uuids = [str(u).lower() for u in adv_data.service_uuids]
                    MOOV_UUIDS = ["2b00", "2b01", "2b02", "d0611e78", "9fa480e0", "7905f431", "89d3502b", "9a3f68e0"]
                    # Tier 1: explicit Moov signature — locks instantly, beats any nuisance.
                    if "moov" in raw_name.lower() or any(any(p in u for p in MOOV_UUIDS) for u in svc_uuids):
                        if moov_sig is None:
                            moov_sig = device
                            print(f"🟢 MOOV-SIG FOUND: {device.address} ({raw_name}) RSSI: {rssi} dBm")
                        return
                    # Tier 2: strong unknown — only a fallback, never beats a real Moov.
                    if rssi > -75 and raw_name not in ("", None):
                        if best_unknown is None or rssi > getattr(best_unknown, 'rssi', -200):
                            best_unknown = device

                print(f"[AC] listening cycle... blacklist={len(self._runtime_blacklist)}")
                scanner = BleakScanner(detection_callback=cb)
                await scanner.start()
                start_t = time.time()
                while time.time() - start_t < 8.0:
                    if moov_sig is not None:
                        break
                    await asyncio.sleep(0.05)
                await scanner.stop()
                target = moov_sig if moov_sig is not None else best_unknown

                if target is not None:
                    print(f"🟢 AUTO-CONNECT TRIGGERED: {target.address} RSSI: {getattr(target, 'rssi', '?')} dBm")
                    self._connect_in_progress = True
                    self._last_connect_attempt = time.time()
                    try:
                        ok = await self.connect_to_device(target.address, device=target)
                        if ok:
                            self._fail_counts[target.address.upper()] = 0
                            print(f"🟢 AUTO-CONNECTED TO MOOV ({target.address})!")
                        else:
                            # Device may just be asleep again, but 3 consecutive failures = BLE junk.
                            mac = target.address.upper()
                            self._fail_counts[mac] = self._fail_counts.get(mac, 0) + 1
                            print(f"[!] Auto-connect failed {target.address} (strike {self._fail_counts[mac]}/3)")
                            if self._fail_counts[mac] >= 3:
                                self._runtime_blacklist.add(mac)
                                print(f"[x] Blacklisted {target.address} for this session")
                    except Exception as e:
                        print(f"[!] Auto-connect failed {target.address}: {e}")
                        mac = target.address.upper()
                        self._fail_counts[mac] = self._fail_counts.get(mac, 0) + 1
                        if self._fail_counts[mac] >= 3:
                            self._runtime_blacklist.add(mac)
                            print(f"[x] Blacklisted {target.address} for this session")
                    finally:
                        self._connect_in_progress = False
            except Exception as e:
                print(f"[!] Auto-connect scan: {e}")
                await asyncio.sleep(2.0)

    def _ble_notification_handler(self, sender, data: bytearray):
        """Handler for real BLE telemetry packets from Moov Now.
        Runs on the BLE (winrt) thread — must NOT touch SQLite or asyncio directly."""
        self._last_packet = time.time()
        parsed = MoovPacketDecoder.parse_sensor_frame(bytes(data))
        if parsed.get("valid"):
            self.current_accel = parsed["accel"]
            self.current_gyro = parsed.get("gyro", self.current_gyro)
            self.current_mag = parsed.get("mag", self.current_mag)
            self.current_orientation = parsed.get("orientation", self.current_orientation)
            self.impact_g = parsed.get("impact_g", 1.0)
            self.cadence_rpm = parsed.get("cadence_rpm", 0)
            self.current_activity = parsed.get("detected_activity", self.current_activity)

            # Edge-triggered step count: one step per accel bounce above 1.45g,
            # re-arm when it settles below 1.15g. Robust across walking/running.
            accel_mag = parsed.get("accel", {}).get("magnitude", 1.0)
            armed = getattr(self, "_step_armed", False)
            step_delta = 0
            if accel_mag > 1.45 and not armed:
                self._step_armed = True
                step_delta = 1
            elif accel_mag < 1.15:
                self._step_armed = False
            if step_delta > 0:
                self.workout_steps += step_delta
                # Buffer for the loop-thread flush (BLE callback runs on a separate thread;
                # touching SQLite here deadlocks the server).
                self._steps_to_flush = getattr(self, "_steps_to_flush", 0) + step_delta
            # NOTE: no broadcast here — a single 20Hz loop (started on connect) pushes telemetry.

    def _start_ble_broadcast(self):
        if self._ble_broadcast_task and not self._ble_broadcast_task.done():
            return
        self._ble_broadcast_task = asyncio.create_task(self._ble_broadcast_loop())

    def _stop_ble_broadcast(self):
        if self._ble_broadcast_task:
            self._ble_broadcast_task.cancel()
            self._ble_broadcast_task = None

    async def _ble_broadcast_loop(self):
        """Push telemetry to the UI at ~20Hz while the real device is connected.
        Runs on the asyncio loop thread, so it is the ONLY place that touches SQLite
        for live step accumulation (the BLE callback is a separate OS thread).
        Also acts as a stream keep-alive: the Moov drops the stream after a burst,
        so re-write the enable config every ~2s to hold it."""
        last_nudge = 0.0
        last_snapshot = 0.0
        while True:
            try:
                steps = getattr(self, "_steps_to_flush", 0)
                if steps > 0:
                    self._steps_to_flush = 0
                    now = time.time()
                    elapsed = now - getattr(self, "_last_flush_ts", now)
                    self._last_flush_ts = now
                    # Active time = wall-clock seconds that actually contained steps
                    models.update_today_steps(steps, max(elapsed, 0.0), steps * 0.04, steps * 0.0008)
                # Time-series log: one timestamped sample per second while streaming
                if self.is_connected and (time.time() - last_snapshot) >= 1.0:
                    last_snapshot = time.time()
                    models.log_telemetry_snapshot(
                        self.active_workout_id, self.current_accel, self.current_gyro,
                        self.impact_g, self.cadence_rpm, self.current_activity)
                # Keep-alive: Moov firmware sleeps the stream after ~10-20s unless re-enabled.
                # When silent >3s, re-write the enable config (cd52=0x01) to resume streaming
                # automatically — no button press needed. If the write fails, the device truly
                # dropped, so release and let auto-connect recover.
                last_pkt = getattr(self, "_last_packet", 0.0)
                if self.is_connected and getattr(self, "_enable_char", None) and last_pkt and (time.time() - last_pkt) > 3.0 and (time.time() - last_nudge) > 3.0:
                    last_nudge = time.time()
                    try:
                        await self.ble_client.write_gatt_char(self._enable_char.uuid, bytes([0x01]), response=False)
                        print("[✓] Re-enabled stream (keep-alive)")
                    except Exception:
                        self.is_connected = False
                        print("[!] Device dropped — releasing for auto-reconnect")
                await self.broadcast(self.get_telemetry_payload())
            except Exception:
                pass
            await asyncio.sleep(0.05)

    async def disconnect(self):
        self._stop_ble_broadcast()
        if self.ble_client and self.ble_client.is_connected:
            await self.ble_client.disconnect()
        self.is_connected = False
        self.connected_device_mac = None
        self._enable_char = None

    def get_telemetry_payload(self) -> Dict[str, Any]:
        return {
            "timestamp": time.time(),
            "device": {
                "name": self.device_name,
                "address": self.connected_device_mac or "",
                "connected": self.is_connected,
                "battery": self.battery_pct,
                "rssi": self.rssi,
            },
            "motion": {
                "accel": self.current_accel,
                "gyro": self.current_gyro,
                "mag": self.current_mag,
                "orientation": self.current_orientation,
                "impact_g": self.impact_g,
                "cadence_rpm": self.cadence_rpm,
                "activity": self.current_activity
            },
            "workout": {
                "active": self.active_workout_id is not None,
                "workout_id": self.active_workout_id,
                "steps": self.workout_steps,
                "duration_sec": int(time.time() - self.workout_start_time) if self.workout_start_time else 0
            }
        }

    async def broadcast(self, message: dict):
        if not self.active_websockets:
            return
        msg_str = json.dumps(message)
        to_remove = set()
        for ws in list(self.active_websockets):
            try:
                # A stuck/stale client must not freeze the broadcaster.
                await asyncio.wait_for(ws.send_text(msg_str), timeout=1.0)
            except Exception:
                to_remove.add(ws)
        self.active_websockets.difference_update(to_remove)


# Global Singleton Instance
bridge = MoovBLEBridge()
