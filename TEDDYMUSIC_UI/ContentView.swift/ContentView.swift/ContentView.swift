import SwiftUI
import AVFoundation
import MediaPlayer
import Combine
import UIKit
import PhotosUI

// MARK: - 1. Data Models
struct Song: Codable, Hashable, Sendable {
    let filename: String
    let title: String
    let artist: String
    let artwork_url: String
}

struct SongResponse: Codable, Sendable {
    let songs: [Song]
}

struct Playlist: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var coverImageFileName: String?
    var songFilenames: [String]
}

struct HealthResponse: Codable {
    let status: String
    let timestamp: Double
    let mac_outward_ping: Double
}

// MARK: - 2. Native Image Cache & Haptic Engine
class ImageCache {
    static let shared = NSCache<NSString, UIImage>()
}

func triggerHaptic() {
    let generator = UIImpactFeedbackGenerator(style: .light)
    generator.impactOccurred()
}

struct CachedImageView: View {
    let urlString: String
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    
    @State private var image: UIImage? = nil
    
    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.gray.opacity(0.3)
            }
        }
        .frame(width: width, height: height)
        .cornerRadius(cornerRadius)
        .task(id: urlString) {
            await loadImage()
        }
    }
    
    @MainActor
    private func loadImage() async {
        self.image = nil
        
        if let cached = ImageCache.shared.object(forKey: NSString(string: urlString)) {
            self.image = cached
            return
        }
        guard let url = URL(string: urlString) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let downloadedImage = UIImage(data: data) {
                ImageCache.shared.setObject(downloadedImage, forKey: NSString(string: urlString))
                self.image = downloadedImage
            }
        } catch { print("Error loading image: \(error)") }
    }
}

// MARK: - 3. The Audio ViewModel
@MainActor
final class AudioPlayerManager: ObservableObject, @unchecked Sendable {
    @Published var songs: [Song] = []
    @Published var currentSong: Song?
    @Published var isPlaying = false
    @Published var isShuffleOn = false
    
    @Published var playlists: [Playlist] = []
    
    @Published var activeContext: [Song] = []
    @Published var playHistory: [Song] = []
    @Published var upcomingQueue: [Song] = []
    
    @Published var currentTime: Double = 0
    @Published var totalDuration: Double = 0
    @Published var bufferedTime: Double = 0
    @Published var isScrubbing: Bool = false
    
    // Dual Colors for Mesh Background
    @Published var dominantColor: Color = Color.gray
    @Published var secondaryColor: Color = Color.blue
    
    @Published var tunnelPing: Double = 0.0
    @Published var phoneOutwardPing: Double = 0.0
    @Published var serverOutwardPing: Double = 0.0
    @Published var isServerOnline: Bool = false
    
    @Published var totalListeningSeconds: Double = 0
    private var lastSaveTime: Double = 0
    
    private var audioPlayer: AVPlayer?
    private var playerObserver: Any?
    private var timeObserver: Any?
    private var pingTimer: Timer?
    
    let serverIP = "ur_tailscale_ip_here"
    
    init() {
        startPingMonitor()
        loadPlaylists()
        loadStats()
        setupRemoteTransportControls()
        
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
    }
    
    func loadStats() {
        self.totalListeningSeconds = UserDefaults.standard.double(forKey: "totalListeningSeconds")
    }
    
    func saveStats() {
        UserDefaults.standard.set(totalListeningSeconds, forKey: "totalListeningSeconds")
    }
    
    private func setupRemoteTransportControls() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        commandCenter.playCommand.addTarget { [weak self] event in
            self?.togglePlay()
            return .success
        }
        
        commandCenter.pauseCommand.addTarget { [weak self] event in
            self?.togglePlay()
            return .success
        }
        
        commandCenter.nextTrackCommand.addTarget { [weak self] event in
            Task { @MainActor [weak self] in self?.playNext() }
            return .success
        }
        
