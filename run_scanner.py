#!/usr/bin/env python3
"""
Launcher script to run Moov Now BLE Scanner
"""
import asyncio
import sys
from ble_tools.scanner import scan_ble_devices

if __name__ == "__main__":
    dur = float(sys.argv[1]) if len(sys.argv) > 1 else 10.0
    asyncio.run(scan_ble_devices(scan_duration=dur))
