import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "Editar com IA": export a .clipbrief for an external AI, import the .clipplan
/// it returns, review it and apply. Everything stays on device except the JSON.
struct AIEditSection: View {
    let project: Project
    let analysis: ContentAnalysis?
    /// Assets imported inside the automation sheet (not yet in `project`).
    let importedAssets: [MediaAsset]
    let isAnalyzing: Bool
    let onAnalyze: () -> Void
    let onApplyPlan: (ClipPlan, ClipBrief?) -> Void

    @State private var scope: ClipBriefScope = .outputs
    @State private var includeTranscript = true
    @State private var includeVocabulary = true
    @State private var shareItem: AIEditShareItem?
    @State private var statusMessage: String?
    @State private var planText = ""
    @State private var showingPlanImporter = false
    @State private var review: AIPlanReview?
    @State private var lastBrief: ClipBrief?
    // Card 3: envio direto para a IA
    @State private var providerSettings = AISettingsStore.load()
    @State private var apiKeyDraft = ""
    @State private var hasAPIKey = false
    @State private var showingAPISettings = false
    @State private var requestText = ""
    @State private var isSendingToAI = false
    @State private var sendNotice: String?
    @State private var sendError: String?
    @State private var lastPlanJSON: String?
    @State private var sendTask: Task<Void, Never>?

    init(
        project: Project,
        analysis: ContentAnalysis?,
        importedAssets: [MediaAsset] = [],
        isAnalyzing: Bool = false,
        onAnalyze: @escaping () -> Void = {},
        onApplyPlan: @escaping (ClipPlan, ClipBrief?) -> Void
    ) {
        self.project = project
        self.analysis = analysis
        self.importedAssets = importedAssets
        self.isAnalyzing = isAnalyzing
        self.onAnalyze = onAnalyze
        self.onApplyPlan = onApplyPlan
    }