        commandCenter.previousTrackCommand.addTarget { [weak self] event in
            Task { @MainActor [weak self] in self?.playPrevious() }
            return .success
        }
        
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let positionTime = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime {
                self?.audioPlayer?.seek(to: CMTime(seconds: positionTime, preferredTimescale: 1))
                return .success
            }
            return .commandFailed
        }
    }
    
    func updateNowPlayingInfo() {
        guard let song = currentSong else { return }
        
        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = song.title
        
        let pingStatus = isServerOnline ? "🟢 \(Int(tunnelPing))ms" : "🔴 Offline"
        nowPlayingInfo[MPMediaItemPropertyArtist] = "\(song.artist) • \(pingStatus)"
        
        if let player = audioPlayer {
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime().seconds
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = totalDuration
            nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = player.rate
        }
        
        if let cachedImage = ImageCache.shared.object(forKey: NSString(string: song.artwork_url)) {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: cachedImage.size) { _ in cachedImage }
        }
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
    
    func loadPlaylists() {
        if let data = UserDefaults.standard.data(forKey: "saved_playlists"),
           let decoded = try? JSONDecoder().decode([Playlist].self, from: data) {
            self.playlists = decoded
        }
    }
    
    func savePlaylists() {
        if let encoded = try? JSONEncoder().encode(playlists) {
            UserDefaults.standard.set(encoded, forKey: "saved_playlists")
        }
    }
    
    func createPlaylist(name: String, coverImage: UIImage?) {
        var imageName: String? = nil
        if let image = coverImage {
            let fileName = UUID().uuidString + ".jpg"
            if let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                let fileURL = documentsURL.appendingPathComponent(fileName)
                if let imageData = image.jpegData(compressionQuality: 0.8) {
                    try? imageData.write(to: fileURL)
                    imageName = fileName
                }
            }
        }
        
        let newPlaylist = Playlist(name: name, coverImageFileName: imageName, songFilenames: [])
        playlists.append(newPlaylist)
        savePlaylists()
        triggerHaptic()
    }
    
    func addSongToPlaylist(song: Song, playlist: Playlist) {
        if let index = playlists.firstIndex(where: { $0.id == playlist.id }) {
            if !playlists[index].songFilenames.contains(song.filename) {
                playlists[index].songFilenames.append(song.filename)
                savePlaylists()
                triggerHaptic()
            }
        }
    }
    
    func toggleSongInPlaylist(song: Song, playlistId: UUID) {
        if let index = playlists.firstIndex(where: { $0.id == playlistId }) {
            if playlists[index].songFilenames.contains(song.filename) {
                playlists[index].songFilenames.removeAll { $0 == song.filename }
            } else {
                playlists[index].songFilenames.append(song.filename)
            }
            savePlaylists()
            triggerHaptic()
        }
    }
    
    func removeSongsFromPlaylist(at offsets: IndexSet, playlistId: UUID) {
        if let index = playlists.firstIndex(where: { $0.id == playlistId }) {
            playlists[index].songFilenames.remove(atOffsets: offsets)
            savePlaylists()
            triggerHaptic()
        }
    }
    
    func getSongs(for playlist: Playlist) -> [Song] {
        return playlist.songFilenames.compactMap { filename in
            self.songs.first { $0.filename == filename }
        }
    }
    
    func loadLocalImage(named fileName: String?) -> UIImage? {
        guard let fileName = fileName else { return nil }
        if let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let fileURL = documentsURL.appendingPathComponent(fileName)
            if let data = try? Data(contentsOf: fileURL) {
                return UIImage(data: data)
            }
        }
        return nil
    }
    
    func startPingMonitor() {
        pingTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                await self.checkServerHealth()
                await self.checkPhoneInternet()
            }
        }
    }
    
    private func checkServerHealth() async {
        guard let url = URL(string: "http://\(serverIP):8000/health") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.0
        
        let startTime = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                let endTime = Date()
                let tPing = endTime.timeIntervalSince(startTime) * 1000
                
                if let decoded = try? JSONDecoder().decode(HealthResponse.self, from: data) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        self.serverOutwardPing = decoded.mac_outward_ping
                        self.tunnelPing = tPing
                        self.isServerOnline = true
                    }
                }
                self.updateNowPlayingInfo()
            } else {
                withAnimation { self.isServerOnline = false; self.serverOutwardPing = 999 }
                self.updateNowPlayingInfo()
            }
        } catch {
            withAnimation { self.isServerOnline = false; self.serverOutwardPing = 999 }
            self.updateNowPlayingInfo()
        }
    }
    
    private func checkPhoneInternet() async {
        guard let url = URL(string: "http://captive.apple.com/hotspot-detect.html") else { return }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 2.0
        
        let startTime = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                let pPing = Date().timeIntervalSince(startTime) * 1000
                withAnimation(.easeInOut(duration: 0.3)) {
                    self.phoneOutwardPing = pPing
                }
            } else {
                withAnimation { self.phoneOutwardPing = 999.0 }
            }
        } catch {
            withAnimation { self.phoneOutwardPing = 999.0 }
        }
    }
    
    func fetchSongs() {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            guard let url = URL(string: "http://\(self.serverIP):8000/songs") else { return }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let decoded = try JSONDecoder().decode(SongResponse.self, from: data)
                self.songs = decoded.songs
            } catch { print("Failed to fetch songs") }
        }
    }
    
    func playSong(song: Song, context: [Song]) {
        triggerHaptic()
        self.activeContext = context
        
        if let current = currentSong {
            playHistory.append(current)
        }
        
        if isShuffleOn {
            upcomingQueue = activeContext.shuffled().filter { $0.filename != song.filename }
        } else {
            if let idx = activeContext.firstIndex(of: song) {
                upcomingQueue = Array(activeContext.dropFirst(idx + 1))
            } else {
                upcomingQueue = []
            }
        }
        startPlayback(for: song)
    }
    
    func playNext() {
        triggerHaptic()
        if upcomingQueue.isEmpty {
            if isShuffleOn {
                upcomingQueue = activeContext.shuffled()
            } else {
                if let first = activeContext.first {
                    playHistory.removeAll()
                    upcomingQueue = Array(activeContext.dropFirst())
                    startPlayback(for: first)
                }
                return
            }
        }
        if let current = currentSong {
            playHistory.append(current)
        }
        let nextSong = upcomingQueue.removeFirst()
        startPlayback(for: nextSong)
    }
    
    func playPrevious() {
        triggerHaptic()
        guard !playHistory.isEmpty else {
            audioPlayer?.seek(to: .zero); audioPlayer?.play()
            return
        }
        if let current = currentSong { upcomingQueue.insert(current, at: 0) }
        let prevSong = playHistory.removeLast()
        startPlayback(for: prevSong)
    }
    
    func playSmartMix() {
        triggerHaptic()
        guard !songs.isEmpty else { return }
        self.activeContext = songs
        withAnimation { isShuffleOn = true }
        
        playHistory.removeAll()
        var randomQueue = songs.shuffled()
        let firstSong = randomQueue.removeFirst()
        upcomingQueue = randomQueue
        startPlayback(for: firstSong)
    }
    
    func toggleShuffle() {
        triggerHaptic()
        withAnimation {
            isShuffleOn.toggle()
            if isShuffleOn {
                upcomingQueue.shuffle()
            } else {
                if let current = currentSong, let idx = activeContext.firstIndex(of: current) {
                    upcomingQueue = Array(activeContext.dropFirst(idx + 1))
                }
            }
        }
    }
    
    private func startPlayback(for song: Song) {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        audioPlayer?.pause()
        if let pObs = playerObserver { NotificationCenter.default.removeObserver(pObs) }
        if let tObs = timeObserver { audioPlayer?.removeTimeObserver(tObs) }
        audioPlayer = nil
        
        currentSong = song
        currentTime = 0; totalDuration = 0; bufferedTime = 0
        extractArtworkColors(from: song.artwork_url) // ⚡️ Using dual colors
        updateNowPlayingInfo()
        
        let encoded = song.filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        guard let url = URL(string: "http://\(serverIP):8000/stream/\(encoded)") else { return }
        
        let playerItem = AVPlayerItem(url: url)
        playerItem.preferredForwardBufferDuration = 1.0
        let newPlayer = AVPlayer(playerItem: playerItem)
        newPlayer.automaticallyWaitsToMinimizeStalling = false
        self.audioPlayer = newPlayer
        self.audioPlayer?.playImmediately(atRate: 1.0)
        isPlaying = true
        
        playerObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.playNext() }
        }
        
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                
                self.totalListeningSeconds += 0.5
                if self.totalListeningSeconds - self.lastSaveTime > 10 {
                    self.saveStats()
                    self.lastSaveTime = self.totalListeningSeconds
                }
                
                if !self.isScrubbing { self.currentTime = time.seconds }
                
                if let duration = self.audioPlayer?.currentItem?.duration.seconds, !duration.isNaN, self.totalDuration == 0 {
                    self.totalDuration = duration
                    self.updateNowPlayingInfo()
                }
                
                if let timeRange = self.audioPlayer?.currentItem?.loadedTimeRanges.first?.timeRangeValue {
                    self.bufferedTime = timeRange.start.seconds + timeRange.duration.seconds
                }
            }
        }
    }
    
    func togglePlay() {
        triggerHaptic()
        guard let player = audioPlayer else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
        updateNowPlayingInfo()
    }
    
    func skipForward() {
        triggerHaptic()
        guard let player = audioPlayer else { return }
        let targetTime = min(currentTime + 10.0, totalDuration)
        currentTime = targetTime
        player.seek(to: CMTime(seconds: targetTime, preferredTimescale: 1))
        updateNowPlayingInfo()
    }
    
    func skipBackward() {
        triggerHaptic()
        guard let player = audioPlayer else { return }
        let targetTime = max(currentTime - 10.0, 0.0)
        currentTime = targetTime
        player.seek(to: CMTime(seconds: targetTime, preferredTimescale: 1))
        updateNowPlayingInfo()
    }
    
    func seek(to percentage: Double) {
        let targetTime = CMTime(seconds: totalDuration * percentage, preferredTimescale: 1)
        audioPlayer?.seek(to: targetTime)
        updateNowPlayingInfo()
    }
    
    // Dual Color Space Extraction for Mesh Background
    private func extractArtworkColors(from urlString: String) {
        guard let url = URL(string: urlString) else { return }
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                if let cached = ImageCache.shared.object(forKey: NSString(string: urlString)) {
                    let colors = cached.splitColors
                    withAnimation(.easeInOut(duration: 1.0)) {
                        self.dominantColor = colors.primary
                        self.secondaryColor = colors.secondary
                    }
                    self.updateNowPlayingInfo()
                    return
                }
                let (data, _) = try await URLSession.shared.data(from: url)
                if let image = UIImage(data: data) {
                    ImageCache.shared.setObject(image, forKey: NSString(string: urlString))
                    let colors = image.splitColors
                    withAnimation(.easeInOut(duration: 1.0)) {
                        self.dominantColor = colors.primary
                        self.secondaryColor = colors.secondary
                    }
                    self.updateNowPlayingInfo()
                }
            } catch { print("Could not extract dual colors") }
        }
    }
    
    func formatTime(_ time: Double) -> String {
        guard !time.isNaN && !time.isInfinite else { return "0:00" }
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - 4. Main App & ZStack Animation Architecture
struct ContentView: View {
    @StateObject private var manager = AudioPlayerManager()
    
    @State private var searchText = ""
    @State private var selectedTab = 0
    @State private var showFullPlayer = false
    
    @Namespace private var animation

    var filteredSongs: [Song] {
        if searchText.isEmpty { return manager.songs }
        return manager.songs.filter { $0.title.localizedCaseInsensitiveContains(searchText) || $0.artist.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                NavigationView {
                    HomeView(manager: manager)
                        .navigationBarHidden(true)
                        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: manager.currentSong != nil ? 60 : 0) }
                }
                .tabItem { Label("Home", systemImage: "house") }.tag(0)

                NavigationView {
                    VStack(spacing: 0) {
                        HStack {
                            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                            TextField("Search titles or artists...", text: $searchText)
                                .textFieldStyle(PlainTextFieldStyle()).autocorrectionDisabled()
                        }
                        .padding(8).background(Color(.systemGray6)).cornerRadius(8)
                        .padding(.horizontal).padding(.top, 5).padding(.bottom, 10)

                        List(filteredSongs, id: \.filename) { song in
                            Button(action: {
                                manager.playSong(song: song, context: filteredSongs)
                            }) {
                                HStack {
                                    CachedImageView(urlString: song.artwork_url, width: 50, height: 50, cornerRadius: 6)
                                    VStack(alignment: .leading) {
                                        Text(song.title).font(.subheadline).bold().foregroundColor(manager.currentSong?.filename == song.filename ? .blue : .primary)
                                        Text(song.artist).font(.caption).foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                        .listStyle(.plain).scrollDismissesKeyboard(.immediately)
                    }
                    .navigationTitle("Search")
                    .safeAreaInset(edge: .bottom) { Color.clear.frame(height: manager.currentSong != nil ? 60 : 0) }
                }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(1)

                NavigationView {
                    LibraryView(manager: manager)
                        .navigationTitle("My Library")
                        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: manager.currentSong != nil ? 60 : 0) }
                }
                .tabItem { Label("My Library", systemImage: "books.vertical") }.tag(2)

                NavigationView {
                    CreatePlaylistView(manager: manager, selectedTab: $selectedTab)
                        .navigationTitle("Create Playlist")
                        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: manager.currentSong != nil ? 60 : 0) }
                }
                .tabItem { Label("Create", systemImage: "plus.square") }.tag(3)
            }
            
            if manager.currentSong != nil && !showFullPlayer {
                MiniPlayerView(manager: manager, showFullPlayer: $showFullPlayer, animation: animation)
                    .padding(.bottom, 50)
                    .zIndex(1)
            }
            
            if showFullPlayer {
                FullPlayerView(manager: manager, showFullPlayer: $showFullPlayer, animation: animation)
                    .transition(.move(edge: .bottom))
                    .zIndex(2)
            }
        }
        .onAppear { manager.fetchSongs() }
    }
}

