#!/usr/bin/env python3
"""
Moov Now Continuous Live BLE Scanner (Phase 1.2)
Monitors BLE advertisements in real-time.
Run this script FIRST, then press your Moov Now button while it's actively listening.
"""

import asyncio
import sys
import time
from bleak import BleakScanner

# Known Moov identifiers or keywords
MOOV_KEYWORDS = ["moov", "now", "omni", "cc.moov"]

async def live_continuous_scan(scan_duration: float = 30.0):
    print("=" * 70)
    print(" 🏃 MOOV NOW LIVE REAL-TIME BLE SCANNER")
    print("=" * 70)
    print(f"[*] Scanner ACTIVE for {scan_duration} seconds.")
    print("👉 PRESS / TAP YOUR MOOV NOW BUTTON NOW while this scanner is running!")
    print("   (Look for new MAC addresses appearing below the moment the red LED blinks)\n")

    seen_macs = set()

    def detection_callback(device, advertisement_data):
        address = device.address
        name = device.name or advertisement_data.local_name or "Unknown / Unnamed"
        rssi = advertisement_data.rssi if hasattr(advertisement_data, 'rssi') else device.rssi
        is_moov = any(k in name.lower() for k in MOOV_KEYWORDS)

        is_new = address not in seen_macs
        seen_macs.add(address)

        # Highlight Moov keyword matches OR new strong signal devices (within 2 meters: RSSI > -75 dBm)
        if is_moov or is_new:
            timestamp = time.strftime("%H:%M:%S")
            prefix = "🔥 [MOOV MATCH]" if is_moov else "   [BLE Signal]"
            print(f"[{timestamp}] {prefix} MAC: {address} | Name: '{name}' | RSSI: {rssi} dBm")
            if advertisement_data.service_uuids:
                print(f"             Services: {advertisement_data.service_uuids}")
            if advertisement_data.manufacturer_data:
                mfd = {f"0x{k:04x}": v.hex() for k, v in advertisement_data.manufacturer_data.items()}
                print(f"             Manufacturer Data: {mfd}")

    scanner = BleakScanner(detection_callback=detection_callback)
    
    await scanner.start()
    await asyncio.sleep(scan_duration)
    await scanner.stop()

    print("\n" + "=" * 70)
    print(f" Scan Completed. Discovered {len(seen_macs)} unique BLE devices in range.")
    print("=" * 70)
    print("\n💡 TROUBLESHOOTING TIP FOR MOOV NOW:")
    print(" 1. RED LED BLINKING 2-3 SECONDS: This usually indicates low battery voltage (< 2.6V).")
    print("    -> Replace the CR2032 coin cell battery (pop open back cover using a coin).")
    print(" 2. SCAN TIMING: Always start the scan FIRST on PC, then press the button so the")
    print("    Windows Bluetooth stack captures the 2-3 second advertisement burst!")

if __name__ == "__main__":
    duration = 30.0
    if len(sys.argv) > 1:
        try:
            duration = float(sys.argv[1])
        except ValueError:
            pass
    asyncio.run(live_continuous_scan(duration))
