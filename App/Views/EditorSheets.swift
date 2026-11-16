import SwiftUI
import AVFoundation

// MARK: - Narration

@MainActor
struct NarrationRecorderSheet: View {
    let title: String
    let hint: String
    var onRecordingChanged: ((Bool) -> Void)?
    let onSave: (MediaAsset) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = NarrationRecorder()
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Text(TimelineView.rulerLabel(recorder.elapsed) + String(format: ".%01d", Int((recorder.elapsed * 10).truncatingRemainder(dividingBy: 10))))
                    .font(.system(size: 40, weight: .semibold).monospacedDigit())

                LevelMeter(level: recorder.level)
                    .frame(height: 10)
                    .padding(.horizontal, 40)

                HStack(spacing: 28) {
                    if recorder.recordedURL != nil && !recorder.isRecording {
                        Button {
                            recorder.togglePlayback()
                        } label: {
                            Image(systemName: recorder.isPlaying ? "stop.circle" : "play.circle")
                                .font(.system(size: 40))
                        }
                    }

                    Button {
                        if recorder.isRecording {
                            recorder.stop()
                            onRecordingChanged?(false)
                        } else {
                            Task {
                                await recorder.start()
                                if recorder.isRecording { onRecordingChanged?(true) }
                            }
                        }
                    } label: {
                        ZStack {
                            Circle().stroke(Color.red, lineWidth: 4).frame(width: 74, height: 74)
                            if recorder.isRecording {
                                RoundedRectangle(cornerRadius: 6).fill(Color.red).frame(width: 30, height: 30)
                            } else {
                                Circle().fill(Color.red).frame(width: 60, height: 60)
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    if recorder.recordedURL != nil && !recorder.isRecording {
                        Button(role: .destructive) {
                            recorder.discard()
                        } label: {
                            Image(systemName: "trash.circle")
                                .font(.system(size: 40))
                        }
                    }
                }

                Text(recorder.isRecording ? "Gravando… toque para parar" : (recorder.recordedURL == nil ? "Toque para gravar" : "Toque para gravar de novo"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let error = recorder.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") {
                        if recorder.isRecording {
                            recorder.stop()
                            onRecordingChanged?(false)
                        }
                        recorder.discard()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Usar") { save() }
                        .disabled(recorder.recordedURL == nil || recorder.isRecording || isSaving)
                }
            }
            .interactiveDismissDisabled(recorder.isRecording)
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        guard let url = recorder.recordedURL else { return }
        isSaving = true
        Task {
            do {
                var asset = try await VideoImporter.shared.importMediaAsset(from: url, type: .audio)
                let formatter = DateFormatter()
                formatter.dateFormat = "dd/MM HH:mm"
                asset.name = "Narração \(formatter.string(from: Date()))"
                recorder.discard()
                onSave(asset)
                dismiss()
            } catch {
                recorder.errorMessage = "Erro ao salvar narração: \(error.localizedDescription)"
            }
            isSaving = false
        }
    }
}

private struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25))
                Capsule()
                    .fill(LinearGradient(colors: [.green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geometry.size.width * CGFloat(level))
                    .animation(.linear(duration: 0.05), value: level)
            }
        }
    }
}

// MARK: - Text

struct TextEditRequest: Identifiable {
    let id = UUID()
    var overlay: TextOverlay
    let isNew: Bool
}