// MARK: - 5. Premium Home View
struct HomeView: View {
    @ObservedObject var manager: AudioPlayerManager

    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [manager.dominantColor.opacity(0.4), Color(.systemBackground)]),
                startPoint: .top,
                endPoint: .center
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    
                    HStack(alignment: .center) {
                        Text(greetingText())
                            .font(.largeTitle).bold()
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.top, 20)
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            HStack(spacing: 6) {
                                Text("📱")
                                Text("\(Int(manager.phoneOutwardPing))ms")
                                    .font(.caption2).bold().foregroundColor(.primary)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(manager.phoneOutwardPing < 150 ? Color.green.opacity(0.3) : Color.yellow.opacity(0.3))
                            .cornerRadius(20)
                            
                            HStack(spacing: 6) {
                                Text("🔗")
                                Text(manager.isServerOnline ? "\(Int(manager.tunnelPing))ms" : "Offline")
                                    .font(.caption2).bold().foregroundColor(.primary)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(manager.isServerOnline ? (manager.tunnelPing < 150 ? Color.blue.opacity(0.3) : Color.orange.opacity(0.3)) : Color.red.opacity(0.3))
                            .cornerRadius(20)
                            
                            HStack(spacing: 6) {
                                Text("🖥️")
                                Text("\(Int(manager.serverOutwardPing))ms")
                                    .font(.caption2).bold().foregroundColor(.primary)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(manager.serverOutwardPing < 150 ? Color.green.opacity(0.3) : Color.yellow.opacity(0.3))
                            .cornerRadius(20)
                        }
                        .padding(.horizontal)
                    }
                    
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Your Listening Stats")
                            .font(.title2).bold()
                            .padding(.horizontal)
                        
                        HStack {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Total Time Listened")
                                    .font(.headline)
                                    .foregroundColor(.white.opacity(0.8))
                                
                                let totalMinutes = Int(manager.totalListeningSeconds) / 60
                                let hours = totalMinutes / 60
                                let mins = totalMinutes % 60
                                
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    if hours > 0 {
                                        Text("\(hours)").font(.system(size: 40, weight: .bold, design: .rounded)).foregroundColor(.white)
                                        Text("hr").font(.headline).foregroundColor(.white.opacity(0.6))
                                    }
                                    Text("\(mins)").font(.system(size: 40, weight: .bold, design: .rounded)).foregroundColor(.white)
                                    Text("min").font(.headline).foregroundColor(.white.opacity(0.6))
                                }
                            }
                            Spacer()
                            Image(systemName: "waveform.path.ecg")
                                .font(.system(size: 50))
                                .foregroundColor(.white.opacity(0.3))
                        }
                        .padding(24)
                        .background(
                            LinearGradient(gradient: Gradient(colors: [Color.blue.opacity(0.8), Color.purple.opacity(0.8)]), startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .cornerRadius(20)
                        .padding(.horizontal)
                        .shadow(color: Color.blue.opacity(0.3), radius: 10, x: 0, y: 5)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        Text("Made For You")
                            .font(.title2).bold()
                            .padding(.horizontal)

                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 16) {
                                SmartMixCard(title: "Discovery Mix", subtitle: "Fresh tracks tailored for you", color: .purple) {
                                    manager.playSmartMix()
                                }
                                .containerRelativeFrame(.horizontal, count: 2, span: 1, spacing: 16)
                                SmartMixCard(title: "Chill Vibes", subtitle: "Relax and unwind", color: .blue) {
                                    manager.playSmartMix()
                                }
                                .containerRelativeFrame(.horizontal, count: 2, span: 1, spacing: 16)
                                SmartMixCard(title: "Heavy Rotation", subtitle: "The songs you love most", color: .orange) {
                                    manager.playSmartMix()
                                }
                                .containerRelativeFrame(.horizontal, count: 2, span: 1, spacing: 16)
                            }
                            .scrollTargetLayout()
                        }
                        .scrollTargetBehavior(.viewAligned)
                        .safeAreaPadding(.horizontal, 20)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        Text("Jump Back In")
                            .font(.title2).bold()
                            .padding(.horizontal)

                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 16) {
                                ForEach(manager.songs.prefix(10), id: \.filename) { song in
                                    Button(action: {
                                        manager.playSong(song: song, context: manager.songs)
                                    }) {
                                        VStack(alignment: .leading) {
                                            CachedImageView(urlString: song.artwork_url, width: 160, height: 160, cornerRadius: 12)
                                                .shadow(color: Color.black.opacity(0.1), radius: 5, x: 0, y: 5)
                                            
                                            Text(song.title).font(.subheadline).bold().foregroundColor(.primary).lineLimit(1)
                                            Text(song.artist).font(.caption).foregroundColor(.secondary).lineLimit(1)
                                        }
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    .containerRelativeFrame(.horizontal, count: 2, span: 1, spacing: 16)
                                }
                            }
                            .scrollTargetLayout()
                        }
                        .scrollTargetBehavior(.viewAligned)
                        .safeAreaPadding(.horizontal, 20)
                    }
                    
                }
                .padding(.bottom, 120)
            }
        }
    }
    
    func greetingText() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 6..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }
}

