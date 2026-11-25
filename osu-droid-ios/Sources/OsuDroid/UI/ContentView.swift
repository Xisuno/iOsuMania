import SpriteKit
import SwiftUI
import UniformTypeIdentifiers

struct PlaySelection: Identifiable {
    let id = UUID()
    let song: SongEntry
    let difficulty: DifficultyEntry
}

struct ContentView: View {
    @StateObject private var library = SongLibrary()
    @State private var importing = false
    @State private var selection: PlaySelection?
    @AppStorage("audioOffsetMs") private var offsetMs = 0.0

    var body: some View {
        NavigationStack {
            List {
                if library.songs.isEmpty {
                    Text("No songs yet. Tap Import and pick one or more .osz files.")
                        .foregroundStyle(.secondary)
                }
                ForEach(library.songs) { song in
                    Section("\(song.title) — \(song.artist)  (mapped by \(song.creator))") {
                        ForEach(song.difficulties) { diff in
                            Button {
                                selection = PlaySelection(song: song, difficulty: diff)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(diff.version)
                                    Text(String(format: "CS %.1f  AR %.1f  OD %.1f  HP %.1f", diff.cs, diff.ar, diff.od, diff.hp))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Section("Audio offset (ms) — uncalibrated") {
                    Slider(value: $offsetMs, in: -200...200, step: 1)
                    Text("\(Int(offsetMs)) ms").font(.caption)
                }
            }
            .navigationTitle("osu!droid iOS")
            .toolbar {
                Button("Import .osz") { importing = true }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    Task { await library.importArchives(urls) }
                }
            }
            .alert("Import failed", isPresented: Binding(get: { library.lastError != nil },
                                                         set: { if !$0 { library.lastError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(library.lastError ?? "") }
            .task { await library.reload() }
            .fullScreenCover(item: $selection) { sel in
                PlayView(selection: sel, offsetMs: offsetMs)
            }
        }
    }
}

struct PlayView: View {
    let selection: PlaySelection
    let offsetMs: Double
    @Environment(\.dismiss) private var dismiss
    @State private var scene: GameScene?
    @State private var result: PlayResult?
    @State private var loadError: String?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.black.ignoresSafeArea()
                if let scene {
                    SpriteView(scene: scene, preferredFramesPerSecond: 120).ignoresSafeArea()
                }
                if let loadError { Text(loadError).foregroundStyle(.red).padding() }
                Button("✕") { scene?.stopPlayback(); dismiss() }
                    .font(.title2).padding(12).foregroundStyle(.white)
                if let result { ResultView(result: result) { dismiss() } }
            }
            .task { load(size: geo.size) }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false; scene?.stopPlayback() }
        .statusBarHidden(true)
    }

    private func load(size: CGSize) {
        guard scene == nil else { return }
        do {
            let text = try String(contentsOf: selection.difficulty.fileURL, encoding: .utf8)
            let map = try BeatmapParser.parse(text)
            guard !map.hitObjects.isEmpty else { loadError = "This difficulty has no hit objects."; return }
            let audio = SongLibrary.resolveFile(named: map.general.audioFilename, in: selection.song.folder)
            let newScene = GameScene(size: size, beatmap: map, audioURL: audio, offsetMs: offsetMs)
            newScene.onFinish = { r in result = r }
            scene = newScene
        } catch {
            loadError = "Could not load beatmap: \(error.localizedDescription)"
        }
    }
}

struct ResultView: View {
    let result: PlayResult
    let close: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text("Results").font(.largeTitle.bold())
            Text("Score \(result.score)")
            Text(String(format: "Accuracy %.2f%%   Max combo %dx", result.accuracy * 100, result.maxCombo))
            Text("300: \(result.great)   100: \(result.ok)   50: \(result.meh)   Miss: \(result.miss)")
            Button("Back", action: close).buttonStyle(.borderedProminent).padding(.top)
        }
        .padding(32)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
