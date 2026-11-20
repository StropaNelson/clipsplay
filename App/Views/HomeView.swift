import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers

struct HomeView: View {
    @StateObject private var viewModel = HomeViewModel()
    @State private var showingNewProject = false
    @State private var showingImport = false
    @State private var showingVideoImport = false
    @State private var showingVideoSource = false
    @State private var openFileImporterAfterSourceDismiss = false
    @State private var projectToEdit: ProjectSummary?
    @State private var newProjectName = ""
    @State private var pendingProjectName: String?
    @State private var pendingOperation: ProjectOperation?
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()
                
                if viewModel.projects.isEmpty && !viewModel.isLoading {
                    emptyState
                } else {
                    projectList
                }
                
                if viewModel.isLoading {
                    ProgressView("Carregando projetos...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(.systemBackground).opacity(0.8))
                }

                if viewModel.isPreparingImport {
                    ProgressView("Preparando vídeos…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(.systemBackground).opacity(0.8))
                }
            }
            .navigationTitle("ClipStudio")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("Novo Projeto", systemImage: "plus") { showingNewProject = true }
                        Button("Importar Projeto", systemImage: "square.and.arrow.down") { showingImport = true }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingNewProject, onDismiss: {
                if pendingProjectName != nil {
                    showingVideoSource = true
                }
            }) {
                NewProjectSheet(onCreate: { name, operation in
                    pendingProjectName = name
                    pendingOperation = operation
                    showingNewProject = false
                })
            }
            .sheet(isPresented: $showingVideoSource, onDismiss: handleVideoSourceDismissal) {
                VideoSourceSheet(
                    onSelectFiles: {
                        openFileImporterAfterSourceDismiss = true
                        showingVideoSource = false
                    },
                    onGalleryPick: { items in
                        showingVideoSource = false
                        handleGalleryVideoSelection(items)
                    }
                )
            }
            .fileImporter(
                isPresented: $showingVideoImport,
                allowedContentTypes: VideoImporter.supportedVideoTypes,
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    guard !urls.isEmpty, let name = pendingProjectName else {
                        pendingProjectName = nil
                        pendingOperation = nil
                        return
                    }
                    pendingProjectName = nil
                    let operation = pendingOperation ?? .multiply
                    pendingOperation = nil
                    Task { await viewModel.prepareImport(name: name, operation: operation, urls: urls) }
                case .failure(let error):
                    pendingProjectName = nil
                    pendingOperation = nil
                    if (error as NSError).code != NSUserCancelledError {
                        viewModel.errorMessage = "Erro ao selecionar vídeo: \(error.localizedDescription)"
                    }
                }
            }
            .fileImporter(
                isPresented: $showingImport,
                allowedContentTypes: ProjectDocument.contentTypes,
                allowsMultipleSelection: false
            ) { result in
                Task {
                    if case .success(let urls) = result, let url = urls.first {
                        await viewModel.importProject(from: url)
                    }
                }
            }
            .sheet(item: $viewModel.shareItem) { item in
                ShareSheet(items: [item.url])
            }
            .sheet(isPresented: Binding(
                get: { viewModel.pendingImport != nil },
                set: { isPresented in
                    if !isPresented { viewModel.cancelPendingImport() }
                }
            )) {
                ReorderSourcesSheet(
                    videos: Binding(
                        get: { viewModel.pendingImport?.videos ?? [] },
                        set: { viewModel.pendingImport?.videos = $0 }
                    ),
                    onConfirm: { Task { await viewModel.confirmPendingImport() } },
                    onCancel: { viewModel.cancelPendingImport() }
                )
            }
            .alert("Erro", isPresented: .constant(viewModel.errorMessage != nil)) {
                Button("OK") { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .fullScreenCover(item: $viewModel.selectedProject) { project in
                EditorView(project: project, initialOperation: viewModel.selectedProjectOperation)
            }
            .refreshable {
                await viewModel.loadProjects()
            }
        }
    }
    
    private var emptyState: some View {
        VStack(spacing: 24) {
            Image(systemName: "film.stack")
                .font(.system(size: 80))
                .foregroundStyle(.secondary)
            
            VStack(spacing: 8) {
                Text("Nenhum projeto ainda")
                    .font(.title2.bold())
                Text("Crie seu primeiro projeto importando um vídeo longo para dividir em episódios.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            
            Button {
                showingNewProject = true
            } label: {
                Label("Criar Projeto", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .frame(width: 220)
                    .padding()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var projectList: some View {
        List {
            ForEach(viewModel.projects) { project in
                ProjectRowView(project: project) {
                    viewModel.selectProject(project)
                } onDuplicate: {
                    projectToEdit = project
                    newProjectName = "\(project.name) (Cópia)"
                } onDelete: {
                    Task { await viewModel.deleteProject(project) }
                } onExport: {
                    Task { await viewModel.exportProjectFile(project) }
                }
                .contextMenu {
                    Button("Editar", systemImage: "pencil") { viewModel.selectProject(project) }
                    Button("Duplicar", systemImage: "doc.on.doc") {
                        projectToEdit = project
                        newProjectName = "\(project.name) (Cópia)"
                    }
                    Button("Exportar Projeto", systemImage: "square.and.arrow.up") {
                        Task { await viewModel.exportProjectFile(project) }
                    }
                    Divider()
                    Button("Excluir", systemImage: "trash", role: .destructive) {
                        Task { await viewModel.deleteProject(project) }
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        Task { await viewModel.deleteProject(project) }
                    } label: {
                        Label("Excluir", systemImage: "trash")
                    }
                    Button {
                        projectToEdit = project
                        newProjectName = "\(project.name) (Cópia)"
                    } label: {
                        Label("Duplicar", systemImage: "doc.on.doc")
                    }
                    .tint(.blue)
                }
            }
        }
        .listStyle(.insetGrouped)
        .sheet(item: $projectToEdit) { project in
            DuplicateProjectSheet(
                projectName: newProjectName,
                onConfirm: { name in
                    Task { await viewModel.duplicateProject(project, newName: name) }
                },
                onCancel: { projectToEdit = nil }
            )
        }
    }

    private func handleVideoSourceDismissal() {
        if openFileImporterAfterSourceDismiss {
            openFileImporterAfterSourceDismiss = false
            showingVideoImport = true
        } else {
            pendingProjectName = nil
            pendingOperation = nil
        }
    }

    private func handleGalleryVideoSelection(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty, let name = pendingProjectName else { return }
        pendingProjectName = nil
        let operation = pendingOperation ?? .multiply
        pendingOperation = nil
        Task { await viewModel.prepareImport(name: name, operation: operation, photosItems: items) }
    }
}

private struct VideoSourceSheet: View {
    let onSelectFiles: () -> Void
    let onGalleryPick: ([PhotosPickerItem]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var gallerySelection: [PhotosPickerItem] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                PhotosPicker(selection: $gallerySelection, matching: .videos) {
                    sourceLabel(
                        title: "Galeria",
                        subtitle: "Escolher um ou mais vídeos do app Fotos",
                        icon: "photo.on.rectangle"
                    )
                }
                .buttonStyle(.plain)

                Button(action: onSelectFiles) {
                    sourceLabel(
                        title: "Arquivos",
                        subtitle: "Escolher um ou mais vídeos em Arquivos",
                        icon: "folder"
                    )
                }
                .buttonStyle(.plain)
            }
            .padding()
            .navigationTitle("Escolher vídeo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
            .onChange(of: gallerySelection) { items in
                guard !items.isEmpty else { return }
                onGalleryPick(items)
            }
        }
        .presentationDetents([.height(260)])
    }

    private func sourceLabel(title: String, subtitle: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 34, height: 34)
                .foregroundStyle(.white)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct ProjectRowView: View {
    let project: ProjectSummary
    let onTap: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void
    let onExport: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 16) {
                thumbnailView
                
                VStack(alignment: .leading, spacing: 6) {
                    Text(project.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    
                    HStack(spacing: 12) {
                        Label("\(project.episodeCount) episódios", systemImage: "film")
                        Label(project.formattedDuration, systemImage: "clock")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    
                    HStack(spacing: 12) {
                        Text(project.updatedAt, style: .relative)
                        Text(project.formattedSize)
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }
    
    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbURL = project.thumbnailURL, let image = UIImage(contentsOfFile: thumbURL.path) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 80, height: 45)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.2))
                .frame(width: 80, height: 45)
                .overlay {
                    Image(systemName: "film")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
        }
    }
}

struct ProjectShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct NewProjectSheet: View {
    let onCreate: (String, ProjectOperation) -> Void
    @State private var name = ""
    @State private var operation: ProjectOperation = .multiply
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Novo Projeto") {
                    TextField("Nome do projeto", text: $name)
                }

                Section("O que você quer criar?") {
                    ForEach(ProjectOperation.allCases) { item in
                        Button {
                            operation = item
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: item == operation ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(item == operation ? Color.accentColor : Color.secondary)
                                Image(systemName: item.icon)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.rawValue)
                                        .foregroundStyle(.primary)
                                    Text(item.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                        .buttonStyle(.plain)
                    }
                }
                
                Section("Importação") {
                    Text("Os vídeos entram na timeline na ordem de gravação — dá para reordenar antes de criar.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Text("Depois da importação, o ClipStudio abre diretamente a automação escolhida. Tudo continua editável na timeline.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Novo Projeto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continuar") { onCreate(name, operation) }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct DuplicateProjectSheet: View {
    @State var projectName: String
    let onConfirm: (String) -> Void
    let onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Duplicar Projeto") {
                    TextField("Nome da cópia", text: $projectName)
                }
            }
            .navigationTitle("Duplicar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { onCancel(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Duplicar") { onConfirm(projectName); dismiss() }
                        .disabled(projectName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.height(200)])
    }
}

@MainActor
class HomeViewModel: ObservableObject {
    /// Selection of probed videos waiting for the user to confirm the order
    /// before the project is created. `tempURLs` holds gallery temp files to
    /// delete on confirm or cancel.
    struct PendingImport {
        var name: String
        var operation: ProjectOperation
        var videos: [PendingVideo]
        var tempURLs: [URL]
    }

    @Published var projects: [ProjectSummary] = []
    @Published var isLoading = false
    @Published var isPreparingImport = false
    @Published var errorMessage: String?
    @Published var selectedProject: Project?
    @Published var selectedProjectOperation: ProjectOperation?
    @Published var shareItem: ProjectShareItem?
    @Published var pendingImport: PendingImport?

    private let storage = ProjectStorage.shared
    private let importer = VideoImporter.shared
    
    func loadProjects() async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            projects = try await storage.listProjects()
        } catch {
            errorMessage = "Erro ao carregar projetos: \(error.localizedDescription)"
        }
    }
    
    func createProject(name: String, from videoURLs: [URL], operation: ProjectOperation) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let primaryURL = videoURLs.first else { return }

        errorMessage = nil
        do {
            var project = try await importer.importVideo(from: primaryURL, projectName: trimmed)
            var sequenceAssets: [MediaAsset] = []
            for url in videoURLs.dropFirst() {
                let asset = try await importer.importMediaAsset(from: url, type: .video)
                project.mediaAssets.append(asset)
                sequenceAssets.append(asset)
            }
            project.operation = operation
            if sequenceAssets.isEmpty {
                project.regenerateEpisodes()
            } else {
                configureSequentialEpisode(&project, assets: sequenceAssets)
            }
            try await storage.saveProject(project)
            await loadProjects()
            selectedProjectOperation = operation
            selectedProject = project
        } catch {
            errorMessage = "Erro ao criar projeto: \(error.localizedDescription)"
        }
    }

    private func configureSequentialEpisode(_ project: inout Project, assets: [MediaAsset]) {
        var sourceClips = [VideoSegment(
            startTime: 0,
            endTime: project.sourceVideoDuration,
            sourceType: .mainVideo,
            sequenceStart: 0
        )]
        var cursor = project.sourceVideoDuration
        for asset in assets {
            sourceClips.append(VideoSegment(
                startTime: 0,
                endTime: asset.duration,
                sourceType: .clipAsset,
                assetID: asset.id,
                sequenceStart: cursor
            ))
            cursor += asset.duration
        }
        project.sourceClips = sourceClips

        var episode = Episode(
            index: 0,
            mainStart: 0,
            mainEnd: cursor,
            introTemplate: project.introTemplate,
            outroTemplate: project.outroTemplate,
            recapSettings: project.recapSettings
        )
        episode.displayTitle = project.operation == .speechEdit ? "Clipe inteiro" : "Clipe em sequência"
        episode.mainClips = sourceClips
        project.episodes = [episode]
        project.updateTimestamp()
    }

    /// Probes the selected files and either creates the project right away
    /// (single video) or opens the reorder sheet with `pendingImport`.
    func prepareImport(name: String, operation: ProjectOperation, urls: [URL]) async {
        isPreparingImport = true
        defer { isPreparingImport = false }

        let videos = await importer.sortedByRecording(importer.probeVideos(urls))
        guard !videos.isEmpty else { return }
        if videos.count == 1 {
            await createProject(name: name, from: videos.map(\.url), operation: operation)
        } else {
            pendingImport = PendingImport(name: name, operation: operation, videos: videos, tempURLs: [])
        }
    }

    /// Gallery variant: the probed urls are temp files that must stay alive
    /// until the user confirms or cancels the reorder sheet.
    func prepareImport(name: String, operation: ProjectOperation, photosItems: [PhotosPickerItem]) async {
        isPreparingImport = true
        defer { isPreparingImport = false }

        let videos = await importer.sortedByRecording(importer.probeGalleryItems(photosItems))
        guard !videos.isEmpty else {
            errorMessage = "Não foi possível ler o vídeo selecionado."
            return
        }
        if videos.count == 1 {
            await createProject(name: name, from: videos.map(\.url), operation: operation)
            cleanupTempFiles(videos.map(\.url))
        } else {
            pendingImport = PendingImport(name: name, operation: operation, videos: videos, tempURLs: videos.map(\.url))
        }
    }

    func confirmPendingImport() async {
        guard let pending = pendingImport else { return }
        await createProject(name: pending.name, from: pending.videos.map(\.url), operation: pending.operation)
        cleanupTempFiles(pending.tempURLs)
        pendingImport = nil
    }

    func cancelPendingImport() {
        guard let pending = pendingImport else { return }
        cleanupTempFiles(pending.tempURLs)
        pendingImport = nil
    }

    private func cleanupTempFiles(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }
    
    func selectProject(_ summary: ProjectSummary) {
        selectedProjectOperation = nil
        Task {
            do {
                selectedProject = try await storage.loadProject(id: summary.id)
            } catch {
                errorMessage = "Erro ao abrir projeto: \(error.localizedDescription)"
            }
        }
    }
    
    func deleteProject(_ summary: ProjectSummary) async {
        do {
            try await storage.deleteProject(id: summary.id)
            await loadProjects()
        } catch {
            errorMessage = "Erro ao excluir: \(error.localizedDescription)"
        }
    }
    
    func duplicateProject(_ summary: ProjectSummary, newName: String) async {
        do {
            let original = try await storage.loadProject(id: summary.id)
            _ = try await storage.duplicateProject(original, newName: newName)
            await loadProjects()
        } catch {
            errorMessage = "Erro ao duplicar: \(error.localizedDescription)"
        }
    }
    
    func exportProjectFile(_ summary: ProjectSummary) async {
        do {
            let project = try await storage.loadProject(id: summary.id)
            let docs = FileManager.default.temporaryDirectory
            let safeName = project.name.replacingOccurrences(of: "/", with: "-")
            let url = docs.appendingPathComponent("\(safeName)_\(Int(Date().timeIntervalSince1970)).clipstudio")
            try await storage.exportProject(project, to: url)
            shareItem = ProjectShareItem(url: url)
        } catch {
            errorMessage = "Erro ao exportar: \(error.localizedDescription)"
        }
    }
    
    func importProject(from url: URL) async {
        do {
            _ = try await storage.importProject(from: url)
            await loadProjects()
        } catch {
            errorMessage = "Erro ao importar: \(error.localizedDescription)"
        }
    }
}