struct SmartMixCard: View {
    let title: String; let subtitle: String; let color: Color; let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading) {
                Spacer()
                Text(title).font(.title3).bold().foregroundColor(.white)
                Text(subtitle).font(.caption).foregroundColor(.white.opacity(0.8)).multilineTextAlignment(.leading)
            }
            .padding().frame(maxWidth: .infinity, idealHeight: 160, alignment: .bottomLeading)
            .background(LinearGradient(gradient: Gradient(colors: [color.opacity(0.8), color.opacity(0.4)]), startPoint: .topLeading, endPoint: .bottomTrailing))
            .cornerRadius(12).shadow(color: color.opacity(0.3), radius: 8, x: 0, y: 5)
        }
    }
}

// MARK: - 6. PLAYLIST VIEWS
struct LibraryView: View {
    @ObservedObject var manager: AudioPlayerManager
    
    var body: some View {
        if manager.playlists.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "music.note.list").font(.system(size: 50)).foregroundColor(.secondary)
                Text("Your Library is empty.").font(.title2).bold()
                Text("Go to the Create tab to make a new playlist.").foregroundColor(.secondary)
            }
        } else {
            List(manager.playlists) { playlist in
                NavigationLink(destination: PlaylistDetailView(manager: manager, playlistId: playlist.id)) {
                    HStack(spacing: 16) {
                        if let image = manager.loadLocalImage(named: playlist.coverImageFileName) {
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 60, height: 60)
                                .cornerRadius(8)
                        } else {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.gray.opacity(0.3))
                                .frame(width: 60, height: 60)
                                .overlay(Image(systemName: "music.note").foregroundColor(.white))
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text(playlist.name).font(.headline)
                            Text("\(playlist.songFilenames.count) Songs").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.plain)
        }
    }
}