    var body: some View {
        VStack(spacing: 16) {
            briefCard
            importCard
            sendCard
            if let plan = currentValidPlan, let outputs = plan.outputs {
                applyCard(outputCount: outputs.count, plan: plan)
            } else if let plan = currentValidPlan, let operations = plan.operations {
                operationsApplyCard(operationCount: operations.count, plan: plan)
            }
        }
        .fileImporter(
            isPresented: $showingPlanImporter,
            allowedContentTypes: planImportTypes,
            allowsMultipleSelection: false
        ) { result in
            importPlan(result)
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: item.urls)
        }
        .onAppear {
            providerSettings = AISettingsStore.load()
            apiKeyDraft = AISettingsStore.loadAPIKey() ?? ""
            hasAPIKey = AISettingsStore.loadAPIKey() != nil
        }
    }

    // MARK: - Card 1: brief

    private var briefCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("1 · Gerar pacote para a IA", systemImage: "shippingbox")
                .font(.headline)
            Text("O .clipbrief resume o vídeo (fala, cortes, pausas e assets) para o ChatGPT/Copilot criar o plano de edição.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                scopeButton(title: "Criar saídas", value: .outputs, enabled: true)
                scopeButton(title: "Editar episódios existentes", value: .editExisting, enabled: !project.episodes.isEmpty)
            }
            if project.episodes.isEmpty {
                Text("Crie saídas/episódios primeiro para liberar a edição interativa.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Incluir transcrição", isOn: $includeTranscript)
                Text("Sem a fala, a IA só vê tempos e cortes.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !(project.transcriptionVocabulary ?? []).isEmpty {
                Toggle("Incluir vocabulário do projeto", isOn: $includeVocabulary)
            }

            HStack(spacing: 10) {
                Button {
                    copyBrief()
                } label: {
                    Label("Copiar instruções + pacote", systemImage: "doc.on.doc")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button {
                    shareBrief()
                } label: {
                    Label("Compartilhar .clipbrief", systemImage: "square.and.arrow.up")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 6) {
                Text(briefStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !summary.hasSpeech && !isAnalyzing {
                    Button("Analisar") { onAnalyze() }
                        .font(.caption.weight(.semibold))
                }
            }
            if let statusMessage = statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func scopeButton(title: String, value: ClipBriefScope, enabled: Bool) -> some View {
        Button {
            scope = value
        } label: {
            Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(
                    scope == value ? Color.accentColor.opacity(0.2) : Color(uiColor: .tertiarySystemGroupedBackground),
                    in: Capsule()
                )
                .foregroundStyle(scope == value ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    // MARK: - Card 2: plan import + review

    private var importCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("2 · Importar plano", systemImage: "doc.badge.arrow.down")
                .font(.headline)
            Text("Cole ou importe o .clipplan que a IA devolveu. O app confere tudo antes de aplicar.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $planText)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 110)
                .padding(6)
                .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    if planText.isEmpty {
                        Text("Cole aqui o JSON do .clipplan…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding()
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .allowsHitTesting(false)
                    }
                }

            HStack(spacing: 10) {
                Button("Revisar plano") { reviewPlan() }
                    .buttonStyle(.borderedProminent)
                    .disabled(planText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Importar arquivo") { showingPlanImporter = true }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Colar") {
                    if let pasted = UIPasteboard.general.string {
                        planText = pasted
                        reviewPlan()
                    }
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.small)

            if let review = review, review.text == planText {
                reviewContent(review)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func reviewContent(_ review: AIPlanReview) -> some View {
        if !review.errors.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(review.errors.prefix(8).enumerated()), id: \.offset) { _, error in
                    Text("• \(error)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if review.errors.count > 8 {
                    Text("…e mais \(review.errors.count - 8) problemas.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        } else if let plan = review.plan {
            if let outputs = plan.outputs {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Plano válido — \(outputs.count) saída(s)", systemImage: "checkmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.green)
                    ForEach(Array(outputs.enumerated()), id: \.offset) { index, output in
                        outputRow(output: output, index: index)
                    }
                }
            } else if let operations = plan.operations {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Plano de edição válido — \(operations.count) edições", systemImage: "checkmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.green)
                    ForEach(Array(operations.enumerated()), id: \.offset) { _, operation in
                        HStack(spacing: 8) {
                            Image(systemName: "slider.horizontal.3")
                                .foregroundStyle(.secondary)
                            Text("\(operation.op) · \(operation.target)")
                                .font(.caption.monospaced())
                            Spacer()
                        }
                    }
                }
            }
        }
    }

    private func outputRow(output: ClipPlanOutput, index: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: formatIcon(output.format))
                .frame(width: 22)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(output.title ?? output.id ?? "Saída \(index + 1)")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text("\(output.segments.count) trechos · \(output.format) · ~\(clock(outputDuration(output)))"
                    + (output.captions?.enabled == true ? " · legendas" : ""))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let reason = output.reason, !reason.isEmpty {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Card 3: send directly to the AI (optional)

    private var sendCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("3 · Enviar direto para a IA (opcional)", systemImage: "paperplane")
                .font(.headline)
            Text("O app monta o mesmo pacote do cartão 1 e envia ao provedor escolhido; a resposta já entra na revisão do cartão 2.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Provedor", selection: providerKindBinding) {
                ForEach(providerOptions, id: \.self) { option in
                    Text(providerTitle(option)).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isSendingToAI)

            providerDetail
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var providerDetail: some View {
        switch effectiveProvider {
        case .manual:
            Text("No modo Manual, copie o pacote no cartão 1 e cole a resposta no cartão 2.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .api:
            apiProviderContent
        case .appleIntelligence:
            appleIntelligenceContent
        }
    }

    private var apiProviderContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(apiSettingsSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button {
                    showingAPISettings.toggle()
                } label: {
                    Label("Configurar", systemImage: "gearshape")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isSendingToAI)
            }
            if showingAPISettings {
                apiSettingsForm
            }
            if !hasAPIKey {
                Text("Adicione sua chave de API nas configurações.")
                    .font(.caption)
                    .foregroundStyle(Color.orange)
            }
            requestEditor
            sendControls
            Text("Com a API, a análise do vídeo é enviada ao serviço escolhido. O vídeo continua no iPad.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var apiSettingsForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SecureField("Chave de API", text: $apiKeyDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote)
                    .onChange(of: apiKeyDraft) { newValue in
                        // The key goes straight to the Keychain on every
                        // change — never to UserDefaults, never to logs.
                        AISettingsStore.saveAPIKey(newValue)
                        hasAPIKey = AISettingsStore.loadAPIKey() != nil
                    }
                if hasAPIKey {
                    Text("Salva")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                    Button("Remover") {
                        AISettingsStore.removeAPIKey()
                        apiKeyDraft = ""
                        hasAPIKey = false
                    }
                    .font(.caption)
                }
            }
            Text("Endpoint")
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField("https://api.openai.com/v1", text: endpointBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .font(.footnote.monospaced())
            Text("Modelo")
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField("gpt-4o-mini", text: modelBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.footnote.monospaced())
            Text("Funciona com serviços compatíveis com a API do ChatGPT (OpenAI, OpenRouter, etc.). A chave fica só neste iPad.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
        .disabled(isSendingToAI)
    }

    private var appleIntelligenceContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AIPlanService.appleIntelligenceLabel)
                .font(.caption)
                .foregroundStyle(AIPlanService.appleIntelligenceReady ? Color.secondary : Color.orange)
            requestEditor
            sendControls
            Text("Funciona melhor com comandos diretos sobre os episódios (ex.: \"remova os silêncios do episódio 1\", \"renomeie o episódio 2\"). Para escolher trechos pela fala, use API ou Manual.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Ideal para pedidos curtos e vídeos pequenos; vídeos longos pedem API ou Manual.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("Com Apple Intelligence, a análise fica neste iPad.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var requestEditor: some View {
        TextEditor(text: $requestText)
            .font(.footnote)
            .frame(minHeight: 64)
            .padding(6)
            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                if requestText.isEmpty {
                    Text("Descreva a edição que você quer…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .allowsHitTesting(false)
                }
            }
            .disabled(isSendingToAI)
    }

    private var sendControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isSendingToAI {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Enviando para a IA…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancelar") { sendTask?.cancel() }
                        .font(.caption.weight(.semibold))
                }
            } else {
                Button {
                    sendToAI()
                } label: {
                    Label("Enviar", systemImage: "paperplane.fill")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSendToAI)
            }
            if let sendNotice = sendNotice {
                Text(sendNotice)
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if let sendError = sendError {
                Text(sendError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Card 4: apply

    private func applyCard(outputCount: Int, plan: ClipPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("4 · Aplicar", systemImage: "wand.and.stars")
                .font(.headline)
            Text("As saídas viram episódios novos e editáveis na timeline; nada do conteúdo atual muda.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                onApplyPlan(plan, lastBrief)
            } label: {
                Label("Aplicar e criar \(outputCount) vídeos", systemImage: "rectangle.stack.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    /// Apply card for `operations` plans: edits go straight into the existing
    /// episodes (a single undo reverts the whole plan).
    private func operationsApplyCard(operationCount: Int, plan: ClipPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("4 · Aplicar", systemImage: "wand.and.stars")
                .font(.headline)
            Text("As edições entram direto nos episódios existentes; dá para desfazer tudo de uma vez.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                onApplyPlan(plan, lastBrief)
            } label: {
                Label("Aplicar \(operationCount) edições", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Logic

    private var currentValidPlan: ClipPlan? {
        guard let review = review, review.errors.isEmpty, review.text == planText else { return nil }
        return review.plan
    }

    /// The project the brief describes: `project` plus assets imported inside
    /// this sheet (they are persisted via onImportAsset but `project` is the
    /// snapshot taken when the sheet opened).
    private var briefProject: Project {
        var merged = project
        for asset in importedAssets where !merged.mediaAssets.contains(where: { $0.id == asset.id }) {
            merged.mediaAssets.append(asset)
        }
        return merged
    }

    private var summary: (transcriptEnd: Double, scenes: Int, pauses: Int, hasSpeech: Bool) {
        let words = project.transcriptWords ?? analysis?.transcriptWords ?? []
        let scenes = (project.sceneCuts ?? analysis?.sceneCuts ?? []).count
        let pauses = ClipBriefBuilder.pauses(words: words, silences: analysis?.silenceRanges ?? []).count
        return (words.map(\.end).max() ?? 0, scenes, pauses, !words.isEmpty)
    }

    private var briefStatus: String {
        if summary.hasSpeech {
            return "Transcrição: \(clock(summary.transcriptEnd)) · \(summary.scenes) cenas · \(summary.pauses) pausas"
        }
        return isAnalyzing
            ? "Análise em andamento — o pacote sai enriquecido quando terminar."
            : "Analise o vídeo para enriquecer o pacote (fala, pausas e ganchos)."
    }

    private func makeBrief() -> ClipBrief {
        ClipBriefBuilder.build(
            project: briefProject,
            analysis: analysis,
            scope: scope,
            includeTranscript: includeTranscript,
            includeVocabulary: includeVocabulary
        )
    }

    // MARK: - Direct send (card 3)

    /// Providers shown in the picker: Manual + API always; Apple Intelligence
    /// only where the framework and OS support it.
    private var providerOptions: [AIProviderKind] {
        var options: [AIProviderKind] = [.manual, .api]
        if AIPlanService.appleIntelligenceSupported {
            options.append(.appleIntelligence)
        }
        return options
    }

    /// Stored kind healed to a shown option (e.g. appleIntelligence saved on a
    /// device where the option no longer exists).
    private var effectiveProvider: AIProviderKind {
        providerOptions.contains(providerSettings.kind) ? providerSettings.kind : .manual
    }

    private var providerKindBinding: Binding<AIProviderKind> {
        Binding(
            get: { effectiveProvider },
            set: { newKind in
                providerSettings.kind = newKind
                AISettingsStore.save(providerSettings)
            }
        )
    }

    private var endpointBinding: Binding<String> {
        Binding(
            get: { providerSettings.baseURL },
            set: { providerSettings.baseURL = $0; AISettingsStore.save(providerSettings) }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { providerSettings.model },
            set: { providerSettings.model = $0; AISettingsStore.save(providerSettings) }
        )
    }

    private func providerTitle(_ kind: AIProviderKind) -> String {
        switch kind {
        case .manual: return "Manual"
        case .api: return "API"
        case .appleIntelligence: return "Apple Intelligence"
        }
    }

    private var apiSettingsSummary: String {
        let host = URL(string: providerSettings.baseURL)?.host ?? providerSettings.baseURL
        let model = providerSettings.model.isEmpty ? AIProviderSettings.defaultModel : providerSettings.model
        return "\(model) · \(host)"
    }

    private var canSendToAI: Bool {
        if requestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        switch effectiveProvider {
        case .manual: return false
        case .api: return hasAPIKey
        case .appleIntelligence: return AIPlanService.appleIntelligenceReady
        }
    }

    /// Sends the SAME brief the manual flow would produce (same scope/privacy
    /// toggles, rebuilt now) and feeds the answer into the existing
    /// parse→validate→preview pipeline via `planText` + `reviewPlan()`.
    private func sendToAI() {
        let text = requestText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sendError = nil
        sendNotice = nil
        let brief = makeBrief()
        lastBrief = brief
        let settings = providerSettings
        let apiKey = AISettingsStore.loadAPIKey()
        let previousPlan = lastPlanJSON
        isSendingToAI = true
        sendTask = Task {
            do {
                let response = try await AIPlanService.requestPlan(
                    brief: brief,
                    requestText: text,
                    previousPlanJSON: previousPlan,
                    settings: settings,
                    apiKey: apiKey
                )
                await MainActor.run {
                    finishSend(response: response)
                }
            } catch is CancellationError {
                await MainActor.run {
                    isSendingToAI = false
                    sendTask = nil
                }
            } catch {
                await MainActor.run {
                    isSendingToAI = false
                    sendTask = nil
                    sendError = describeSendError(error)
                }
            }
        }
    }

    @MainActor
    private func finishSend(response: String) {
        isSendingToAI = false
        sendTask = nil
        lastPlanJSON = response
        planText = response
        reviewPlan()
        if let reviewed = review, reviewed.plan != nil {
            sendError = nil
            sendNotice = "Plano recebido — revise abaixo."
        } else {
            // Malformed answer: keep the raw text visible and show its start.
            sendNotice = nil
            sendError = "A resposta não é um plano válido: \(String(response.prefix(200)))"
        }
    }

    private func describeSendError(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    private func copyBrief() {
        let brief = makeBrief()
        lastBrief = brief
        let json = ClipBriefBuilder.encode(brief)
        UIPasteboard.general.string = ClipPromptGenerator.prompt(for: brief)
            + "\n\n--- INÍCIO DO ARQUIVO .clipbrief ---\n"
            + json
            + "\n--- FIM DO ARQUIVO .clipbrief ---\n"
        statusMessage = "Instruções e pacote copiados — cole no ChatGPT/Copilot."
    }

    private func shareBrief() {
        let brief = makeBrief()
        lastBrief = brief
        do {
            let directory = FileManager.default.temporaryDirectory
            let base = project.name.replacingOccurrences(of: "/", with: "-")
            let promptURL = directory.appendingPathComponent("\(base)_instrucoes.txt")
            let briefURL = directory.appendingPathComponent(ClipBriefBuilder.briefFileName(project: project))
            try ClipPromptGenerator.prompt(for: brief).write(to: promptURL, atomically: true, encoding: .utf8)
            try ClipBriefBuilder.encode(brief).write(to: briefURL, atomically: true, encoding: .utf8)
            shareItem = AIEditShareItem(urls: [promptURL, briefURL])
            statusMessage = nil
        } catch {
            statusMessage = "Falha ao preparar os arquivos: \(error.localizedDescription)"
        }
    }

    private func reviewPlan() {
        // Models sometimes answer with prose or a fenced block around the plan;
        // pull the first balanced JSON object out before decoding.
        let text = ClipPlanParser.extractJSON(from: planText)
            ?? planText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let data = text.data(using: .utf8) else {
            review = AIPlanReview(plan: nil, errors: ["JSON inválido: o texto está vazio."], text: planText)
            return
        }
        do {
            let plan = try JSONDecoder().decode(ClipPlan.self, from: data).normalized()
            let errors = ClipPlanValidator.validate(
                plan,
                context: ClipBriefBuilder.validationContext(project: briefProject, analysis: analysis)
            )
            review = AIPlanReview(plan: plan, errors: errors, text: planText)
        } catch {
            review = AIPlanReview(plan: nil, errors: ["JSON inválido: \(describeJSONError(error))"], text: planText)
        }
    }

    private func importPlan(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            guard let url = urls.first else { return }
            let accessGranted = url.startAccessingSecurityScopedResource()
            defer {
                if accessGranted { url.stopAccessingSecurityScopedResource() }
            }
            let text = try String(contentsOf: url, encoding: .utf8)
            planText = text
            reviewPlan()
        } catch {
            if (error as NSError).code != NSUserCancelledError {
                review = AIPlanReview(plan: nil, errors: ["Falha ao importar: \(error.localizedDescription)"], text: planText)
            }
        }
    }

    private var planImportTypes: [UTType] {
        var types: [UTType] = [.json, .plainText, .data]
        if let clipplan = UTType(filenameExtension: "clipplan") {
            types.append(clipplan)
        }
        return types
    }

    private func describeJSONError(_ error: Error) -> String {
        if case DecodingError.dataCorrupted(let context) = error { return context.debugDescription }
        if case DecodingError.keyNotFound(let key, let context) = error {
            return "campo \"\(key.stringValue)\" ausente (\(context.debugDescription))"
        }
        if case DecodingError.typeMismatch(_, let context) = error { return context.debugDescription }
        if case DecodingError.valueNotFound(_, let context) = error { return context.debugDescription }
        return error.localizedDescription
    }

    private func outputDuration(_ output: ClipPlanOutput) -> Double {
        ClipPlanExecutor.outputDuration(output, sequenceDuration: project.sequenceSourceDuration)
    }

    private func formatIcon(_ format: String) -> String {
        switch format {
        case "9:16": return "rectangle.portrait"
        case "16:9": return "rectangle"
        case "1:1": return "square"
        case "4:5": return "rectangle.portrait.inset.filled"
        default: return "film"
        }
    }

    private func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// Result of "Revisar plano"; `text` tracks what was reviewed so edits hide stale previews.
private struct AIPlanReview {
    var plan: ClipPlan?
    var errors: [String]
    var text: String
}

private struct AIEditShareItem: Identifiable {
    let id = UUID()
    let urls: [URL]
}
