# 🎵 Teddy Music
<div align="center">
  <img src="https://via.placeholder.com/800x400/1a1a1a/ffffff?text=Drop+Your+Awesome+App+GIF+Here" alt="Teddy Music Hero" width="100%">

  # 🎵 Teddy Music

  *An uncompromising, self-hosted iOS music ecosystem designed for the modern audio purist.*

  [![SwiftUI](https://img.shields.io/badge/SwiftUI-15.0+-blue.svg?logo=swift&logoColor=white&style=for-the-badge)](https://developer.apple.com/xcode/swiftui/)
  [![Python](https://img.shields.io/badge/Python-3.10+-FFD43B.svg?logo=python&logoColor=blue&style=for-the-badge)](https://www.python.org/)
  [![FastAPI](https://img.shields.io/badge/FastAPI-0.100+-009688.svg?logo=fastapi&logoColor=white&style=for-the-badge)](https://fastapi.tiangolo.com/)
  [![Tailscale](https://img.shields.io/badge/Tailscale-Zero_Trust-black.svg?logo=tailscale&logoColor=white&style=for-the-badge)](https://tailscale.com/)
</div>

---

## 🚀 The Vision
**Teddy Music** bridges the gap between premium commercial streaming interfaces and private, self-hosted audio. It delivers a flagship native iOS frontend that securely streams high-fidelity local audio from a custom Python backend—all routed through a zero-trust Tailscale network. No subscriptions. No tracking. Just pure UI/UX perfection.

---

## ✨ Signature Features

### 🎲 Spatial 3D Queue Flip
> Engineered a custom 3D view matrix using `.rotation3DEffect`. Users can physically spin the active vinyl record 180° to reveal an interactive, gesture-ready upcoming queue.

### 🌊 Algorithmic Mesh Background
> Implemented a SwiftUI `PhaseAnimator` that continuously generates a fluid, breathing mesh gradient. It extracts primary and secondary colors directly from the active album art for a deeply immersive visual tone.

### 📡 Telemetry Triangulation HUD
> A custom-built real-time health monitor that pings the local iOS device, the Tailscale subnet, and the Mac Mini server to display outward internet latency in a sleek, non-intrusive pill layout.

### 📳 Tactile Haptic Engine
> Deep integration with `UIImpactFeedbackGenerator`, mapping UI layout transitions, playback toggles, and track skips to physical, satisfying Taptic Engine responses.

---

## 🧠 Systems Architecture

This repository is a **Monorepo** containing both the client and server codebases, communicating over a secure VPN.

| 📱 The Client (iOS / SwiftUI) | 🖥️ The Server (Python / Mac Mini) | 🔐 The Network (Tailscale) |
| :--- | :--- | :--- |
| **Gesture-driven, MVVM architecture.** Utilizes `@StateObject` and modern `async/await` concurrency. Features a custom Double-Ended Queue (Deque) for seamless track shuffling without dropping main-thread frames. | **FastAPI & SQLite backend.** Features a hybrid ETL pipeline to scan raw MP3s, extract ID3 metadata via Mutagen, fetch missing album art from the iTunes API, and serve the payload with sub-millisecond latency. | **Zero-trust peer-to-peer subnet.** Audio streaming and API queries are strictly routed over Tailscale, completely bypassing traditional port-forwarding vulnerabilities. |

---

## 🛠️ Quick Start Guide

### 1. Boot the Backend Server
Navigate to the server directory on your host machine and spin up the Uvicorn server:
```bash
cd TEDDY_MUSIC_SERVER
uvicorn main:app --host 0.0.0.0 --port 8000