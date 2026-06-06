# Teddy Music

A self-hosted, Tailscale-routed iOS music player. This repository contains both the FastAPI Python backend and the native SwiftUI iOS frontend.

## 🛠 Prerequisites
Before you begin, ensure you have the following installed on your systems:
* **Server (Mac/PC):** Python 3.10+ installed.
* **Client (Mac):** Xcode 15+ installed.
* **Network:** Tailscale installed and authenticated on both your Server and your iOS Device.

---

## 🖥 Part 1: Backend Setup (The Server)

The backend is responsible for scanning your local `.mp3` files, extracting ID3 tags, and serving the audio over a secure FastAPI endpoint.

### 1. Clone the Repository
Open your Terminal and clone this project:
```bash
git clone [https://github.com/YOUR_USERNAME/teddy-music-server.git](https://github.com/YOUR_USERNAME/teddy-music-server.git)
cd teddy-music-server
2. Set Up the Python Virtual Environment
To keep dependencies isolated, create and activate a virtual environment:
Bash
python3 -m venv .venv
source .venv/bin/activate
3. Install Dependencies
Install the required Python packages directly into your virtual environment:
Bash
pip install fastapi "uvicorn[standard]" requests python-dotenv mutagen
4. Configure Your Environment Variables
You must tell the server where your music lives and what your Tailscale IP is.
Create a file named .env in the root of the server folder.
Add your absolute path to your music folder and your server's Tailscale IP address:
Plaintext
MUSIC_DIR=/Users/YourUsername/Path/To/Your/Songs
TAILSCALE_IP=100.x.x.x
(Note: Ensure your .env file is added to your .gitignore so it is not pushed to version control.)
5. Build the Database
Run the hybrid scanner. This script will read your MP3 files, extract ID3 tags, fetch missing high-resolution album art from the iTunes API, and build the music.db SQLite database:
Bash
python build_db.py
6. Start the Server
Boot up the Uvicorn server:
Bash
python main.py
You should see a message confirming the server is live on Port 8000. Keep this terminal window running.
📱 Part 2: Frontend Setup (The iOS Client)
The frontend is a pure SwiftUI native iOS application featuring background playback, haptics, and live mesh gradients.
1. Open the Project
Navigate to the iOS folder and double-click TeddyMusicApp.xcodeproj to open it in Xcode.
2. Configure Your Network Secrets
The app needs to know where to find your server. Do not hardcode your IP address into the main code files.
In Xcode, right-click your main app folder in the left navigator and select New File > Swift File.
Name it Secrets.swift.
Add the following code, replacing the IP with your server's exact Tailscale IP:
Swift
import Foundation

struct Secrets {
    static let tailscaleIP = "100.x.x.x" 
}
(Note: Ensure Secrets.swift is added to your .gitignore.)
3. Build and Run
Connect your physical iPhone to your Mac via USB.
Select your iPhone from the device target list at the top of Xcode.
Hit Cmd + R to Build and Run.
Important Note: Background audio capabilities, Control Center transport controls, and Taptic Engine haptics will not function correctly on the Xcode Simulator. You must deploy to a physical iOS device to test these features.
🛑 Troubleshooting
App won't load music / shows 🔴 Offline: Ensure Tailscale is actively connected on both the Mac server and the iPhone. Check that the IP address in Secrets.swift perfectly matches the Mac's Tailscale IP.
ModuleNotFoundError when running Python: Ensure your virtual environment is active (source .venv/bin/activate) before running main.py or build_db.py.