struct PlaylistDetailView: View {
    @ObservedObject var manager: AudioPlayerManager
    let playlistId: UUID
    
    @State private var showAddSongsSheet = false
    
    var playlist: Playlist? {
        manager.playlists.first(where: { $0.id == playlistId })
    }
    
    var playlistSongs: [Song] {
        guard let p = playlist else { return [] }
        return manager.getSongs(for: p)
    }
    
    var body: some View {
        VStack {
            if let p = playlist {
                if let image = manager.loadLocalImage(named: p.coverImageFileName) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 200, height: 200)
                        .cornerRadius(12)
                        .shadow(radius: 10)
                        .padding()
                }
                
                Text(p.name).font(.largeTitle).bold()
                
                if !playlistSongs.isEmpty {
                    Button(action: {
                        manager.playSong(song: playlistSongs[0], context: playlistSongs)
                    }) {
                        HStack {
                            Image(systemName: "play.fill")
                            Text("Play All")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                        .padding(.horizontal)
                    }
                } else {
                    Text("No songs yet. Tap the + to add some!")
                        .foregroundColor(.secondary)
                        .padding()
                }
                
                List {
                    ForEach(playlistSongs, id: \.filename) { song in
                        HStack {
                            CachedImageView(urlString: song.artwork_url, width: 40, height: 40, cornerRadius: 4)
                            VStack(alignment: .leading) {
                                Text(song.title).font(.subheadline).bold()
                                    .foregroundColor(manager.currentSong?.filename == song.filename ? .blue : .primary)
                                Text(song.artist).font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            manager.playSong(song: song, context: playlistSongs)
                        }
                    }
                    .onDelete { offsets in
                        manager.removeSongsFromPlaylist(at: offsets, playlistId: playlistId)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(playlist?.name ?? "Playlist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    showAddSongsSheet = true
                }) {
                    Image(systemName: "plus")
                        .font(.title3)
                        .bold()
                }
            }
        }
        .sheet(isPresented: $showAddSongsSheet) {
            AddSongsSheet(manager: manager, playlistId: playlistId)
        }
    }
}

struct AddSongsSheet: View {
    @ObservedObject var manager: AudioPlayerManager
    let playlistId: UUID
    @Environment(\.dismiss) var dismiss
    
    @State private var searchText = ""
    
