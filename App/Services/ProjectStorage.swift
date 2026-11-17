import Foundation
import SwiftUI
import UniformTypeIdentifiers

actor ProjectStorage {
    static let shared = ProjectStorage()
    
    private let projectsDirectory: URL
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    
    private init() {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        projectsDirectory = docs.appendingPathComponent("ClipStudio_Projects", isDirectory: true)
        try? fileManager.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
        
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }
    
    func listProjects() async throws -> [ProjectSummary] {
        let files = try fileManager.contentsOfDirectory(at: projectsDirectory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles])
        var summaries: [ProjectSummary] = []
        for file in files where file.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: file)
                let project = try decoder.decode(Project.self, from: data)
                let attrs = try fileManager.attributesOfItem(atPath: file.path)
                let size = attrs[.size] as? Int64 ?? 0
                let modDate = attrs[.modificationDate] as? Date ?? Date()
                summaries.append(ProjectSummary(
                    id: project.id,
                    name: project.name,
                    episodeCount: project.episodes.count,
                    sourceDuration: project.sourceVideoDuration,
                    updatedAt: modDate,
                    fileSize: size,
                    fileURL: file,
                    thumbnailURL: project.mediaAssets.first(where: { $0.type == .video })?.thumbnailFileURL
                ))
            } catch {
                print("Failed to decode project \(file): \(error)")
            }
        }
        return summaries.sorted { $0.updatedAt > $1.updatedAt }
    }
    
    func loadProject(id: UUID) async throws -> Project {
        let file = projectsDirectory.appendingPathComponent("\(id.uuidString).json")
        do {
            let data = try Data(contentsOf: file)
            return try decoder.decode(Project.self, from: data)
        } catch {
            // Recover from the last good copy if the main file is missing or damaged.
            guard let backup = try? Data(contentsOf: backupURL(for: id)),
                  let project = try? decoder.decode(Project.self, from: backup) else { throw error }
            return project
        }
    }

    private func backupURL(for id: UUID) -> URL {
        projectsDirectory.appendingPathComponent("\(id.uuidString).backup")
    }
    
    func loadProject(url: URL) async throws -> Project {
        let data = try Data(contentsOf: url)
        return try decoder.decode(Project.self, from: data)
    }
    
    func saveProject(_ project: Project) async throws {
        var project = project
        project.updateTimestamp()
        let file = projectsDirectory.appendingPathComponent("\(project.id.uuidString).json")
        let data = try encoder.encode(project)
        if let previous = try? Data(contentsOf: file),
           (try? decoder.decode(Project.self, from: previous)) != nil {
            try? previous.write(to: backupURL(for: project.id), options: .atomic)
        }
        try data.write(to: file, options: .atomic)
    }
    
    func createProject(_ project: Project) async throws {
        let file = projectsDirectory.appendingPathComponent("\(project.id.uuidString).json")
        let data = try encoder.encode(project)
        try data.write(to: file, options: .atomic)
    }
    
    func duplicateProject(_ project: Project, newName: String) async throws -> Project {
        var copy = project
        copy.id = UUID()
        copy.name = newName
        copy.createdAt = Date()
        copy.updatedAt = Date()
        try await saveProject(copy)
        return copy
    }
    
    func deleteProject(id: UUID) async throws {
        let file = projectsDirectory.appendingPathComponent("\(id.uuidString).json")
        try fileManager.removeItem(at: file)
        try? fileManager.removeItem(at: backupURL(for: id))
    }
    
    func exportProject(_ project: Project, to url: URL) async throws {
        var project = project
        project.updateTimestamp()

        var manifest = ProjectPackageManifest()
        var entries = [SimpleZIP.Entry(name: "project.json", data: try encoder.encode(project))]
        var packagedPaths = Set<String>()

        func addStoredFile(_ path: String, folder: String) {
            guard !path.isEmpty, manifest.files[path] == nil else { return }
            let resolvedURL = StoredFileLocator.resolve(path)
            guard fileManager.fileExists(atPath: resolvedURL.path) else { return }
            let ext = resolvedURL.pathExtension
            let filename = "\(UUID().uuidString)\(ext.isEmpty ? "" : "." + ext)"
            let entryName = "\(folder)/\(filename)"
            guard !packagedPaths.contains(entryName) else { return }
            packagedPaths.insert(entryName)
            manifest.files[path] = entryName
            entries.append(SimpleZIP.Entry(name: entryName, fileURL: resolvedURL))
        }

        addStoredFile(project.sourceVideoURL, folder: "media")
        for asset in project.mediaAssets {
            addStoredFile(asset.fileURL, folder: "media")
            if let thumbnailURL = asset.thumbnailURL {
                addStoredFile(thumbnailURL, folder: "thumbnails")
            }
        }
        if let analysis = await AnalysisStore.shared.load(projectID: project.id),
           let analysisData = try? encoder.encode(analysis) {
            entries.append(SimpleZIP.Entry(name: "analysis.json", data: analysisData))
        }
        entries.append(SimpleZIP.Entry(name: "manifest.json", data: try encoder.encode(manifest)))
        try SimpleZIP.write(entries: entries, to: url)
    }
    
    func importProject(from url: URL) async throws -> Project {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let isZIP = isZIPFile(url)
        var packageEntries: [String: URL]? = nil
        var packageDirectory: URL? = nil
        if isZIP {
            let extractedDirectory = fileManager.temporaryDirectory.appendingPathComponent("clipstudio-import-\(UUID().uuidString)", isDirectory: true)
            packageDirectory = extractedDirectory
            packageEntries = try SimpleZIP.extractEntries(from: url, to: extractedDirectory)
        }
        defer {
            if let packageDirectory = packageDirectory {
                try? fileManager.removeItem(at: packageDirectory)
            }
        }
        var copy: Project

        if let entries = packageEntries {
            guard let projectURL = entries["project.json"],
                  let manifestURL = entries["manifest.json"] else {
                throw ImportError.invalidPackage
            }
            copy = try decoder.decode(Project.self, from: try Data(contentsOf: projectURL))
            let manifest = try decoder.decode(ProjectPackageManifest.self, from: try Data(contentsOf: manifestURL))
            var importedPaths: [String: String] = [:]

            for (storedPath, entryName) in manifest.files {
                guard (entryName.hasPrefix("media/") || entryName.hasPrefix("thumbnails/")),
                      !entryName.contains(".."),
                      let extractedURL = entries[entryName] else { continue }
                let directory = entryName.hasPrefix("thumbnails/") ? getThumbnailsDirectory() : getMediaAssetsDirectory()
                let ext = URL(fileURLWithPath: entryName).pathExtension
                let destination = directory.appendingPathComponent("imported_\(UUID().uuidString)\(ext.isEmpty ? "" : "." + ext)")
                try fileManager.moveItem(at: extractedURL, to: destination)
                importedPaths[storedPath] = destination.path
            }

            if let sourcePath = importedPaths[copy.sourceVideoURL] {
                copy.sourceVideoURL = sourcePath
            }
            for index in copy.mediaAssets.indices {
                if let filePath = importedPaths[copy.mediaAssets[index].fileURL] {
                    copy.mediaAssets[index].fileURL = filePath
                }
                if let thumbnailPath = copy.mediaAssets[index].thumbnailURL,
                   let importedThumbnail = importedPaths[thumbnailPath] {
                    copy.mediaAssets[index].thumbnailURL = importedThumbnail
                }
            }
        } else {
            copy = try decoder.decode(Project.self, from: try Data(contentsOf: url))
        }

        copy.id = UUID()
        copy.createdAt = Date()
        copy.updatedAt = Date()

        if let entries = packageEntries,
           let analysisURL = entries["analysis.json"],
           let analysisData = try? Data(contentsOf: analysisURL),
           var analysis = try? decoder.decode(ContentAnalysis.self, from: analysisData) {
            analysis.projectID = copy.id
            analysis.sourceSignature = AnalysisCoordinator.shared.sourceSignature(for: copy)
            try? await AnalysisStore.shared.save(analysis)
        }

        try await saveProject(copy)
        return copy
    }

    private func isZIPFile(_ url: URL) -> Bool {
        guard let input = try? FileHandle(forReadingFrom: url) else { return false }
        defer { input.closeFile() }
        let data = input.readData(ofLength: 4)
        return Array(data) == [0x50, 0x4b, 0x03, 0x04]
    }
}

