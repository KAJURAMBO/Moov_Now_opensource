#!/usr/bin/env python3
"""
Moov Now Notification Listener Tool (Phase 1.3 / Phase 2.4)
Subscribes to GATT notifications from Moov Now characteristics to log,
record, and inspect live packet data streams (9-axis sensor data, step counts, command responses).
"""

import asyncio
import sys
import time
from bleak import BleakClient, BleakError

class BLEStreamListener:
    def __init__(self, address: str, char_uuid: str = None, duration: float = 60.0):
        self.address = address
        self.char_uuid = char_uuid
        self.duration = duration
        self.packet_count = 0
        self.byte_count = 0
        self.start_time = None

    def notification_handler(self, sender, data: bytearray):
        self.packet_count += 1
        self.byte_count += len(data)
        now = time.time()
        elapsed = now - self.start_time if self.start_time else 1.0
        rate = self.packet_count / max(elapsed, 0.001)

        hex_str = data.hex(" ")
        bytes_list = list(data)

        print(f"[{self.packet_count:04d} | {elapsed:05.1f}s] Handle/UUID: {sender}")
        print(f"  ├─ Hex  : 0x {hex_str}")
        print(f"  ├─ Bytes: {bytes_list}")
        print(f"  └─ Rate : {rate:.1f} pkt/s | Length: {len(data)} bytes")
        print()

    async def run(self):
        print("=" * 70)
        print(" 🏃 MOOV NOW LIVE NOTIFICATION LISTENER")
        print("=" * 70)
        print(f"[*] Target MAC: {self.address}")
        print(f"[*] Duration: {self.duration} seconds")

        try:
            async with BleakClient(self.address, timeout=15.0) as client:
                print(f"[✓] Connected: {client.is_connected}")

                target_char = self.char_uuid
                if not target_char:
                    # Auto-detect notify/indicate characteristic
                    print("[*] Auto-detecting notification characteristics...")
                    notify_chars = []
                    for service in client.services:
                        for char in service.characteristics:
                            if "notify" in char.properties or "indicate" in char.properties:
                                notify_chars.append(char)
                    
                    if not notify_chars:
                        print("❌ No notification/indicate characteristics found!")
                        return

                    print(f"[✓] Found {len(notify_chars)} notification characteristics:")
                    for idx, c in enumerate(notify_chars):
                        print(f"   [{idx}] UUID: {c.uuid} ({', '.join(c.properties)})")
                    
                    target_char = notify_chars[0].uuid
                    print(f"[*] Defaulting to primary characteristic: {target_char}")

                print(f"[*] Subscribing to notifications on: {target_char}")
                self.start_time = time.time()
                await client.start_notify(target_char, self.notification_handler)

                print("[*] Listening for incoming data... Move or shake the Moov Now device!\n")
                await asyncio.sleep(self.duration)

                await client.stop_notify(target_char)
                print("=" * 70)
                print(" Stream finished.")
                print(f" Total Packets: {self.packet_count}")
                print(f" Total Bytes  : {self.byte_count}")
                print("=" * 70)

        except BleakError as e:
            print(f"❌ BLE Error: {e}")
        except Exception as e:
            print(f"❌ Error: {e}")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python listener.py <DEVICE_MAC_ADDRESS> [CHARACTERISTIC_UUID] [DURATION_SEC]")
        print("Example: python listener.py XX:XX:XX:XX:XX:XX 00002a37-0000-1000-8000-00805f9b34fb 30")
        sys.exit(1)

    mac = sys.argv[1]
    c_uuid = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] != "auto" else None
    dur = float(sys.argv[3]) if len(sys.argv) > 3 else 60.0

    listener = BLEStreamListener(mac, c_uuid, dur)
    asyncio.run(listener.run())
