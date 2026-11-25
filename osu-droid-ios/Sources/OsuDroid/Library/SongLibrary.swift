import Foundation
import ZIPFoundation

struct DifficultyEntry: Identifiable, Hashable {
    var id: String { fileURL.path }
    let fileURL: URL
    let version: String
    let cs: Float, ar: Float, od: Float, hp: Float
}

struct SongEntry: Identifiable, Hashable {
    var id: String { folder.path }
    let folder: URL
    let title: String
    let artist: String
    let creator: String
    let difficulties: [DifficultyEntry]
}

enum LibraryError: LocalizedError {
    case unreadable(String)
    var errorDescription: String? {
        switch self { case .unreadable(let m): return m }
    }
}

@MainActor
final class SongLibrary: ObservableObject {
    @Published private(set) var songs: [SongEntry] = []
    @Published var lastError: String?

    nonisolated static var songsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Songs", isDirectory: true)
    }

    func reload() async {
        let found = await Task.detached(priority: .userInitiated) { SongLibrary.scan() }.value
        songs = found
    }

    func importArchives(_ urls: [URL]) async {
        for url in urls {
            do {
                try await Task.detached(priority: .userInitiated) { try SongLibrary.importArchive(url) }.value
            } catch {
                lastError = "\(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        await reload()
    }

    // MARK: - Work done off the main actor

    nonisolated private static func importArchive(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        let name = url.deletingPathExtension().lastPathComponent
        let destination = songsDirectory.appendingPathComponent(name, isDirectory: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) } // re-import replaces
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            try fm.unzipItem(at: url, to: destination)
        } catch {
            try? fm.removeItem(at: destination)
            throw LibraryError.unreadable("Not a valid .osz archive (\(error.localizedDescription))")
        }
    }

    nonisolated static func scan() -> [SongEntry] {
        let fm = FileManager.default
        let root = songsDirectory
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }

        var result: [SongEntry] = []
        for folder in folders {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }

            var difficulties: [DifficultyEntry] = []
            var title = folder.lastPathComponent, artist = "", creator = ""
            for file in files where file.pathExtension.lowercased() == "osu" {
                guard let text = try? String(contentsOf: file, encoding: .utf8),
                      let map = try? BeatmapParser.parse(text, includeHitObjects: false),
                      map.general.mode == 0 else { continue }
                if !map.metadata.title.isEmpty { title = map.metadata.title }
                artist = map.metadata.artist; creator = map.metadata.creator
                difficulties.append(DifficultyEntry(fileURL: file, version: map.metadata.version,
                                                    cs: map.difficulty.cs, ar: map.difficulty.ar,
                                                    od: map.difficulty.od, hp: map.difficulty.hp))
            }
            if !difficulties.isEmpty {
                difficulties.sort { $0.od + $0.ar + $0.cs < $1.od + $1.ar + $1.cs }
                result.append(SongEntry(folder: folder, title: title, artist: artist, creator: creator,
                                        difficulties: difficulties))
            }
        }
        return result.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Case-insensitive lookup of a file named in a .osu inside the beatmap folder.
    nonisolated static func resolveFile(named name: String, in folder: URL) -> URL? {
        let direct = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }
    }
}
