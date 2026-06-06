# 🧸 Teddy Music

A self-hosted, Tailscale-routed iOS music player. This repository contains both the **FastAPI Python backend** and the **native SwiftUI iOS frontend**.

---

## 🛑 Before We Start
While this guide references macOS paths for the initial setup, **I highly recommend using a Raspberry Pi as your dedicated 24/7 server**. 

Because the backend is built on pure Python and FastAPI, it is completely cross-platform. You can run this server perfectly on a **Raspberry Pi, a Windows PC, or a Mac**. Just make sure you adjust your folder paths in the `.env` file to match your specific operating system!

---

## ✨ Features
* **Hybrid Database:** Scans local `.mp3` ID3 tags and automatically falls back to the iTunes API for missing 600x600 cover art.
* **Native iOS Client:** Pure SwiftUI architecture with Haptic Feedback, Background Playback, and Control Center support.
* **Live Telemetry:** Real-time server ping monitoring built directly into the UI.
* **Fluid UI:** Dynamic mesh gradients that automatically extract and match the dual-color space of the currently playing album art.

---

## 🛠 Prerequisites

Before you begin, ensure you have the following installed:
* **Server (Raspberry Pi / Mac / Windows):** Python 3.10+ installed.
* **Client (Mac):** Xcode 15+ installed.
* **Network:** Tailscale installed and authenticated on both your Server and your iOS Device.

---

## 🖥 Part 1: Backend Setup (The Server)

The backend is responsible for scanning your local `.mp3` files, extracting metadata, and serving the audio over a secure FastAPI endpoint.

### 1. Clone the Repository
Open your Terminal (or Command Prompt) and clone this project:
```bash
git clone [https://github.com/YOUR_USERNAME/teddy-music-server.git](https://github.com/YOUR_USERNAME/teddy-music-server.git)
cd teddy-music-server
```

### 2. Set Up the Virtual Environment
To keep dependencies isolated, create and activate a virtual Python environment:

**On Mac / Raspberry Pi / Linux:**
```bash
python3 -m venv .venv
source .venv/bin/activate
```

**On Windows:**
```cmd
python -m venv .venv
.venv\Scripts\activate
```

### 3. Install Dependencies
Install the required Python packages directly into your virtual environment:
```bash
pip install fastapi "uvicorn[standard]" requests python-dotenv mutagen
```

### 4. Configure Environment Variables
You must tell the server where your music lives and what your Tailscale IP is.
1. Create a file named `.env` in the root of the server folder.
2. Add your absolute path to your music folder and your Tailscale IP:

**Example (.env):**
```text
MUSIC_DIR=/Users/YourUsername/Path/To/Your/Songs
TAILSCALE_IP=100.x.x.x
```
> **Note:** Ensure your `.env` file is added to your `.gitignore` so your personal paths are not pushed to GitHub.

### 5. Build the Database
Run the hybrid scanner to build the SQLite database:
```bash
python build_db.py
```

### 6. Start the Server
Boot up the Uvicorn server:
```bash
python main.py
```
*You should see a message confirming the server is live on Port 8000. Keep this terminal window running.*

---

## 📱 Part 2: Frontend Setup (The iOS Client)

### 1. Open the Project
Navigate to the iOS folder and double-click `TeddyMusicApp.xcodeproj` to open it in Xcode.

### 2. Configure Your Network Secrets
The app needs to know where to find your server. Do not hardcode your IP address into the main code files!
1. In Xcode, right-click your main app folder in the left navigator and select **New File > Swift File**.
2. Name it `Secrets.swift`.
3. Add the following code, replacing the IP with your server's exact Tailscale IP:
```swift
import Foundation

struct Secrets {
    static let tailscaleIP = "100.x.x.x" 
}
```
> **Note:** Ensure `Secrets.swift` is added to your `.gitignore`.

### 3. Build and Run
1. Connect your physical iPhone to your Mac via USB.
2. Select your iPhone from the device target list at the top of Xcode.
3. Hit **Cmd + R** to Build and Run.

> **⚠️ Important:** Background audio capabilities, Control Center transport controls, and Taptic Engine haptics will not function correctly on the Xcode Simulator. You must deploy to a physical iOS device to test these features.

---

## 🛑 Troubleshooting

* **App won't load music / shows 🔴 Offline:** Ensure Tailscale is actively connected on *both* the server and the iPhone. Check that the IP address in `Secrets.swift` perfectly matches the server's Tailscale IP.
* **ModuleNotFoundError when running Python:** Ensure your virtual environment is active before running `main.py` or `build_db.py`.
* **High ping tunnel ping:** Please use ethernet cable.