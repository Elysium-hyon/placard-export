import Foundation
import Observation
import SwiftUI
import UIKit
import ZIPFoundation

// MARK: - Errors

enum WallpaperExportError: LocalizedError, Equatable {
    case nothingToExport
    case packageMissing
    case emptyDescriptor
    case archiveFailed(String)

    var errorDescription: String? {
        switch self {
        case .nothingToExport: String(localized: "Nothing was selected.")
        case .packageMissing: String(localized: "The stored package is gone. Install the wallpaper again to download it.")
        case .emptyDescriptor: String(localized: "This wallpaper has no descriptor on disk to export.")
        case .archiveFailed(let detail): String(localized: "Could not build the package: \(detail)")
        }
    }
}

// MARK: - Paths

enum WallpaperExportPaths {
    nonisolated static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Raw `.tendies` packages downloaded from the catalog, kept for later export.
    nonisolated static var packages: URL {
        documents.appending(path: "WallpaperPackages", directoryHint: .isDirectory)
    }

    /// Finished packages handed to the share sheet.
    nonisolated static var exports: URL {
        documents.appending(path: "Exports", directoryHint: .isDirectory)
    }

    nonisolated static func prepare(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

// MARK: - Naming

enum WallpaperPackageNaming {
    /// Strips separators and characters that APFS or the share sheet dislike.
    nonisolated static func sanitized(_ name: String, limit: Int = 80) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = name.components(separatedBy: illegal)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = cleaned.isEmpty ? "Wallpaper" : cleaned
        return String(trimmed.prefix(limit))
    }

    /// Stable 8-hex tag (FNV-1a). Hashing must not change between launches,
    /// otherwise a stored package could no longer be found by its wallpaper.
    nonisolated static func tag(for value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%08x", UInt32(truncatingIfNeeded: hash))
    }
}

// MARK: - Stored packages

struct StoredWallpaperPackage: Identifiable, Hashable, Sendable {
    let url: URL

    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var bytes: Int64 { WallpaperPackageStore.size(of: url) }
}

enum WallpaperPackageStore {
    /// `<Documents>/WallpaperPackages/<name>-<tag>.tendies`
    nonisolated static func destination(for wallpaper: Wallpaper) -> URL {
        let base = WallpaperPackageNaming.sanitized(wallpaper.name)
        let tag = WallpaperPackageNaming.tag(for: wallpaper.url)
        return WallpaperExportPaths.packages.appending(path: "\(base)-\(tag).tendies")
    }

    nonisolated static func existing(for wallpaper: Wallpaper) -> URL? {
        let url = destination(for: wallpaper)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Keeps the downloaded package so it can be re-exported after the temporary
    /// workspace is torn down. Copy-then-move keeps a half-written file invisible.
    ///
    /// An existing copy is always replaced: catalogs republish the same URL with
    /// new artwork, and the stored package must not go stale.
    @discardableResult
    nonisolated static func store(downloaded source: URL, for wallpaper: Wallpaper) throws -> URL {
        try WallpaperExportPaths.prepare(WallpaperExportPaths.packages)
        let destination = destination(for: wallpaper)
        if source.standardizedFileURL == destination.standardizedFileURL { return destination }

        let staging = destination.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.copyItem(at: source, to: staging)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: staging, to: destination)
        return destination
    }

