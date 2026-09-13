"""
Moov Now Database Models & Access Layer
Uses SQLite for zero-configuration, reliable local fitness data storage.
"""

import sqlite3
import os
import time
from typing import List, Dict, Any, Optional

DB_FILE = os.path.join(os.path.dirname(__file__), "moov_fitness.db")

def get_db():
    conn = sqlite3.connect(DB_FILE)
    conn.row_factory = sqlite3.Row
    return conn

def init_db():
    """Create initial database tables if they do not exist."""
    conn = get_db()
    cursor = conn.cursor()

    # Workouts Table
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS workouts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        activity_type TEXT NOT NULL,
        start_time REAL NOT NULL,
        end_time REAL,
        duration_sec INTEGER DEFAULT 0,
        total_steps INTEGER DEFAULT 0,
        avg_cadence_rpm INTEGER DEFAULT 0,
        max_impact_g REAL DEFAULT 0.0,
        calories_burned REAL DEFAULT 0.0,
        distance_km REAL DEFAULT 0.0,
        notes TEXT
    );
    """)

    # Daily Stats Table
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS daily_stats (
        date TEXT PRIMARY KEY,
        total_steps INTEGER DEFAULT 0,
        active_minutes INTEGER DEFAULT 0,
        calories_burned REAL DEFAULT 0.0,
        distance_km REAL DEFAULT 0.0,
        last_updated REAL
    );
    """)

    # Device Metadata Table
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS device_info (
        mac_address TEXT PRIMARY KEY,
        device_name TEXT,
        battery_pct INTEGER DEFAULT 100,
        firmware_rev TEXT,
        last_connected REAL
    );
    """)

    # Telemetry Log Snapshot Table
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS telemetry_snapshots (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp REAL NOT NULL,
        workout_id INTEGER,
        accel_x REAL, accel_y REAL, accel_z REAL,
        gyro_x REAL, gyro_y REAL, gyro_z REAL,
        impact_g REAL, cadence_rpm INTEGER,
        activity TEXT
    );
    """)

    # Migration: active_seconds added so active minutes accumulate at full precision
    cols = [r[1] for r in cursor.execute("PRAGMA table_info(daily_stats);").fetchall()]
    if "active_seconds" not in cols:
        cursor.execute("ALTER TABLE daily_stats ADD COLUMN active_seconds REAL DEFAULT 0;")

    conn.commit()
    conn.close()

def log_telemetry_snapshot(workout_id, accel: dict, gyro: dict, impact_g: float,
                           cadence_rpm: int, activity: str) -> None:
    """Append one timestamped telemetry sample to the time-series log."""
    conn = get_db()
    cursor = conn.cursor()
    cursor.execute("""
        INSERT INTO telemetry_snapshots
            (timestamp, workout_id, accel_x, accel_y, accel_z, gyro_x, gyro_y, gyro_z,
             impact_g, cadence_rpm, activity)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
    """, (time.time(), workout_id, accel.get("x"), accel.get("y"), accel.get("z"),
          gyro.get("x"), gyro.get("y"), gyro.get("z"), impact_g, cadence_rpm, activity))
    conn.commit()
    conn.close()


def get_telemetry_snapshots(limit: int = 500, workout_id: Optional[int] = None) -> List[Dict[str, Any]]:
    """Read recent telemetry samples, optionally scoped to one workout."""
    conn = get_db()
    cursor = conn.cursor()
    if workout_id is not None:
        cursor.execute("SELECT * FROM telemetry_snapshots WHERE workout_id = ? ORDER BY timestamp DESC LIMIT ?;",
                       (workout_id, limit))
    else:
        cursor.execute("SELECT * FROM telemetry_snapshots ORDER BY timestamp DESC LIMIT ?;", (limit,))
    rows = cursor.fetchall()
    conn.close()
    return [dict(r) for r in rows]

# Helper Query Functions
def get_all_workouts(limit: int = 20) -> List[Dict[str, Any]]:
    conn = get_db()
    cursor = conn.cursor()
    cursor.execute("SELECT * FROM workouts ORDER BY start_time DESC LIMIT ?;", (limit,))
    rows = cursor.fetchall()
    conn.close()
    return [dict(r) for r in rows]

def create_workout(activity_type: str) -> int:
    conn = get_db()
    cursor = conn.cursor()
    now = time.time()
    cursor.execute("""
        INSERT INTO workouts (activity_type, start_time, notes)
        VALUES (?, ?, 'Live Moov Now workout session');
    """, (activity_type, now))
    workout_id = cursor.lastrowid
    conn.commit()
    conn.close()
    return workout_id

def finish_workout(workout_id: int, duration_sec: int, total_steps: int, avg_cadence: int, max_impact: float, calories: float, distance_km: float):
    conn = get_db()
    cursor = conn.cursor()
    now = time.time()
    cursor.execute("""
        UPDATE workouts
        SET end_time = ?, duration_sec = ?, total_steps = ?, avg_cadence_rpm = ?, max_impact_g = ?, calories_burned = ?, distance_km = ?
        WHERE id = ?;
    """, (now, duration_sec, total_steps, avg_cadence, max_impact, calories, distance_km, workout_id))
    conn.commit()
    conn.close()

def get_today_stats() -> Dict[str, Any]:
    conn = get_db()
    cursor = conn.cursor()
    today_str = time.strftime("%Y-%m-%d")
    cursor.execute("SELECT * FROM daily_stats WHERE date = ?;", (today_str,))
    row = cursor.fetchone()
    conn.close()
    if row:
        return dict(row)
    return {"date": today_str, "total_steps": 0, "active_minutes": 0, "calories_burned": 0.0, "distance_km": 0.0}

def update_today_steps(step_delta: int, active_sec_delta: float, calories_delta: float, distance_km_delta: float):
    """Accumulate today's totals.

    Totals are stored at full precision and only rounded for display — rounding the
    running total on every call would discard the small per-second increments and the
    values would never move off zero.
    """
    conn = get_db()
    cursor = conn.cursor()
    today_str = time.strftime("%Y-%m-%d")
    now = time.time()

    current = get_today_stats()
    new_steps = int(current["total_steps"] + step_delta)
    new_active_sec = float(current.get("active_seconds") or 0.0) + float(active_sec_delta)
    new_active_min = int(new_active_sec // 60)
    new_calories = round(float(current["calories_burned"]) + calories_delta, 4)
    new_dist = round(float(current["distance_km"]) + distance_km_delta, 6)

    cursor.execute("""
        INSERT INTO daily_stats (date, total_steps, active_minutes, active_seconds, calories_burned, distance_km, last_updated)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(date) DO UPDATE SET
            total_steps = excluded.total_steps,
            active_minutes = excluded.active_minutes,
            active_seconds = excluded.active_seconds,
            calories_burned = excluded.calories_burned,
            distance_km = excluded.distance_km,
            last_updated = excluded.last_updated;
    """, (today_str, new_steps, new_active_min, new_active_sec, new_calories, new_dist, now))

    conn.commit()
    conn.close()

# Initialize DB when module loaded
init_db()