    var filteredSongs: [Song] {
        if searchText.isEmpty { return manager.songs }
        return manager.songs.filter { $0.title.localizedCaseInsensitiveContains(searchText) || $0.artist.localizedCaseInsensitiveContains(searchText) }
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("Search to add...", text: $searchText)
                        .textFieldStyle(PlainTextFieldStyle()).autocorrectionDisabled()
                }
                .padding(8).background(Color(.systemGray6)).cornerRadius(8)
                .padding()
                
                List(filteredSongs, id: \.filename) { song in
                    let isInPlaylist = manager.playlists.first(where: { $0.id == playlistId })?.songFilenames.contains(song.filename) ?? false
                    
                    Button(action: {
                        manager.toggleSongInPlaylist(song: song, playlistId: playlistId)
                    }) {
                        HStack {
                            CachedImageView(urlString: song.artwork_url, width: 40, height: 40, cornerRadius: 4)
                            VStack(alignment: .leading) {
                                Text(song.title).font(.subheadline).bold()
                                Text(song.artist).font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            
                            if isInPlaylist {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.blue)
                                    .font(.title2)
                            } else {
                                Image(systemName: "plus.circle")
                                    .foregroundColor(.gray.opacity(0.5))
                                    .font(.title2)
                            }
                        }
                    }
                    .foregroundColor(.primary)
                }
                .listStyle(.plain)
                .scrollDismissesKeyboard(.immediately)
            }
            .navigationTitle("Add Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .bold()
                }
            }
        }
    }
}

struct CreatePlaylistView: View {
    @ObservedObject var manager: AudioPlayerManager
    @Binding var selectedTab: Int
    
    @State private var playlistName: String = ""
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var selectedImage: UIImage? = nil
    
    @FocusState private var isKeyboardFocused: Bool
    
    var body: some View {
        Form {
            Section(header: Text("Playlist Details")) {
                TextField("Playlist Name", text: $playlistName)
                    .focused($isKeyboardFocused)
                    .submitLabel(.done)
            }
            
            Section(header: Text("Cover Art")) {
                PhotosPicker(selection: $selectedPhotoItem, matching: .images, photoLibrary: .shared()) {
                    HStack {
                        Image(systemName: "photo")
                        Text("Select Photo from Gallery")
                    }
                }
                .onChange(of: selectedPhotoItem) { newItem in
                    Task {
                        if let data = try? await newItem?.loadTransferable(type: Data.self),
                           let uiImage = UIImage(data: data) {
                            selectedImage = uiImage
                        }
                    }
                }
                
                if let image = selectedImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 200)
                        .cornerRadius(8)
                }
            }
            
            Button(action: {
                isKeyboardFocused = false
                manager.createPlaylist(name: playlistName, coverImage: selectedImage)
                
                playlistName = ""
                selectedImage = nil
                selectedPhotoItem = nil
                selectedTab = 2
            }) {
                Text("Create Playlist")
                    .bold()
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .disabled(playlistName.isEmpty)
        }
        .scrollDismissesKeyboard(.immediately)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    isKeyboardFocused = false
                }
            }
        }
    }
}

// MARK: - 7. Mini Player View
struct MiniPlayerView: View {
    @ObservedObject var manager: AudioPlayerManager
    @Binding var showFullPlayer: Bool
    var animation: Namespace.ID
    
    // State to track swipe movement visually
    @State private var dragOffset: CGFloat = 0
    
    var body: some View {
        if let song = manager.currentSong {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    CachedImageView(urlString: song.artwork_url, width: 44, height: 44, cornerRadius: 6)
                        .matchedGeometryEffect(id: "albumArt", in: animation)
                        .shadow(radius: 2)
                        .offset(x: dragOffset) // Visual wiggle on drag
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.title).font(.subheadline).bold().lineLimit(1).foregroundColor(.white)
                        Text(song.artist).font(.caption).foregroundColor(.white.opacity(0.8)).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "tv.and.hifispeaker.fill").font(.system(size: 14)).foregroundColor(.white.opacity(0.8)).padding(.trailing, 4)
                    Button(action: manager.togglePlay) { Image(systemName: manager.isPlaying ? "pause.fill" : "play.fill").font(.title2).foregroundColor(.white).frame(width: 30, height: 30) }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .contentShape(Rectangle())
                .onTapGesture {
                    triggerHaptic()
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.8, blendDuration: 0)) {
                        showFullPlayer = true
                    }
                }
                // Swipe Gestures to skip tracks directly from the Mini Player
                .gesture(
                    DragGesture()
                        .onChanged { gesture in
                            dragOffset = gesture.translation.width * 0.4
                        }
                        .onEnded { gesture in
                            let threshold: CGFloat = 60
                            if gesture.translation.width < -threshold {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { manager.playNext() }
                            } else if gesture.translation.width > threshold {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { manager.playPrevious() }
                            }
                            withAnimation(.spring()) { dragOffset = 0 }
                        }
                )

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.white.opacity(0.3))
                        Rectangle().fill(Color.white)
                            .frame(width: max(0, min(geometry.size.width, geometry.size.width * CGFloat(manager.currentTime / max(manager.totalDuration, 1)))))
                            .animation(.linear(duration: 0.5), value: manager.currentTime)
                    }
                }
                .frame(height: 2)
            }
            .background(ZStack {
                Rectangle().fill(.ultraThinMaterial)
                LinearGradient(gradient: Gradient(colors: [manager.dominantColor.opacity(0.6), manager.dominantColor.opacity(0.2)]), startPoint: .leading, endPoint: .trailing)
            })
            .cornerRadius(12)
            .padding(.horizontal, 8).padding(.bottom, 6)
            .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 5)
        }
    }
}

