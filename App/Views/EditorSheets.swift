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

    @Environment(\.dismiss) private var dismiss
    @State private var overlay: TextOverlay
    @State private var color: Color

    init(request: TextEditRequest, episodeDuration: Double, onSave: @escaping (TextOverlay) -> Void, onDelete: @escaping () -> Void) {
        self.isNew = request.isNew
        self.episodeDuration = max(episodeDuration, 1)
        self.onSave = onSave
        self.onDelete = onDelete
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
                }

                Section("Estilo") {
                    Picker("Estilo", selection: $overlay.style) {
                        ForEach(TextOverlayStyle.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    ColorPicker("Cor", selection: $color, supportsOpacity: false)
                    Toggle("Negrito", isOn: $overlay.isBold)
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
    let selectedID: UUID?
    let onSelect: (UUID) -> Void
    let onMove: (UUID, Double, Double, Bool) -> Void

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                ForEach(overlays) { overlay in
                    TextOverlayLabel(overlay: overlay, canvasSize: size, isSelected: overlay.id == selectedID)
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

    var body: some View {
        let fontSize = max(6, CGFloat(overlay.fontScale) * canvasSize.height)
        Text(overlay.text)
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
    let onAdd: (MediaAsset, Bool, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showingImport = false
    @State private var allEpisodes = false
    @State private var atPlayhead = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Começar na posição do cursor", isOn: $atPlayhead)
                    Toggle("Adicionar em todos os episódios", isOn: $allEpisodes)
                }
                Section("Biblioteca de áudio") {
                    if assets.isEmpty {
                        Text("Nenhum áudio importado ainda.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(assets) { asset in
                        Button {
                            onAdd(asset, allEpisodes, atPlayhead)
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
    let assetDuration: Double
    let episodeDuration: Double
    let onSave: (AudioClip) -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var clip: AudioClip

    init(clip: AudioClip, assetDuration: Double, episodeDuration: Double, onSave: @escaping (AudioClip) -> Void, onDelete: @escaping () -> Void) {
        self._clip = State(initialValue: clip)
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
                Section("Posição na linha do tempo") {
                    HStack {
                        Text("Início")
                        Slider(value: $clip.timelineStart, in: 0...max(episodeDuration - 0.1, 0.1))
                        Text(TimelineView.rulerLabel(clip.timelineStart)).monospacedDigit()
                    }
                }
                Section("Trecho do áudio") {
                    HStack {
                        Text("Início")
                        Slider(value: $clip.sourceStart, in: 0...max(assetDuration - 0.1, 0.1))
                        Text(TimelineView.rulerLabel(clip.sourceStart)).monospacedDigit()
                    }
                    .onChange(of: clip.sourceStart) { newValue in
                        clip.sourceEnd = max(clip.sourceEnd, min(newValue + 0.1, assetDuration))
                    }
                    HStack {
                        Text("Fim")
                        Slider(value: $clip.sourceEnd, in: min(clip.sourceStart + 0.1, assetDuration)...assetDuration)
                        Text(TimelineView.rulerLabel(clip.sourceEnd)).monospacedDigit()
                    }
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
