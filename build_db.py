import os
import json
import requests
import urllib.parse
import re
import sqlite3
from mutagen.mp3 import MP3
from mutagen.id3 import ID3, APIC

# Configuration
# Put your music folder path here:

MUSIC_DIR = "song_path"

# Put your server code folder path here (where the SQL DB and JSON backup will be stored):
SERVER_DIR = "server_code_path"
DB_FILE = os.path.join(SERVER_DIR, "songs.json")
COVERS_DIR = os.path.join(SERVER_DIR, "covers")
SQL_FILE = os.path.join(SERVER_DIR, "music.db")

# TAILSCALE IP
# Put your Tailscale IP address here:
SERVER_IP = "tailscale_ip_or_local_ip"


def clean_filename(filename):
    """Removes junk words and symbols for a better iTunes search."""
    name = filename.replace(".mp3", "").replace(".MP3", "")
    name = re.sub(r'[\(\[].*?[\)\]]', '', name)
    name = name.replace("_", " ").replace("-", " ")
    name = re.sub(r'^\d+\s*', '', name)

    junk_words = ["official", "audio", "video", "lyrics",
                  "clean", "explicit", "hq", "mp3", "download"]
    for word in junk_words:
        name = re.sub(rf'\b{word}\b', '', name, flags=re.IGNORECASE)

    return " ".join(name.split())


def fetch_itunes_metadata(clean_name):
    """Fallback: Asks iTunes for missing title/artist/artwork."""
    url = f"https://itunes.apple.com/search?term={urllib.parse.quote(clean_name)}&entity=song&limit=1"
    try:
        response = requests.get(url, timeout=5)
        if response.status_code == 200:
            data = response.json()
            if data['resultCount'] > 0:
                track = data['results'][0]
                return {
                    "title": track.get('trackName', clean_name),
                    "artist": track.get('artistName', 'Unknown Artist'),
                    "album": track.get('collectionName', 'Unknown Album'),
                    "artwork_url": track.get('artworkUrl100', '').replace('100x100bb', '600x600bb')
                }
    except Exception:
        pass
    return None


def build_and_sync():
    # Prep the SQL Database
    conn = sqlite3.connect(SQL_FILE)
    cursor = conn.cursor()
    cursor.execute('''
    CREATE TABLE IF NOT EXISTS songs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        filename TEXT UNIQUE NOT NULL,
        title TEXT NOT NULL,
        artist TEXT NOT NULL,
        album TEXT NOT NULL,
        artwork_url TEXT NOT NULL
    )
    ''')
    conn.commit()

    # Load existing JSON data to protect manual edits
    existing_db = {}
    if os.path.exists(DB_FILE):
        try:
            with open(DB_FILE, 'r') as f:
                data = json.load(f)
                for song in data.get("songs", []):
                    existing_db[song["filename"]] = song
        except Exception:
            print("⚠️ Could not read existing JSON DB, starting fresh.")

    songs = []

    if not os.path.exists(COVERS_DIR):
        os.makedirs(COVERS_DIR)

    if not os.path.exists(MUSIC_DIR):
        print(f"❌ Error: Folder not found at {MUSIC_DIR}")
        return

    print("🔍 Starting Super Scanner (JSON + SQL)...")

    # Scan all MP3 files in the MUSIC_DIR
    for filename in os.listdir(MUSIC_DIR):
        if filename.lower().endswith(".mp3"):

            # If the code already have it in JSON, SKIP scanning and use saved data
            if filename in existing_db:
                songs.append(existing_db[filename])
                continue

            # If it's a new song,run the Hybrid Scanner
            print(f"🆕 New song detected: {filename}. Scanning...")

            file_path = os.path.join(MUSIC_DIR, filename)
            raw_name = filename.replace(".mp3", "").replace(".MP3", "")

            title = raw_name
            artist = "Unknown Artist"
            album = "Unknown Album"
            artwork_url = None

            # Offline ID3 Scan
            try:
                audio = MP3(file_path, ID3=ID3)
                if audio.tags:
                    if 'TIT2' in audio.tags:
                        title = str(audio.tags.get('TIT2').text[0])
                    if 'TPE1' in audio.tags:
                        artist = str(audio.tags.get('TPE1').text[0])
                    if 'TALB' in audio.tags:
                        album = str(audio.tags.get('TALB').text[0])

                    for tag in audio.tags.values():
                        if isinstance(tag, APIC):
                            img_name = f"{filename}.jpg"
                            img_path = os.path.join(COVERS_DIR, img_name)
                            with open(img_path, 'wb') as f:
                                f.write(tag.data)
                            artwork_url = f"http://{SERVER_IP}:8000/cover/{urllib.parse.quote(img_name)}"
                            break
            except Exception:
                pass

            # Online iTunes Fallback
            if artist == "Unknown Artist" or title == raw_name or not artwork_url:
                clean_name = clean_filename(filename)
                itunes_data = fetch_itunes_metadata(clean_name)
                if itunes_data:
                    title = itunes_data["title"] if title == raw_name else title
                    artist = itunes_data["artist"] if artist == "Unknown Artist" else artist
                    album = itunes_data["album"] if album == "Unknown Album" else album
                    if not artwork_url:
                        artwork_url = itunes_data["artwork_url"]

            # Ultimate Fallback
            if not artwork_url:
                artwork_url = "https://placehold.co/600x600/1C1C1E/FFFFFF/png?text=Music"

            songs.append({
                "filename": filename,
                "title": title,
                "artist": artist,
                "album": album,
                "artwork_url": artwork_url
            })

    # ⚡️ Save the JSON Backup
    with open(DB_FILE, 'w') as f:
        json.dump({"songs": songs}, f, indent=4)
    print(f"📁 JSON Backup updated with {len(songs)} songs.")

    # ⚡️  Save/inject Everything into SQL
    sql_added = 0
    for song in songs:
        try:
            cursor.execute('''
                INSERT INTO songs (filename, title, artist, album, artwork_url)
                VALUES (?, ?, ?, ?, ?)
            ''', (song['filename'], song['title'], song['artist'], song.get('album', 'Unknown Album'), song['artwork_url']))
            sql_added += 1
            print(f"   ✅ Added to SQL: {song['title']}")
        except sqlite3.IntegrityError:
            # Skips duplicates silently
            pass

    conn.commit()
    conn.close()

    print(
        f"\n🎉 Server Backend Ready! Inserted {sql_added} new songs into the active SQL database.")


if __name__ == "__main__":
    build_and_sync()
