import os
import sqlite3
import time
import requests
import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from pathlib import Path
from dotenv import load_dotenv

# Load secret environment variables
load_dotenv()

app = FastAPI()

# Dynamic Paths
# Automatically finds the folder this script is running inside
SERVER_DIR = Path(__file__).parent.absolute()
COVERS_DIR = SERVER_DIR / "covers"
SQL_DB_PATH = SERVER_DIR / "music.db"

# Pulls the secret folder from your local .env file
MUSIC_DIR = os.getenv("MUSIC_DIR")

if not MUSIC_DIR:
    raise RuntimeError("CRITICAL: MUSIC_DIR is not set in the .env file!")

# Convert MUSIC_DIR to a Path object for safety
MUSIC_DIR = Path(MUSIC_DIR)


def get_mac_internet_ping():
    """Measures how fast the Mac Mini can reach the outside internet"""
    try:
        start_time = time.time()
        requests.get(
            "http://captive.apple.com/hotspot-detect.html", timeout=1.5)
        return (time.time() - start_time) * 1000
    except Exception:
        return 999.0


@app.get("/health")
def health_check():
    mac_ping = get_mac_internet_ping()
    return {
        "status": "online",
        "timestamp": time.time(),
        "mac_outward_ping": mac_ping
    }


@app.get("/songs")
def get_songs():
    try:
        conn = sqlite3.connect(SQL_DB_PATH)
        conn.row_factory = sqlite3.Row
        cursor = conn.cursor()

        cursor.execute(
            "SELECT filename, title, artist, album, artwork_url FROM songs")
        rows = cursor.fetchall()
        conn.close()

        # Advanced Python trick to convert SQLite rows to Dicts instantly
        song_list = [dict(row) for row in rows]
        return {"songs": song_list}

    except sqlite3.Error as e:
        print(f"Database error: {e}")
        return {"songs": []}


@app.get("/stream/{filename}")
def stream(filename: str):
    file_path = MUSIC_DIR / filename

    # Path Traversal Security Check
    try:
        file_path.resolve().relative_to(MUSIC_DIR.resolve())
    except ValueError:
        raise HTTPException(status_code=403, detail="Forbidden")

    if not file_path.exists():
        raise HTTPException(status_code=404, detail="Not Found")

    return FileResponse(file_path, media_type="audio/mpeg")


@app.get("/cover/{filename}")
def get_cover(filename: str):
    file_path = COVERS_DIR / filename

    try:
        file_path.resolve().relative_to(COVERS_DIR.resolve())
    except ValueError:
        raise HTTPException(status_code=403, detail="Forbidden")

    if not file_path.exists():
        raise HTTPException(status_code=404, detail="Not Found")

    return FileResponse(file_path)


@app.get("/download-db")
def download_database():
    if not SQL_DB_PATH.exists():
        raise HTTPException(status_code=404, detail="Database not found")
    return FileResponse(SQL_DB_PATH, media_type="application/octet-stream", filename="teddy_music_backup.db")


if __name__ == "__main__":
    print("🚀 Teddy Music Server Live on Port 8000 (Dynamic Routing Powered!)")
    uvicorn.run(app, host="0.0.0.0", port=8000)
