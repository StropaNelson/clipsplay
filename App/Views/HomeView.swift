import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @StateObject private var viewModel = HomeViewModel()
    @State private var showingNewProject = false
    @State private var showingImport = false
    @State private var showingVideoImport = false
    @State private var projectToEdit: ProjectSummary?
    @State private var newProjectName = ""
    @State private var pendingProjectName: String?
    
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
                    showingVideoImport = true
                }
            }) {
                NewProjectSheet(onCreate: { name in
                    pendingProjectName = name
                    showingNewProject = false
                })
            }
            .fileImporter(
                isPresented: $showingVideoImport,
                allowedContentTypes: VideoImporter.supportedVideoTypes,
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first, let name = pendingProjectName else { return }
                    pendingProjectName = nil
                    Task { await viewModel.createProject(name: name, from: url) }
                case .failure(let error):
                    pendingProjectName = nil
                    if (error as NSError).code != NSUserCancelledError {
                        viewModel.errorMessage = "Erro ao selecionar vídeo: \(error.localizedDescription)"
                    }
                }
            }
            .fileImporter(
                isPresented: $showingImport,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                Task {
                    if case .success(let urls) = result, let url = urls.first {
                        await viewModel.importProject(from: url)
                    }
                }
            }
            .alert("Erro", isPresented: .constant(viewModel.errorMessage != nil)) {
                Button("OK") { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .fullScreenCover(item: $viewModel.selectedProject) { project in
                EditorView(project: project)
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

extension ProjectSummary {
    var thumbnailURL: URL? {
        // This would need to be stored in the project or generated
        nil
    }
}

struct NewProjectSheet: View {
    let onCreate: (String) -> Void
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Novo Projeto") {
                    TextField("Nome do projeto", text: $name)
                }
                
                Section {
                    Text("Após criar, você poderá importar um vídeo para começar a dividir em episódios.")
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
                    Button("Criar") { onCreate(name) }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.height(250)])
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
    @Published var projects: [ProjectSummary] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var selectedProject: Project?
    
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
    
    func createProject(name: String, from videoURL: URL) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        
        errorMessage = nil
        do {
            var project = try await importer.importVideo(from: videoURL, projectName: trimmed)
            project.regenerateEpisodes()
            try await storage.saveProject(project)
            await loadProjects()
            selectedProject = project
        } catch {
            errorMessage = "Erro ao criar projeto: \(error.localizedDescription)"
        }
    }
    
    func selectProject(_ summary: ProjectSummary) {
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
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let url = docs.appendingPathComponent("\(project.name)_\(Int(Date().timeIntervalSince1970)).clipstudio")
            try await storage.exportProject(project, to: url)
            // Share sheet would be presented here
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