struct TextOverlayEditorSheet: View {
    let isNew: Bool
    let episodeDuration: Double
    let onSave: (TextOverlay) -> Void
    let onDelete: () -> Void
    var templates: [TextStyleTemplate] = []
    var onSaveTemplate: ((String, TextStyleTemplate) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var overlay: TextOverlay
    @State private var color: Color
    @State private var templateName = ""
    @FocusState private var isTextFocused: Bool

    init(request: TextEditRequest, episodeDuration: Double, onSave: @escaping (TextOverlay) -> Void, onDelete: @escaping () -> Void,
         templates: [TextStyleTemplate] = [], onSaveTemplate: ((String, TextStyleTemplate) -> Void)? = nil) {
        self.isNew = request.isNew
        self.episodeDuration = max(episodeDuration, 1)
        self.onSave = onSave
        self.onDelete = onDelete
        self.templates = templates
        self.onSaveTemplate = onSaveTemplate
        self._overlay = State(initialValue: request.overlay)
        self._color = State(initialValue: request.overlay.color.color)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Digite o texto", text: $overlay.text, axis: .vertical)
                        .lineLimit(1...4)
                        .font(.title3)
                        .focused($isTextFocused)
                        .onAppear {
                            guard isNew else { return }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { isTextFocused = true }
                        }
                }

                if !templates.isEmpty || onSaveTemplate != nil {
                    Section("Modelo de identidade") {
                        if !templates.isEmpty {
                            Picker("Aplicar modelo", selection: templatePicker) {
                                Text("Nenhum").tag(UUID?.none)
                                ForEach(templates) { Text($0.name).tag(UUID?.some($0.id)) }
                            }
                        }
                        if onSaveTemplate != nil {
                            HStack {
                                TextField("Nome do modelo", text: $templateName)
                                Button("Salvar") {
                                    let name = templateName.trimmingCharacters(in: .whitespacesAndNewlines)
                                    guard !name.isEmpty else { return }
                                    onSaveTemplate?(name, TextStyleTemplate(
                                        name: name,
                                        style: overlay.style,
                                        color: RGBAColor(color),
                                        isBold: overlay.isBold,
                                        fontScale: overlay.fontScale,
                                        positionX: overlay.positionX,
                                        positionY: overlay.positionY,
                                        animation: overlay.animation,
                                        exitAnimation: overlay.exitAnimation
                                    ))
                                    templateName = ""
                                }
                                .disabled(templateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                    }
                }

                Section("Estilo") {
                    Picker("Estilo", selection: $overlay.style) {
                        ForEach(TextOverlayStyle.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    ColorPicker("Cor", selection: $color, supportsOpacity: false)
                    Toggle("Negrito", isOn: $overlay.isBold)
                    Picker("Animação", selection: entranceAnimation) {
                        ForEach(TextAnimationStyle.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Saída", selection: exitAnimation) {
                        ForEach(TextAnimationStyle.allCases) { Text($0.rawValue).tag($0) }
                    }
                    HStack {
                        Text("Tamanho")
                        Slider(value: $overlay.fontScale, in: 0.03...0.16)
                    }
                }

                Section {
                    HStack(spacing: 10) {
                        positionButton("Topo", y: 0.15)
                        positionButton("Centro", y: 0.5)
                        positionButton("Base", y: 0.82)
                    }
                    .buttonStyle(.bordered)
                } header: {
                    Text("Posição")
                } footer: {
                    Text("Você também pode arrastar o texto direto na prévia.")
                }

                Section {
                    Picker("Repetir em", selection: $overlay.anchor) {
                        Text("Só este episódio").tag(ClipAnchor?.none)
                        ForEach(ClipAnchor.allCases) { Text($0.rawValue).tag(ClipAnchor?.some($0)) }
                    }
                } footer: {
                    Text("Títulos repetidos aparecem na mesma posição relativa em todos os episódios (ou em todas as aberturas/encerramentos).")
                }

                Section("Tempo") {
                    HStack {
                        Text("Início")
                        Slider(value: $overlay.startTime, in: 0...max(episodeDuration - 0.5, 0.1))
                        Text(TimelineView.rulerLabel(overlay.startTime)).monospacedDigit()
                    }
                    HStack {
                        Text("Duração")
                        Slider(value: $overlay.duration, in: 0.5...max(episodeDuration - overlay.startTime, 0.6))
                        Text(String(format: "%.1fs", overlay.duration)).monospacedDigit()
                    }
                }

                if !isNew {
                    Section {
                        Button("Excluir texto", role: .destructive) {
                            onDelete()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "Adicionar texto" : "Editar texto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Adicionar" : "Salvar") {
                        var result = overlay
                        result.color = RGBAColor(color)
                        result.duration = min(result.duration, max(episodeDuration - result.startTime, 0.5))
                        onSave(result)
                        dismiss()
                    }
                    .disabled(overlay.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // `$overlay.animation` would resolve to `Binding.animation(_:)`, so build these explicitly.
    private var entranceAnimation: Binding<TextAnimationStyle> {
        Binding(
            get: { overlay.animation ?? TextAnimationStyle.none },
            set: { overlay.animation = $0 == TextAnimationStyle.none ? nil : $0 }
        )
    }

    private var exitAnimation: Binding<TextAnimationStyle> {
        Binding(
            get: { overlay.exitAnimation ?? TextAnimationStyle.none },
            set: { overlay.exitAnimation = $0 == TextAnimationStyle.none ? nil : $0 }
        )
    }

    private var templatePicker: Binding<UUID?> {
        Binding<UUID?>(
            get: { nil },
            set: { id in
                guard let template = templates.first(where: { $0.id == id }) else { return }
                overlay.style = template.style
                overlay.isBold = template.isBold
                overlay.fontScale = template.fontScale
                overlay.positionX = template.positionX
                overlay.positionY = template.positionY
                overlay.animation = template.animation
                overlay.exitAnimation = template.exitAnimation
                color = template.color.color
            }
        )
    }

    private func positionButton(_ title: String, y: Double) -> some View {
        Button(title) {
            overlay.positionX = 0.5
            overlay.positionY = y
        }
        .frame(maxWidth: .infinity)
    }
}

/// Draws text overlays over the preview with the same geometry used for export.
struct TextOverlayLayer: View {
    let overlays: [TextOverlay]
    var currentTime: Double = 0
    let selectedID: UUID?
    let onSelect: (UUID) -> Void
    let onMove: (UUID, Double, Double, Bool) -> Void

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                ForEach(overlays) { overlay in
                    TextOverlayLabel(overlay: overlay, canvasSize: size, isSelected: overlay.id == selectedID, time: currentTime)
                        .position(x: overlay.positionX * size.width, y: overlay.positionY * size.height)
                        .onTapGesture { onSelect(overlay.id) }
                        .gesture(
                            DragGesture(coordinateSpace: .named("textCanvas"))
                                .onChanged { value in
                                    onMove(overlay.id, clamp(value.location.x / size.width), clamp(value.location.y / size.height), false)
                                }
                                .onEnded { value in
                                    onMove(overlay.id, clamp(value.location.x / size.width), clamp(value.location.y / size.height), true)
                                }
                        )
                }
            }
            .frame(width: size.width, height: size.height)
            .coordinateSpace(name: "textCanvas")
        }
    }

    private func clamp(_ value: CGFloat) -> Double {
        Double(min(0.98, max(0.02, value)))
    }
}

struct TextOverlayLabel: View {
    let overlay: TextOverlay
    let canvasSize: CGSize
    let isSelected: Bool
    var time: Double = 0

    private var label: Text {
        guard let words = overlay.highlightWords else {
            if overlay.animation == .typewriter, entranceProgress < 1 {
                let count = Int(Double(overlay.text.count) * entranceProgress)
                return Text(String(overlay.text.prefix(count)))
            }
            return Text(overlay.text)
        }
        let local = time - overlay.startTime
        return words.enumerated().reduce(Text("")) { result, entry in
            let spoken = local >= entry.element.start && local < entry.element.end
            let word = Text((entry.offset == 0 ? "" : " ") + entry.element.text)
            return result + (spoken ? word.foregroundColor(TextOverlay.highlightColor) : word)
        }
    }

    private var entranceProgress: Double {
        guard let style = overlay.animation, style != .none else { return 1 }
        return min(max((time - overlay.startTime) / 0.4, 0), 1)
    }

    private var exitProgress: Double {
        guard let style = overlay.exitAnimation, style != .none else { return 1 }
        return min(max((overlay.endTime - time) / 0.35, 0), 1)
    }

    var body: some View {
        let fontSize = max(6, CGFloat(overlay.fontScale) * canvasSize.height)
        let progress = entranceProgress * exitProgress
        label
            .font(.system(size: fontSize, weight: overlay.isBold ? .bold : .regular))
            .foregroundStyle(overlay.color.color)
            .multilineTextAlignment(.center)
            .shadow(color: overlay.style == .shadow ? .black.opacity(0.85) : .clear, radius: fontSize * 0.08)
            .padding(overlay.style == .box ? fontSize * 0.35 : 0)
            .background(
                overlay.style == .box ? Color.black.opacity(0.6) : Color.clear,
                in: RoundedRectangle(cornerRadius: fontSize * 0.25)
            )
            .frame(maxWidth: canvasSize.width * 0.9)
            .fixedSize(horizontal: false, vertical: true)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .padding(-4)
                    .opacity(isSelected ? 1 : 0)
            )
            .opacity(progress)
            .scaleEffect(overlay.animation == .pop ? 0.2 + 0.8 * entranceProgress : 1)
            .offset(y: overlay.animation == .slide
                   ? (1 - entranceProgress) * canvasSize.height * 0.15
                   : (overlay.animation == .bounce ? -(1 - entranceProgress) * canvasSize.height * 0.25 : 0))
    }
}

// MARK: - Transitions

struct TransitionPickerSheet: View {
    let segment: TimelineSegment
    let onApply: (TransitionStyle, Double, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var style: TransitionStyle
    @State private var duration: Double
    @State private var applyToAll = false

    init(segment: TimelineSegment, onApply: @escaping (TransitionStyle, Double, Bool) -> Void) {
        self.segment = segment
        self.onApply = onApply
        self._style = State(initialValue: segment.transition)
        self._duration = State(initialValue: segment.transitionDuration)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 10) {
                        ForEach(TransitionStyle.allCases) { item in
                            Button {
                                style = item
                            } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: item.icon)
                                        .font(.system(size: 22))
                                    Text(item.rawValue)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                }
                                .frame(maxWidth: .infinity, minHeight: 64)
                                .background(
                                    item == style ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 10)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(item == style ? Color.accentColor : .clear, lineWidth: 2)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Transição de entrada")
                } footer: {
                    Text("Aplicada entre o clipe anterior e “\(segment.trackType.rawValue)”.")
                }

                if style != .none {
                    Section("Duração") {
                        HStack {
                            Slider(value: $duration, in: 0.2...2.0, step: 0.1)
                            Text(String(format: "%.1fs", duration)).monospacedDigit()
                        }
                    }
                }

                Section {
                    Toggle("Aplicar a todos os clipes do episódio", isOn: $applyToAll)
                }
            }
            .navigationTitle("Transição")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Aplicar") {
                        onApply(style, duration, applyToAll)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Audio

struct AddAudioSheet: View {
    let assets: [MediaAsset]
    let onImportAsset: (MediaAsset) -> Void
    let onAdd: (MediaAsset, ClipAnchor?, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showingImport = false
    @State private var anchor: ClipAnchor?
    @State private var atPlayhead = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Começar na posição do cursor", isOn: $atPlayhead)
                    Picker("Repetir em", selection: $anchor) {
                        Text("Só este episódio").tag(ClipAnchor?.none)
                        ForEach(ClipAnchor.allCases) { Text($0.rawValue).tag(ClipAnchor?.some($0)) }
                    }
                }
                Section("Biblioteca de áudio") {
                    if assets.isEmpty {
                        Text("Nenhum áudio importado ainda.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(assets) { asset in
                        Button {
                            onAdd(asset, anchor, atPlayhead)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: asset.name.hasPrefix("Narração") ? "mic.fill" : "music.note")
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 28)
                                VStack(alignment: .leading) {
                                    Text(asset.name).lineLimit(1)
                                    Text(TimelineView.rulerLabel(asset.duration))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "plus.circle.fill")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Adicionar áudio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fechar") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingImport = true
                    } label: {
                        Label("Importar", systemImage: "square.and.arrow.down")
                    }
                }
            }
            .sheet(isPresented: $showingImport) {
                AssetImportSheet(initialType: .audio) { asset in onImportAsset(asset) }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct AudioClipEditorSheet: View {
    let assetURL: URL?
    let assetDuration: Double
    let episodeDuration: Double
    let onSave: (AudioClip) -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var clip: AudioClip

    init(clip: AudioClip, assetURL: URL?, assetDuration: Double, episodeDuration: Double, onSave: @escaping (AudioClip) -> Void, onDelete: @escaping () -> Void) {
        self._clip = State(initialValue: clip)
        self.assetURL = assetURL
        self.assetDuration = max(assetDuration, clip.sourceEnd, 0.2)
        self.episodeDuration = max(episodeDuration, 0.2)
        self.onSave = onSave
        self.onDelete = onDelete
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(clip.name) {
                    Picker("Tipo", selection: $clip.kind) {
                        ForEach(AudioClipKind.allCases) { Label($0.rawValue, systemImage: $0.icon).tag($0) }
                    }
                    HStack {
                        Image(systemName: "speaker.fill")
                        Slider(value: $clip.volume, in: 0...1)
                        Text("\(Int(clip.volume * 100))%").monospacedDigit().frame(width: 48)
                    }
                }
                Section {
                    Picker("Repetir em", selection: $clip.anchor) {
                        Text("Só este episódio").tag(ClipAnchor?.none)
                        ForEach(ClipAnchor.allCases) { Text($0.rawValue).tag(ClipAnchor?.some($0)) }
                    }
                }
                Section("Posição na linha do tempo") {
                    HStack {
                        Text("Início")
                        Slider(value: $clip.timelineStart, in: 0...max(episodeDuration - 0.1, 0.1))
                        Text(TimelineView.rulerLabel(clip.timelineStart)).monospacedDigit()
                    }
                }
                Section("Trecho do áudio") {
                    TrimRangeView(
                        url: assetURL,
                        duration: assetDuration,
                        start: $clip.sourceStart,
                        end: $clip.sourceEnd,
                        isAudio: true,
                        tint: .green
                    )
                    .padding(.vertical, 4)
                }
                Section {
                    Button {
                        Task {
                            if let normalized = await WaveformProvider.shared.normalizedGain(for: assetURL) {
                                clip.volume = normalized
                            }
                        }
                    } label: {
                        Label("Normalizar volume", systemImage: "waveform.badge.magnifyingglass")
                    }
                    .disabled(assetURL == nil)
                }
                Section("Fade") {
                    HStack {
                        Text("Entrada")
                        Slider(value: $clip.fadeIn, in: 0...5, step: 0.5)
                        Text(String(format: "%.1fs", clip.fadeIn)).monospacedDigit()
                    }
                    HStack {
                        Text("Saída")
                        Slider(value: $clip.fadeOut, in: 0...5, step: 0.5)
                        Text(String(format: "%.1fs", clip.fadeOut)).monospacedDigit()
                    }
                }
                Section {
                    Button("Remover áudio", role: .destructive) {
                        onDelete()
                        dismiss()
                    }
                }
            }
            .navigationTitle("Editar áudio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") {
                        onSave(clip)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Picture-in-picture

struct AddOverlaySheet: View {
    let assets: [MediaAsset]
    let onImportAsset: (MediaAsset) -> Void
    let onAdd: (MediaAsset) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showingImport = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if assets.isEmpty {
                        Text("Importe uma imagem ou vídeo para sobrepor.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(assets) { asset in
                        Button {
                            onAdd(asset)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Color.black
                                    if let url = asset.thumbnailFileURL, let image = UIImage(contentsOfFile: url.path) {
                                        Image(uiImage: image).resizable().scaledToFill()
                                    }
                                }
                                .frame(width: 64, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                VStack(alignment: .leading) {
                                    Text(asset.name).lineLimit(1)
                                    Text(asset.type == .video ? "Vídeo · \(TimelineView.rulerLabel(asset.duration))" : "Imagem")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "plus.circle.fill")
                            }
                        }
                    }
                } footer: {
                    Text("A sobreposição começa na posição do cursor. Depois arraste na prévia para posicionar.")
                }
            }
            .navigationTitle("Sobrepor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fechar") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingImport = true
                    } label: {
                        Label("Importar", systemImage: "square.and.arrow.down")
                    }
                }
            }
            .sheet(isPresented: $showingImport) {
                AssetImportSheet(initialType: .image) { asset in onImportAsset(asset) }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct MediaOverlayEditorSheet: View {
    let episodeDuration: Double
    let assetDuration: Double
    let onSave: (MediaOverlay) -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var overlay: MediaOverlay
    @State private var chromaColor: Color

    init(overlay: MediaOverlay, episodeDuration: Double, assetDuration: Double, onSave: @escaping (MediaOverlay) -> Void, onDelete: @escaping () -> Void) {
        self._overlay = State(initialValue: overlay)
        self._chromaColor = State(initialValue: overlay.chromaKey?.color.color ?? .green)
        self.episodeDuration = max(episodeDuration, 1)
        self.assetDuration = max(assetDuration, 0.5)
        self.onSave = onSave
        self.onDelete = onDelete
    }

    private var maxDuration: Double {
        let remaining = max(episodeDuration - overlay.startTime, 0.6)
        return overlay.isVideo ? min(remaining, max(assetDuration - overlay.sourceStart, 0.6)) : remaining
    }

    private var chromaEnabled: Binding<Bool> {
        Binding(
            get: { overlay.chromaKey?.enabled == true },
            set: { overlay.chromaKey = $0 ? (overlay.chromaKey ?? ChromaKeySettings(enabled: true)) : nil
                if $0 { overlay.chromaKey?.enabled = true; overlay.chromaKey?.color = RGBAColor(chromaColor) } }
        )
    }

    private var chromaTolerance: Binding<Double> {
        Binding(
            get: { overlay.chromaKey?.tolerance ?? 0.4 },
            set: { overlay.chromaKey?.tolerance = $0 }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(overlay.name) {
                    HStack {
                        Text("Tamanho")
                        Slider(value: $overlay.widthFraction, in: 0.1...1)
                        Text("\(Int(overlay.widthFraction * 100))%").monospacedDigit().frame(width: 48)
                    }
                    HStack {
                        Text("Opacidade")
                        Slider(value: $overlay.opacity, in: 0.05...1)
                        Text("\(Int(overlay.opacity * 100))%").monospacedDigit().frame(width: 48)
                    }
                    HStack {
                        Text("Rotação")
                        Slider(value: $overlay.rotation, in: -180...180, step: 1)
                        Text("\(Int(overlay.rotation))°").monospacedDigit().frame(width: 48)
                    }
                    if overlay.isVideo {
                        HStack {
                            Image(systemName: overlay.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            Slider(value: $overlay.volume, in: 0...1)
                            Text("\(Int(overlay.volume * 100))%").monospacedDigit().frame(width: 48)
                        }
                    }
                }
                if overlay.isVideo {
                    Section {
                        Toggle("Chroma key", isOn: chromaEnabled)
                        if overlay.chromaKey?.enabled == true {
                            ColorPicker("Cor de fundo", selection: $chromaColor, supportsOpacity: false)
                                .onChange(of: chromaColor) { overlay.chromaKey?.color = RGBAColor($0) }
                            HStack {
                                Text("Tolerância")
                                Slider(value: chromaTolerance, in: 0.05...0.8)
                            }
                        }
                    } footer: {
                        Text("Remove o fundo de uma cor (ex.: tela verde) da sobreposição de vídeo.")
                    }
                }
                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                        positionButton("↖︎", x: 0.25, y: 0.22)
                        positionButton("↑", x: 0.5, y: 0.22)
                        positionButton("↗︎", x: 0.75, y: 0.22)
                        positionButton("←", x: 0.25, y: 0.5)
                        positionButton("•", x: 0.5, y: 0.5)
                        positionButton("→", x: 0.75, y: 0.5)
                        positionButton("↙︎", x: 0.25, y: 0.78)
                        positionButton("↓", x: 0.5, y: 0.78)
                        positionButton("↘︎", x: 0.75, y: 0.78)
                    }
                    .buttonStyle(.bordered)
                } header: {
                    Text("Posição")
                } footer: {
                    Text("Você também pode arrastar direto na prévia.")
                }
                Section("Tempo") {
                    HStack {
                        Text("Início")
                        Slider(value: $overlay.startTime, in: 0...max(episodeDuration - 0.3, 0.1))
                        Text(TimelineView.rulerLabel(overlay.startTime)).monospacedDigit()
                    }
                    HStack {
                        Text("Duração")
                        Slider(value: $overlay.duration, in: 0.3...max(maxDuration, 0.4))
                        Text(String(format: "%.1fs", overlay.duration)).monospacedDigit()
                    }
                }
                Section {
                    Button("Remover sobreposição", role: .destructive) {
                        onDelete()
                        dismiss()
                    }
                }
            }
            .navigationTitle("Sobreposição")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") {
                        var result = overlay
                        result.duration = min(result.duration, maxDuration)
                        onSave(result)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func positionButton(_ title: String, x: Double, y: Double) -> some View {
        Button(title) {
            overlay.centerX = x
            overlay.centerY = y
        }
        .frame(maxWidth: .infinity)
    }
}

/// Image overlays are drawn here during preview; video overlays are rendered by the composition,
/// so only their selection frame is drawn.
struct MediaOverlayLayer: View {
    let overlays: [MediaOverlay]
    let selectedID: UUID?
    let imageURL: (MediaOverlay) -> URL?
    let aspect: (MediaOverlay) -> CGFloat
    let onSelect: (UUID) -> Void
    let onMove: (UUID, Double, Double, Bool) -> Void

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                ForEach(overlays) { overlay in
                    let width = CGFloat(overlay.widthFraction) * size.width
                    let height = width / max(aspect(overlay), 0.1)
                    ZStack {
                        if !overlay.isVideo, let url = imageURL(overlay), let image = UIImage(contentsOfFile: url.path) {
                            Image(uiImage: image).resizable().scaledToFit()
                        } else {
                            Color.white.opacity(0.001)
                        }
                    }
                    .frame(width: width, height: height)
                    .opacity(overlay.opacity)
                    .rotationEffect(.degrees(overlay.rotation))
                    .overlay(
                        Rectangle()
                            .stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                            .opacity(overlay.id == selectedID ? 1 : 0)
                    )
                    .position(x: overlay.centerX * size.width, y: overlay.centerY * size.height)
                    .onTapGesture { onSelect(overlay.id) }
                    .gesture(
                        DragGesture(coordinateSpace: .named("mediaCanvas"))
                            .onChanged { value in
                                onMove(overlay.id, clamp(value.location.x / size.width), clamp(value.location.y / size.height), false)
                            }
                            .onEnded { value in
                                onMove(overlay.id, clamp(value.location.x / size.width), clamp(value.location.y / size.height), true)
                            }
                    )
                }
            }
            .frame(width: size.width, height: size.height)
            .coordinateSpace(name: "mediaCanvas")
        }
    }

    private func clamp(_ value: CGFloat) -> Double {
        Double(min(0.98, max(0.02, value)))
    }
}


// MARK: - Clip framing

struct ClipTransformSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var transform: ClipTransform
    @State private var adjustments: ClipAdjustments
    let onChange: (ClipTransform, ClipAdjustments) -> Void

    init(transform: ClipTransform, adjustments: ClipAdjustments, onChange: @escaping (ClipTransform, ClipAdjustments) -> Void) {
        _transform = State(initialValue: transform)
        _adjustments = State(initialValue: adjustments)
        self.onChange = onChange
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Enquadramento") {
                    row("Zoom", value: $transform.scale, range: 0.3...4, label: String(format: "%.2f×", transform.scale))
                    row("Rotação", value: $transform.rotation, range: -180...180, step: 1, label: "\(Int(transform.rotation))°")
                    row("Horizontal", value: $transform.offsetX, range: -1...1, label: "\(Int(transform.offsetX * 100))%")
                    row("Vertical", value: $transform.offsetY, range: -1...1, label: "\(Int(transform.offsetY * 100))%")
                }
                Section("Cor e luz") {
                    row("Brilho", value: $adjustments.brightness, range: -1...1, label: "\(Int(adjustments.brightness * 100))%")
                    row("Contraste", value: $adjustments.contrast, range: 0.25...2, label: String(format: "%.2f", adjustments.contrast))
                    row("Saturação", value: $adjustments.saturation, range: 0...2, label: String(format: "%.2f", adjustments.saturation))
                    row("Temperatura", value: $adjustments.warmth, range: -1...1, label: "\(Int(adjustments.warmth * 100))%")
                    row("Vinheta", value: $adjustments.vignette, range: 0...1, label: "\(Int(adjustments.vignette * 100))%")
                }
                Section {
                    HStack {
                        Button("Girar 90°") { transform.rotation = (transform.rotation + 90).truncatingRemainder(dividingBy: 360) }
                        Spacer()
                        Button("Redefinir", role: .destructive) { transform = .identity; adjustments = .identity }
                    }
                }
            }
            .navigationTitle("Ajustar clipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") {
                        onChange(transform, adjustments)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double = 0.01, label: String) -> some View {
        HStack {
            Text(title).frame(width: 90, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text(label).monospacedDigit().frame(width: 56, alignment: .trailing)
        }
    }
}
