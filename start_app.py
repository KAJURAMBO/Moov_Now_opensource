#!/usr/bin/env python3
"""
Launcher script for starting the Moov Now FastAPI + WebSocket Web Application
"""
import uvicorn
import os

if __name__ == "__main__":
    print("=" * 70)
    print(" 🏃 MOOV NOW REVIVAL PLATFORM - WEB DASHBOARD SERVER")
    print("=" * 70)
    print("[*] Launching backend engine and static web application...")
    print("[*] Web App URL : http://localhost:8000")
    print("[*] WebSocket   : ws://localhost:8000/ws/live")
    print("=" * 70)

    uvicorn.run("backend.main:app", host="0.0.0.0", port=8000, reload=False)
