import os
import sqlite3
import time
import requests
import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse

app = FastAPI()

# --- Paths ---
# Put your music folder path here:
MUSIC_DIR = "song_path"
# Put your server code folder path here (where the SQL DB and JSON backup will be stored):
SERVER_DIR = "server_code_path"
COVERS_DIR = os.path.join(SERVER_DIR, "covers")
SQL_DB_PATH = os.path.join(SERVER_DIR, "music.db")


def get_mac_internet_ping():
    """Measures how fast the Mac Mini can reach the outside internet"""
    try:
        start_time = time.time()
        # Ping Apple's captive portal page
        requests.get(
            "http://captive.apple.com/hotspot-detect.html", timeout=1.5)
        return (time.time() - start_time) * 1000
    except Exception:
        return 999.0  # Indicates the Mac lost internet

# Health Check with Server Telemetry


@app.get("/health")
def health_check():
    mac_ping = get_mac_internet_ping()
    return {
        "status": "online",
        "timestamp": time.time(),
        "mac_outward_ping": mac_ping
    }

# Fetch Songs from SQL Database


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

        song_list = []
        for row in rows:
            song_list.append({
                "filename": row["filename"],
                "title": row["title"],
                "artist": row["artist"],
                "album": row["album"],
                "artwork_url": row["artwork_url"]
            })

        return {"songs": song_list}

    except sqlite3.Error as e:
        print(f"Database error: {e}")
        return {"songs": []}

# Serve Audio


@app.get("/stream/{filename}")
def stream(filename: str):
    file_path = os.path.join(MUSIC_DIR, filename)
    if not os.path.abspath(file_path).startswith(os.path.abspath(MUSIC_DIR)):
        raise HTTPException(status_code=403, detail="Forbidden")
    if not os.path.exists(file_path):
        raise HTTPException(status_code=404, detail="Not Found")

    return FileResponse(file_path, media_type="audio/mpeg")

# Serve Cover Art


@app.get("/cover/{filename}")
def get_cover(filename: str):
    file_path = os.path.join(COVERS_DIR, filename)

    if not os.path.abspath(file_path).startswith(os.path.abspath(COVERS_DIR)):
        raise HTTPException(status_code=403, detail="Forbidden")
    if not os.path.exists(file_path):
        raise HTTPException(status_code=404, detail="Not Found")

    return FileResponse(file_path)

# Backup SQL Database


@app.get("/download-db")
def download_database():
    if not os.path.exists(SQL_DB_PATH):
        raise HTTPException(status_code=404, detail="Database not found")
    return FileResponse(SQL_DB_PATH, media_type="application/octet-stream", filename="teddy_music_backup.db")


if __name__ == "__main__":
    print("🚀 Teddy Music Server Live on Port 8000 (Triangulation Telemetry Powered!)")
    uvicorn.run(app, host="0.0.0.0", port=8000)
