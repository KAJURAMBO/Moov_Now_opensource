"""
Moov Now Application Server (FastAPI + WebSockets + Static Frontend)
"""

import asyncio
import os
import time
from typing import Optional
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse, JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from backend import models
from backend.ble_bridge import bridge

app = FastAPI(
    title="Moov Now Fitness Tracker Revival Platform",
    description="Replacement backend and live BLE dashboard for Moov Now Omni Motion tracker",
    version="1.0.0"
)

# Enable CORS for local web development
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

FRONTEND_DIR = os.path.join(os.path.dirname(__file__), "..", "frontend")

@app.on_event("startup")
async def startup_event():
    models.init_db()
    # Real device only — no synthetic data. The app idles as "Disconnected" until the
    # Moov advertises; the background engine then connects on its own.
    bridge.is_connected = False
    bridge.device_name = "Moov Now (Waiting for device)"
    bridge.start_auto_connect()
    print("🚀 Moov Now Server started! Web UI available at http://localhost:8000")

# Request Schemas
class ConnectRequest(BaseModel):
    address: str

class StartWorkoutRequest(BaseModel):
    activity_type: str

class StopWorkoutRequest(BaseModel):
    workout_id: int

# REST API Endpoints
@app.get("/api/status")
async def get_status():
    return bridge.get_telemetry_payload()

@app.post("/api/scan")
async def scan_ble_devices():
    try:
        devices = await bridge.scan_devices(timeout=6.0)
        return {"success": True, "devices": devices}
    except Exception as e:
        return {"success": False, "error": str(e), "devices": []}

@app.post("/api/connect")
async def connect_device(req: ConnectRequest):
    success = await bridge.connect_to_device(req.address)
    if success:
        return {"success": True, "message": f"Connected to Moov device {req.address}"}
    else:
        return {"success": False, "message": "Failed to connect to device. Still scanning for the Moov."}

@app.post("/api/auto_latch")
async def auto_latch_moov():
    success = await bridge.auto_latch_device(timeout=10.0)
    if success:
        return {"success": True, "message": f"Latched successfully to Moov Now ({bridge.connected_device_mac})!"}
    else:
        return {"success": False, "message": "Auto-latch timed out. Ensure Moov button was pressed while blinking red."}

@app.post("/api/disconnect")
async def disconnect_device():
    await bridge.disconnect()
    bridge.device_name = "Moov Now (Waiting for device)"
    await bridge.broadcast(bridge.get_telemetry_payload())
    return {"success": True, "message": "Disconnected. Waiting for the Moov to advertise again."}

@app.get("/api/workouts")
async def list_workouts():
    workouts = models.get_all_workouts(limit=30)
    return {"workouts": workouts}

@app.post("/api/workouts/start")
async def start_workout(req: StartWorkoutRequest):
    workout_id = models.create_workout(req.activity_type)
    bridge.active_workout_id = workout_id
    bridge.workout_steps = 0
    bridge.workout_start_time = time.time()
    return {"success": True, "workout_id": workout_id, "activity": req.activity_type}

@app.post("/api/workouts/stop")
async def stop_workout(req: StopWorkoutRequest):
    if bridge.active_workout_id == req.workout_id:
        duration = int(time.time() - (bridge.workout_start_time or time.time()))
        steps = bridge.workout_steps
        avg_cadence = bridge.cadence_rpm
        max_impact = round(bridge.impact_g, 2)
        calories = round(steps * 0.045, 1)
        dist_km = round(steps * 0.0008, 2)

        models.finish_workout(req.workout_id, duration, steps, avg_cadence, max_impact, calories, dist_km)
        
        bridge.active_workout_id = None
        bridge.workout_start_time = None
        bridge.workout_steps = 0
        return {"success": True, "summary": {
            "workout_id": req.workout_id,
            "duration_sec": duration,
            "steps": steps,
            "calories": calories,
            "distance_km": dist_km
        }}
    raise HTTPException(status_code=400, detail="Workout ID not active")

@app.get("/api/daily_stats")
async def get_daily_stats():
    return models.get_today_stats()

@app.get("/api/telemetry")
async def get_telemetry(limit: int = 500, workout_id: Optional[int] = None):
    """Timestamped telemetry time-series (accel/gyro/impact/cadence/activity)."""
    return {"samples": models.get_telemetry_snapshots(limit=limit, workout_id=workout_id)}

# WebSocket Endpoint for Real-time Streaming Telemetry
@app.websocket("/ws/live")
async def websocket_live_endpoint(websocket: WebSocket):
    await websocket.accept()
    bridge.active_websockets.add(websocket)
    try:
        # Send initial state immediately
        await websocket.send_json(bridge.get_telemetry_payload())
        while True:
            # Keep socket alive and receive client commands if any
            data = await websocket.receive_text()
            if data == "ping":
                await websocket.send_text("pong")
    except WebSocketDisconnect:
        bridge.active_websockets.discard(websocket)
    except Exception:
        bridge.active_websockets.discard(websocket)

# Mount Static Files for Frontend
if os.path.exists(FRONTEND_DIR):
    app.mount("/static", StaticFiles(directory=FRONTEND_DIR), name="static")

@app.get("/")
async def serve_index():
    index_path = os.path.join(FRONTEND_DIR, "index.html")
    if os.path.exists(index_path):
        return FileResponse(index_path)
    return JSONResponse({"status": "Moov Server Online. Frontend index.html loading..."}, status_code=200)

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("backend.main:app", host="0.0.0.0", port=8000, reload=True)