    nonisolated static func all() -> [StoredWallpaperPackage] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: WallpaperExportPaths.packages,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return items
            .filter { $0.pathExtension.lowercased() == "tendies" }
            .map(StoredWallpaperPackage.init(url:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    nonisolated static func remove(_ package: StoredWallpaperPackage) throws {
        try FileManager.default.removeItem(at: package.url)
    }

    nonisolated static func size(of url: URL) -> Int64 {
        let value = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return Int64(value ?? 0)
    }
}

// MARK: - Exporter

enum WallpaperExporter {
    /// Repacks an installed wallpaper's descriptor folder into a `.tendies` file.
    ///
    /// The result is `descriptors/<uuid>/…`, the same shape the catalogs ship,
    /// so it can be imported again by Placard, Pocket Poster or anything else
    /// that understands PosterKit descriptors.
    nonisolated static func export(installed wallpaper: InstalledWallpaper) throws -> URL {
        let manager = FileManager.default
        let staging = manager.temporaryDirectory
            .appending(path: "PlacardExport-\(UUID().uuidString)", directoryHint: .isDirectory)
        try WallpaperExportPaths.prepare(staging)
        defer { try? manager.removeItem(at: staging) }

        _ = try WorseQuery.stageInstalledWallpaper(wallpaper, into: staging)
        let group = staging.appending(path: "descriptors", directoryHint: .isDirectory)
        guard manager.fileExists(atPath: group.path) else { throw WallpaperExportError.emptyDescriptor }

        try WallpaperExportPaths.prepare(WallpaperExportPaths.exports)
        let base = WallpaperPackageNaming.sanitized(wallpaper.name)
        let tag = String(wallpaper.posterUUID.prefix(8))
        let destination = uniqueDestination(in: WallpaperExportPaths.exports,
                                            fileName: "\(base)-\(tag).tendies")
        let stagingArchive = destination.appendingPathExtension("part")
        try? manager.removeItem(at: stagingArchive)

        do {
            try manager.zipItem(at: group, to: stagingArchive,
                                shouldKeepParent: true, compressionMethod: .deflate)
        } catch {
            try? manager.removeItem(at: stagingArchive)
            throw WallpaperExportError.archiveFailed(error.localizedDescription)
        }

        guard let archive = try? Archive(url: stagingArchive, accessMode: .read) else {
            try? manager.removeItem(at: stagingArchive)
            throw WallpaperExportError.archiveFailed(String(localized: "The new archive could not be reopened."))
        }
        var entries = 0
        for _ in archive { entries += 1 }
        guard entries > 0 else {
            try? manager.removeItem(at: stagingArchive)
            throw WallpaperExportError.archiveFailed(String(localized: "The new archive is empty."))
        }

        try manager.moveItem(at: stagingArchive, to: destination)
        return destination
    }

    nonisolated static func export(installed wallpapers: [InstalledWallpaper]) throws -> [URL] {
        guard !wallpapers.isEmpty else { throw WallpaperExportError.nothingToExport }
        return try wallpapers.map { try export(installed: $0) }
    }

    /// Copies packages that were downloaded earlier — byte-identical to what the
    /// catalog served, no repacking involved.
    nonisolated static func export(stored packages: [StoredWallpaperPackage]) throws -> [URL] {
        guard !packages.isEmpty else { throw WallpaperExportError.nothingToExport }
        try WallpaperExportPaths.prepare(WallpaperExportPaths.exports)
        let manager = FileManager.default
        return try packages.map { package in
            guard manager.fileExists(atPath: package.url.path) else {
                throw WallpaperExportError.packageMissing
            }
            let stem = package.url.deletingPathExtension().lastPathComponent
            let destination = uniqueDestination(in: WallpaperExportPaths.exports,
                                               fileName: "\(stem).tendies")
            try manager.copyItem(at: package.url, to: destination)
            return destination
        }
    }

    nonisolated private static func uniqueDestination(in directory: URL, fileName: String) -> URL {
        let manager = FileManager.default
        let stem = (fileName as NSString).deletingPathExtension
        var candidate = directory.appending(path: fileName)
        var counter = 2
        while manager.fileExists(atPath: candidate.path) {
            candidate = directory.appending(path: "\(stem)-\(counter).tendies")
            counter += 1
        }
        return candidate
    }
}

// MARK: - Manager

@MainActor
@Observable
final class WallpaperExportManager {
    enum State: Equatable {
        case idle
        case working(String)
        case ready([URL])
        case failed(String)

        var isWorking: Bool {
            if case .working = self { return true }
            return false
        }
    }

    private(set) var state: State = .idle

    var sharedURLs: [URL] {
        if case .ready(let urls) = state { return urls }
        return []
    }

    var isSharing: Bool {
        if case .ready = state { return true }
        return false
    }

    var failureMessage: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    func export(installed wallpapers: [InstalledWallpaper]) {
        start {
            try WallpaperExporter.export(installed: wallpapers)
        }
    }

    func export(stored packages: [StoredWallpaperPackage]) {
        start {
            try WallpaperExporter.export(stored: packages)
        }
    }

    func reset() {
        guard !state.isWorking else { return }
        state = .idle
    }

    private func start(_ work: @escaping @Sendable () throws -> [URL]) {
        guard !state.isWorking else { return }
        state = .working(String(localized: "Packing wallpaper…"))
        Task {
            do {
                let urls = try await Task.detached(priority: .userInitiated) { try work() }.value
                state = .ready(urls)
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - Share sheet

struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
