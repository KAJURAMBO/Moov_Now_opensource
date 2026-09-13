#!/usr/bin/env python3
"""
Launcher script to listen to raw BLE telemetry stream from Moov Now
"""
import sys
import asyncio
from ble_tools.listener import BLEStreamListener

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python run_listener.py <DEVICE_MAC_ADDRESS>")
        sys.exit(1)
    mac = sys.argv[1]
    listener = BLEStreamListener(mac)
    asyncio.run(listener.run())