// MARK: - 8. Full Player View
struct FullPlayerView: View {
    @ObservedObject var manager: AudioPlayerManager
    @Binding var showFullPlayer: Bool
    var animation: Namespace.ID
    
    @State private var recordRotation: Double = 0
    @State private var isShowingQueue = false // Tracks if the record is flipped
    
    let timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()
    
    var body: some View {
        if let song = manager.currentSong {
            ZStack {
                // Dynamic Mesh Fluid Background
                MeshFluidBackgroundView(primary: manager.dominantColor, secondary: manager.secondaryColor)
                
                VStack {
                    HStack {
                        Button(action: {
                            triggerHaptic()
                            withAnimation(.spring(response: 0.5, dampingFraction: 0.8, blendDuration: 0)) {
                                showFullPlayer = false
                            }
                        }) {
                            Image(systemName: "chevron.down").font(.title2).foregroundColor(.white).padding()
                        }
                        Spacer()
                        Text("NOW PLAYING").font(.caption).bold().foregroundColor(.white.opacity(0.7))
                        Spacer()
                        
                        //  Menu merged with the new 3D Queue Flip Button
                        HStack(spacing: 16) {
                            Button(action: {
                                triggerHaptic()
                                withAnimation(.spring(response: 0.55, dampingFraction: 0.8)) {
                                    isShowingQueue.toggle()
                                }
                            }) {
                                Image(systemName: isShowingQueue ? "music.note" : "list.bullet")
                                    .font(.title2).foregroundColor(.white).frame(width: 30, height: 30)
                            }
                            
                            Menu {
                                Text("Add to Playlist...").font(.caption)
                                Divider()
                                if manager.playlists.isEmpty {
                                    Text("No playlists created yet.")
                                } else {
                                    ForEach(manager.playlists) { playlist in
                                        Button(action: { manager.addSongToPlaylist(song: song, playlist: playlist) }) {
                                            Label(playlist.name, systemImage: "music.note.list")
                                        }
                                    }
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.title2).foregroundColor(.white).frame(width: 30, height: 30).contentShape(Rectangle())
                            }
                        }.padding(.trailing)
                    }
                    .padding(.top, 40)
                    Spacer()

                    // 3D Flippable Record Container
                    ZStack {
                        if !isShowingQueue {
                            // Front of card: Spinning Record
                            ZStack {
                                CachedImageView(urlString: song.artwork_url, width: 320, height: 320, cornerRadius: 160)
                                    .matchedGeometryEffect(id: "albumArt", in: animation)
                                VinylRecordGroovesOverlay()
                                    .frame(width: 320, height: 320)
                            }
                            .rotationEffect(.degrees(recordRotation))
                            .transition(.asymmetric(insertion: .opacity, removal: .opacity))
                        } else {
                            // Back of card: Queue List
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Up Next")
                                    .font(.headline).foregroundColor(.white).padding(.horizontal, 16).padding(.top, 16)
                                
                                if manager.upcomingQueue.isEmpty {
                                    VStack {
                                        Spacer()
                                        Text("End of queue.").font(.subheadline).foregroundColor(.white.opacity(0.6))
                                        Spacer()
                                    }.frame(maxWidth: .infinity)
                                } else {
                                    ScrollView {
                                        LazyVStack(spacing: 12) {
                                            ForEach(manager.upcomingQueue.prefix(15), id: \.hashValue) { qSong in
                                                HStack(spacing: 12) {
                                                    CachedImageView(urlString: qSong.artwork_url, width: 40, height: 40, cornerRadius: 6)
                                                    VStack(alignment: .leading, spacing: 2) {
                                                        Text(qSong.title).font(.system(size: 14, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                                                        Text(qSong.artist).font(.system(size: 11)).foregroundColor(.white.opacity(0.7)).lineLimit(1)
                                                    }
                                                    Spacer()
                                                }
                                                .padding(.horizontal, 12)
                                                .contentShape(Rectangle())
                                                .onTapGesture { manager.playSong(song: qSong, context: manager.activeContext) }
                                            }
                                        }
                                        .padding(.bottom, 16)
                                    }
                                }
                            }
                            .frame(width: 320, height: 320)
                            .background(.ultraThinMaterial)
                            .cornerRadius(24)
                            .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0)) // Inverts so text isn't backwards
                            .transition(.asymmetric(insertion: .opacity, removal: .opacity))
                        }
                    }
                    .frame(width: 320, height: 320)
                    .shadow(color: Color.black.opacity(0.4), radius: 25, x: 0, y: 12)
                    .rotation3DEffect(.degrees(isShowingQueue ? 180 : 0), axis: (x: 0, y: 1, z: 0)) // Flips the whole container
                    .onReceive(timer) { _ in
                        if manager.isPlaying && !isShowingQueue { recordRotation += 0.5 }
                    }
                    
                    Spacer()

                    VStack(alignment: .leading, spacing: 5) {
                        Text(song.title).font(.title).bold().lineLimit(1).foregroundColor(.white)
                        Text(song.artist).font(.title3).foregroundColor(.white.opacity(0.7)).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24)

                    VStack(spacing: 8) {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.3)).frame(height: 6)
                                Capsule().fill(Color.white.opacity(0.6)).frame(width: max(0, min(geometry.size.width, geometry.size.width * CGFloat(manager.bufferedTime / max(manager.totalDuration, 1)))), height: 6)
                                Capsule().fill(Color.white).frame(width: max(0, min(geometry.size.width, geometry.size.width * CGFloat(manager.currentTime / max(manager.totalDuration, 1)))), height: 6)
                                Circle().fill(Color.white).shadow(radius: 2).frame(width: 18, height: 18)
                                    .offset(x: max(0, min(geometry.size.width - 18, (geometry.size.width * CGFloat(manager.currentTime / max(manager.totalDuration, 1))) - 9)))
                            }
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0)
                                .onChanged { v in manager.isScrubbing = true; manager.currentTime = manager.totalDuration * Double(min(max(0, v.location.x / geometry.size.width), 1)) }
                                .onEnded { v in manager.isScrubbing = false; manager.seek(to: Double(min(max(0, v.location.x / geometry.size.width), 1))) })
                        }.frame(height: 20)
                        
                        HStack {
                            Text(manager.formatTime(manager.currentTime)).font(.caption).foregroundColor(.white.opacity(0.7))
                            Spacer()
                            Text(manager.formatTime(manager.totalDuration)).font(.caption).foregroundColor(.white.opacity(0.7))
                        }
                    }.padding(.horizontal, 24).padding(.top, 10)

                    HStack {
                        Button(action: manager.toggleShuffle) { Image(systemName: manager.isShuffleOn ? "shuffle.circle.fill" : "shuffle").font(.title3).foregroundColor(manager.isShuffleOn ? .blue : .white.opacity(0.6)) }
                        Spacer()
                        Button(action: manager.skipBackward) { Image(systemName: "gobackward.10").font(.title2).foregroundColor(.white) }
                        Spacer()
                        Button(action: manager.playPrevious) { Image(systemName: "backward.end.fill").font(.largeTitle).foregroundColor(.white) }
                        Spacer()
                        Button(action: manager.togglePlay) { Image(systemName: manager.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 70)).foregroundColor(.white) }
                        Spacer()
                        Button(action: manager.playNext) { Image(systemName: "forward.end.fill").font(.largeTitle).foregroundColor(.white) }
                        Spacer()
                        Button(action: manager.skipForward) { Image(systemName: "goforward.10").font(.title2).foregroundColor(.white) }
                        Spacer()
                        Button(action: { }) { Image(systemName: "repeat").font(.title3).foregroundColor(.white.opacity(0.2)) }
                    }.padding(.horizontal, 30).padding(.top, 20).padding(.bottom, 60)
                }
            }
            .ignoresSafeArea()
        }
    }
}

