#!/usr/bin/env python3
"""
Moov Now Protocol Decoder & Packet Parser (Phase 2.4 / Phase 3 Integration)
Decodes raw byte streams from the Moov Now 9-axis Omni Motion sensor.
Parses accelerometer (g), gyroscope (deg/s), magnetometer (uT), impact force, cadence,
and step counts.
"""

import struct
import math
from typing import Dict, Any, Tuple, Optional

class MoovPacketDecoder:
    """
    Parser for Moov Now BLE telemetry packets.
    Handles standard GATT notifications and proprietary Moov payload formats.
    """

    # Scale factors derived from Omni Motion 9-axis specifications:
    # Accel range: +/- 16g (16-bit signed int -> 32768 LSB = 16g)
    ACCEL_SCALE = 16.0 / 32768.0
    # Gyro range: +/- 2000 deg/s (16-bit signed int -> 32768 LSB = 2000 dps)
    GYRO_SCALE = 2000.0 / 32768.0
    # Mag range: +/- 4800 uT (16-bit signed int)
    MAG_SCALE = 4800.0 / 32768.0

    @staticmethod
    def parse_battery_level(data: bytes) -> Optional[int]:
        """Parse standard 1-byte battery service characteristic 0x2A19."""
        if len(data) >= 1:
            return int(data[0])
        return None

    @classmethod
    def parse_sensor_frame(cls, data: bytes) -> Dict[str, Any]:
        """
        Parse raw notification payload into structured 9-axis motion & workout metrics.
        Payloads can be raw 9-axis 18-byte/20-byte buffers or structured event packets.
        """
        packet_len = len(data)
        
        # Default empty reading structure
        result = {
            "valid": False,
            "packet_length": packet_len,
            "raw_hex": data.hex(),
            "accel": {"x": 0.0, "y": 0.0, "z": 0.0, "magnitude": 1.0},
            "gyro": {"x": 0.0, "y": 0.0, "z": 0.0, "magnitude": 0.0},
            "mag": {"x": 0.0, "y": 0.0, "z": 0.0},
            "impact_g": 1.0,
            "cadence_rpm": 0,
            "orientation": {"pitch": 0.0, "roll": 0.0, "yaw": 0.0},
            "detected_activity": "Idle",
            "step_delta": 0,
        }

        if packet_len < 2:
            return result

        try:
            # Case 1: 20-byte Moov Now telemetry frame (reverse-engineered from device + Moov APK).
            # Layout (little-endian): [0:2]=header, [2:8]=mag/raw-varies, [8:12]=zeros,
            # [12:18]=ACCEL 3xint16 (scale 16384/g, ±2g), [18]=seq counter, [19]=0x00.
            if packet_len >= 18:
                ax_raw, ay_raw, az_raw = struct.unpack("<hhh", data[12:18])
                gx_raw, gy_raw, gz_raw = struct.unpack("<hhh", data[2:8])

                ax = round(ax_raw / 16384.0, 3)
                ay = round(ay_raw / 16384.0, 3)
                az = round(az_raw / 16384.0, 3)

                gx = round(gx_raw * cls.GYRO_SCALE, 2)
                gy = round(gy_raw * cls.GYRO_SCALE, 2)
                gz = round(gz_raw * cls.GYRO_SCALE, 2)

                mx = my = mz = 0.0

                # Compute acceleration magnitude & impact force (in g).
                # NOTE: gyro bytes [2:8] swing full-range even when stationary and do not behave
                # like a rate gyro on this firmware — keep it as a best-effort rotation signal
                # but drive activity/steps from ACCEL only.
                accel_mag = round(math.sqrt(ax * ax + ay * ay + az * az), 2)
                gyro_mag = round(math.sqrt(gx * gx + gy * gy + gz * gz), 2)

                # Estimate Pitch & Roll from accelerometer (gravity vector).
                # Reference: device flat gives az ~= -1 g, so angles are measured from -az,
                # which keeps both within about +/-90 deg (no 180-degree gimbal flip).
                pitch = round(math.atan2(-ax, math.sqrt(ay * ay + az * az + 1e-6)) * (180.0 / math.pi), 1)
                roll = round(math.atan2(ay, -az + 1e-6) * (180.0 / math.pi), 1)
                yaw = 0.0

                # Activity from accel magnitude. At rest the magnitude is ~1 g, so anything
                # near gravity must read Idle rather than a sport.
                activity = "Idle"
                if accel_mag > 2.6:
                    activity = "Boxing"
                elif accel_mag > 1.75:
                    activity = "Running"
                elif accel_mag > 1.15:
                    activity = "Walking"

                # Step: sustained accel deviation from gravity (1g) = movement impulse
                step_inc = 1 if (accel_mag > 1.35 and abs(accel_mag - 1.0) > 0.45) else 0

                result.update({
                    "valid": True,
                    "accel": {"x": ax, "y": ay, "z": az, "magnitude": accel_mag},
                    "gyro": {"x": gx, "y": gy, "z": gz, "magnitude": gyro_mag},
                    "mag": {"x": mx, "y": my, "z": mz},
                    "impact_g": accel_mag,
                    "cadence_rpm": int(min(220, gyro_mag * 0.8)),
                    "orientation": {"pitch": pitch, "roll": roll, "yaw": yaw},
                    "detected_activity": activity,
                    "step_delta": step_inc
                })

            # Case 2: Short 6-17 byte frame
            elif packet_len >= 6:
                ax_raw, ay_raw, az_raw = struct.unpack("<hhh", data[:6])
                ax = round(ax_raw * cls.ACCEL_SCALE, 3)
                ay = round(ay_raw * cls.ACCEL_SCALE, 3)
                az = round(az_raw * cls.ACCEL_SCALE, 3)
                accel_mag = round(math.sqrt(ax * ax + ay * ay + az * az), 2)

                pitch = round(math.atan2(ay, math.sqrt(ax * ax + az * az + 1e-6)) * (180.0 / math.pi), 1)
                roll = round(math.atan2(-ax, az + 1e-6) * (180.0 / math.pi), 1)

                result.update({
                    "valid": True,
                    "accel": {"x": ax, "y": ay, "z": az, "magnitude": accel_mag},
                    "impact_g": accel_mag,
                    "orientation": {"pitch": pitch, "roll": roll, "yaw": 0.0}
                })

            # Case 3: 2-5 byte short frame
            else:
                b1 = data[0] if len(data) > 0 else 0
                b2 = data[1] if len(data) > 1 else 0
                ax = round((b1 - 128) / 32.0, 2)
                ay = round((b2 - 128) / 32.0, 2)
                accel_mag = round(math.sqrt(ax * ax + ay * ay + 1.0), 2)

                result.update({
                    "valid": True,
                    "accel": {"x": ax, "y": ay, "z": 1.0, "magnitude": accel_mag},
                    "impact_g": accel_mag,
                    "orientation": {"pitch": ax * 30.0, "roll": ay * 30.0, "yaw": 0.0}
                })

        except Exception as err:
            result["error"] = str(err)

        return result


if __name__ == "__main__":
    print("Testing MoovPacketDecoder with sample payload...")
    # 18-byte dummy binary buffer simulating 9-axis readings
    dummy_data = struct.pack("<hhhhhhHhh", 2048, -1024, 16384, 500, -300, 1200, 100, 200, -500)
    parsed = MoovPacketDecoder.parse_sensor_frame(dummy_data)
    print("Parsed Data:")
    import json
    print(json.dumps(parsed, indent=2))