struct ProjectPackageManifest: Codable {
    var files: [String: String] = [:]
}

enum ProjectDocument {
    static let type = UTType(exportedAs: "com.stropa.clipstudio.project", conformingTo: .data)
    static let contentTypes: [UTType] = [type, .json]
}

enum ImportError: LocalizedError {
    case invalidPackage

    var errorDescription: String? {
        switch self {
        case .invalidPackage: return "O arquivo .clipstudio não contém um projeto válido."
        }
    }
}

struct ProjectSummary: Identifiable {
    let id: UUID
    let name: String
    let episodeCount: Int
    let sourceDuration: Double
    let updatedAt: Date
    let fileSize: Int64
    let fileURL: URL
    let thumbnailURL: URL?
    
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
    
    var formattedDuration: String {
        let h = Int(sourceDuration) / 3600
        let m = (Int(sourceDuration) % 3600) / 60
        let s = Int(sourceDuration) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}

extension ProjectStorage {
    func getExportDirectory() -> URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let exportDir = docs.appendingPathComponent("ClipStudio_Exportados", isDirectory: true)
        try? fileManager.createDirectory(at: exportDir, withIntermediateDirectories: true)
        return exportDir
    }
    
    func getThumbnailsDirectory() -> URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let thumbDir = docs.appendingPathComponent("ClipStudio_Thumbnails", isDirectory: true)
        try? fileManager.createDirectory(at: thumbDir, withIntermediateDirectories: true)
        return thumbDir
    }
    
    func getMediaAssetsDirectory() -> URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let mediaDir = docs.appendingPathComponent("ClipStudio_Media", isDirectory: true)
        try? fileManager.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        return mediaDir
    }
}