// MARK: - 9. Static Grooves Layer
struct VinylRecordGroovesOverlay: View {
    let vinylReflection = AngularGradient(gradient: Gradient(colors: [Color(white: 0.15).opacity(0.5), Color.black.opacity(0.5), Color(white: 0.15).opacity(0.5), Color.black.opacity(0.5), Color(white: 0.15).opacity(0.5)]), center: .center)

    var body: some View {
        ZStack {
            Circle().fill(vinylReflection)
            ForEach(1..<6) { i in Circle().stroke(Color.white.opacity(0.1), lineWidth: 1).padding(CGFloat(i * 24)) }
            
            Circle().fill(Color.black).frame(width: 14, height: 14)
            Circle().fill(Color(white: 0.8)).frame(width: 6, height: 6)
        }
        .clipShape(Circle())
    }
}

// MARK: - 10.  Animated Mesh Background
struct MeshFluidBackgroundView: View {
    let primary: Color
    let secondary: Color
    
    var body: some View {
        ZStack {
            Color.black // Base darkness anchor
            
            // Continuous Ambient Orbit Canvas
            if #available(iOS 17.0, *) {
                PhaseAnimator([false, true]) { phase in
                    ZStack {
                        // Blob Shape 1
                        Circle()
                            .fill(primary.opacity(0.45))
                            .frame(width: 450, height: 450)
                            .offset(x: phase ? -80 : 60, y: phase ? -140 : -40)
                            .scaleEffect(phase ? 1.15 : 0.9)
                        
                        // Blob Shape 2
                        Circle()
                            .fill(secondary.opacity(0.35))
                            .frame(width: 400, height: 400)
                            .offset(x: phase ? 90 : -50, y: phase ? 60 : -100)
                            .scaleEffect(phase ? 0.85 : 1.2)
                        
                        // Center Glow
                        Circle()
                            .fill(primary.opacity(0.2))
                            .frame(width: 300, height: 300)
                            .offset(y: 40)
                    }
                    .blur(radius: 95)
                } animation: { _ in
                    .linear(duration: 9.0).repeatForever(autoreverses: true)
                }
            } else {
                // Fallback for ip i3 iOS versions
                LinearGradient(gradient: Gradient(colors: [primary.opacity(0.9), secondary.opacity(0.2)]), startPoint: .top, endPoint: .bottom)
            }
        }
    }
}

// MARK: - 11. Dual Color Space Extraction
extension UIImage {
    var splitColors: (primary: Color, secondary: Color) {
        guard let cgImage = self.cgImage else { return (Color.gray, Color.blue) }
        var bitmap = [UInt8](repeating: 0, count: 16)
        let context = CGContext(data: &bitmap, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: 2, height: 2))
        
        let c1 = Color(red: Double(bitmap[0]) / 255.0, green: Double(bitmap[1]) / 255.0, blue: Double(bitmap[2]) / 255.0)
        let c2 = Color(red: Double(bitmap[8]) / 255.0, green: Double(bitmap[9]) / 255.0, blue: Double(bitmap[10]) / 255.0)
        return (c1, c2)
    }
}
