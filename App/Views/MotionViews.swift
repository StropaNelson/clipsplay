import SwiftUI
import UIKit

struct MotionLayer: View {
    let elements: [MotionElement]
    let currentTime: Double
    let selectedID: UUID?
    let onSelect: (UUID) -> Void
    let onMove: (UUID, Double, Double, Bool) -> Void

    var body: some View {
        GeometryReader { geometry in
            let size: CGSize = geometry.size
            ZStack(alignment: .topLeading) {
                canvas
                ForEach(elements) { element in
                    hitArea(for: element, size: size)
                }
            }
            .frame(width: size.width, height: size.height)
            .coordinateSpace(name: "motionCanvas")
        }
    }

    private var canvas: some View {
        Canvas { context, canvasSize in
            context.withCGContext { cgContext in
                for element in elements {
                    MotionRenderer.draw(element, at: currentTime, canvasSize: canvasSize, in: cgContext)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func hitArea(for element: MotionElement, size: CGSize) -> some View {
        let rect: CGRect = MotionRenderer.frameRect(element, canvasSize: size)
        return Color.white.opacity(0.001)
            .frame(width: rect.width, height: rect.height)
            .overlay(
                Rectangle()
                    .stroke(
                        Color.white,
                        style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])
                    )
                    .opacity(element.id == selectedID ? 1 : 0)
                    .allowsHitTesting(false)
            )
            .position(x: rect.midX, y: rect.midY)
            .onTapGesture { onSelect(element.id) }
            .gesture(dragGesture(for: element.id, size: size))
    }

    private func dragGesture(for id: UUID, size: CGSize) -> some Gesture {
        DragGesture(coordinateSpace: .named("motionCanvas"))
            .onChanged { value in
                let x: CGFloat = value.location.x / size.width
                let y: CGFloat = value.location.y / size.height
                onMove(id, clamp(x), clamp(y), false)
            }
            .onEnded { value in
                let x: CGFloat = value.location.x / size.width
                let y: CGFloat = value.location.y / size.height
                onMove(id, clamp(x), clamp(y), true)
            }
    }

    private func clamp(_ value: CGFloat) -> Double {
        let minimum: CGFloat = 0.02
        let maximum: CGFloat = 0.98
        let clamped: CGFloat = min(maximum, max(minimum, value))
        return Double(clamped)
    }
}

struct AddMotionSheet: View {
    let currentTime: Double
    let timelineDuration: Double
    let onAdd: (MotionElement) -> Void

    @Environment(\.dismiss) private var dismiss

    private var latestStart: Double { max(0, timelineDuration - 0.3) }
    private var start: Double { min(currentTime, latestStart) }
    private var remainingDuration: Double { timelineDuration - start }
    private var duration: Double { max(0.3, min(3, remainingDuration)) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    preset("Título", icon: "textformat") {
                        MotionElement.preset(.text, start: start, duration: duration)
                    }
                    preset("Número em destaque", icon: "number") {
                        MotionElement.preset(.counter, start: start, duration: duration)
                    }
                    preset("Retângulo", icon: "rectangle") {
                        MotionElement.preset(.shape, shape: .roundedRect, start: start, duration: duration)
                    }
                    preset("Círculo", icon: "circle") {
                        MotionElement.preset(.shape, shape: .circle, start: start, duration: duration)
                    }
                    preset("Linha", icon: "line.diagonal") {
                        MotionElement.preset(.shape, shape: .line, start: start, duration: duration)
                    }
                    preset("Seta", icon: "arrow.right") {
                        MotionElement.preset(.shape, shape: .arrow, start: start, duration: duration)
                    }
                } footer: {
                    Text("O elemento começa no cursor. Depois arraste na prévia para posicionar.")
                }
            }
            .navigationTitle("Adicionar motion")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func preset(_ title: String, icon: String, element: @escaping () -> MotionElement) -> some View {
        Button {
            onAdd(element())
            dismiss()
        } label: {
            Label(title, systemImage: icon)
        }
    }
}

struct MotionElementEditorSheet: View {
    let episodeDuration: Double
    let onSave: (MotionElement) -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var element: MotionElement

    init(
        element: MotionElement,
        episodeDuration: Double,
        onSave: @escaping (MotionElement) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self._element = State(initialValue: element)
        self.episodeDuration = max(episodeDuration, 1)
        self.onSave = onSave
        self.onDelete = onDelete
    }

    private var hasFill: Binding<Bool> {
        Binding(
            get: { element.fillColor != nil },
            set: {
                if $0 {
                    let defaultColor = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.6)
                    element.fillColor = element.fillColor ?? defaultColor
                } else {
                    element.fillColor = nil
                }
            }
        )
    }

    private var hasStroke: Binding<Bool> {
        Binding(
            get: { element.strokeColor != nil },
            set: {
                if $0 {
                    element.strokeColor = element.strokeColor ?? element.textColor
                } else {
                    element.strokeColor = nil
                }
            }
        )
    }

    private var textColor: Binding<Color> {
        Binding(get: { element.textColor.color }, set: { element.textColor = RGBAColor($0) })
    }

    private var fillColor: Binding<Color> {
        Binding(
            get: { element.fillColor?.color ?? .black },
            set: { element.fillColor = RGBAColor($0) }
        )
    }

    private var strokeColor: Binding<Color> {
        Binding(
            get: { element.strokeColor?.color ?? .white },
            set: { element.strokeColor = RGBAColor($0) }
        )
    }

    private var lineColor: Binding<Color> {
        Binding(
            get: { (element.strokeColor ?? element.textColor).color },
            set: { element.strokeColor = RGBAColor($0) }
        )
    }

    private var isLineShape: Bool {
        element.kind == .shape && (element.shape == .line || element.shape == .arrow)
    }

    private var previewTime: Double {
        let entrancePreviewDuration: Double = element.entranceDuration + 0.1
        let previewOffset: Double = min(element.duration, entrancePreviewDuration)
        return element.startTime + previewOffset
    }

    private struct Position: Identifiable {
        let title: String
        let x: Double
        let y: Double

        var id: String { title }
    }

    private static let positions: [Position] = [
        Position(title: "↖︎", x: 0.25, y: 0.22),
        Position(title: "↑", x: 0.5, y: 0.22),
        Position(title: "↗︎", x: 0.75, y: 0.22),
        Position(title: "←", x: 0.25, y: 0.5),
        Position(title: "•", x: 0.5, y: 0.5),
        Position(title: "→", x: 0.75, y: 0.5),
        Position(title: "↙︎", x: 0.25, y: 0.78),
        Position(title: "↓", x: 0.5, y: 0.78),
        Position(title: "↘︎", x: 0.75, y: 0.78)
    ]

    private static let positionColumns = Array(repeating: GridItem(.flexible()), count: 3)

    private var countDurationRange: ClosedRange<Double> { 0.3...5 }
    private var fontScaleRange: ClosedRange<Double> { 0.02...0.2 }
    private var widthRange: ClosedRange<Double> { 0.05...1 }
    private var heightRange: ClosedRange<Double> { 0.04...0.8 }
    private var cornerRadiusRange: ClosedRange<Double> { 0...0.5 }
    private var strokeWidthRange: ClosedRange<Double> { 0.001...0.04 }
    private var opacityRange: ClosedRange<Double> { 0.05...1 }
    private var rotationRange: ClosedRange<Double> { -180...180 }
    private var entranceDurationRange: ClosedRange<Double> { 0.1...3 }
    private var exitDurationRange: ClosedRange<Double> { 0.1...2 }
    private var startRange: ClosedRange<Double> { 0...max(episodeDuration - 0.3, 0.1) }
    private var durationRange: ClosedRange<Double> { 0.3...max(maxDuration, 0.4) }

    private var countDurationLabel: String { String(format: "%.1fs", element.countDuration) }
    private var fontScaleLabel: String { "\(Int(element.fontScale * 100))%" }
    private var widthLabel: String { "\(Int(element.widthFraction * 100))%" }
    private var heightLabel: String { "\(Int(element.heightFraction * 100))%" }
    private var cornerRadiusLabel: String { "\(Int(element.cornerRadius * 100))%" }
    private var strokeWidthLabel: String { "\(Int(element.strokeWidth * 1000))‰" }
    private var opacityLabel: String { "\(Int(element.opacity * 100))%" }
    private var rotationLabel: String { "\(Int(element.rotation))°" }
    private var entranceDurationLabel: String { String(format: "%.1fs", element.entranceDuration) }
    private var exitDurationLabel: String { String(format: "%.1fs", element.exitDuration) }
    private var durationLabel: String { String(format: "%.1fs", element.duration) }
    private var startLabel: String { TimelineView.rulerLabel(element.startTime) }

    var body: some View {
        NavigationStack {
            Form {
                previewSection
                contentSection
                appearanceSection
                animationSection
                positionSection
                timeSection
                deleteSection
            }
            .navigationTitle("Editar motion")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") {
                        onSave(element)
                        dismiss()
                    }
                }
            }
        }
    }

    private var previewSection: some View {
        Section {
            Canvas { context, size in
                context.withCGContext { cgContext in
                    MotionRenderer.draw(element, at: previewTime, canvasSize: size, in: cgContext)
                }
            }
            .frame(height: 150)
            .frame(maxWidth: .infinity)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var contentSection: some View {
        Section("Conteúdo") {
            contentRows
        }
    }

    @ViewBuilder
    private var contentRows: some View {
        switch element.kind {
        case .text:
            TextField("Texto", text: $element.text, axis: .vertical)
                .lineLimit(1...4)
        case .counter:
            TextField("De", value: $element.counterFrom, format: .number)
                .keyboardType(.decimalPad)
            TextField("Até", value: $element.counterTo, format: .number)
                .keyboardType(.decimalPad)
            TextField("Prefixo", text: $element.prefix)
            TextField("Sufixo", text: $element.suffix)
            Stepper("Casas decimais: \(element.decimals)", value: $element.decimals, in: 0...2)
            sliderRow(
                "Duração da contagem",
                value: $element.countDuration,
                range: countDurationRange,
                label: countDurationLabel
            )
        case .shape:
            Picker("Forma", selection: $element.shape) {
                ForEach(MotionShape.allCases) { shape in
                    Text(shape.rawValue).tag(shape)
                }
            }
        }
    }

    private var appearanceSection: some View {
        Section("Aparência") {
            colorRows
            sizeRows
        }
    }

    @ViewBuilder
    private var colorRows: some View {
        if isLineShape {
            ColorPicker("Cor da linha", selection: lineColor, supportsOpacity: true)
        } else {
            ColorPicker("Cor do texto", selection: textColor, supportsOpacity: true)
            Toggle("Preenchimento", isOn: hasFill)
            if element.fillColor != nil {
                ColorPicker("Cor do preenchimento", selection: fillColor, supportsOpacity: true)
            }
            Toggle("Contorno", isOn: hasStroke)
            if element.strokeColor != nil {
                ColorPicker("Cor do contorno", selection: strokeColor, supportsOpacity: true)
            }
        }
    }

    @ViewBuilder
    private var sizeRows: some View {
        Toggle("Negrito", isOn: $element.isBold)
        sliderRow("Tamanho da fonte", value: $element.fontScale, range: fontScaleRange, label: fontScaleLabel)
        sliderRow("Largura", value: $element.widthFraction, range: widthRange, label: widthLabel)
        sliderRow("Altura", value: $element.heightFraction, range: heightRange, label: heightLabel)
        sliderRow("Cantos", value: $element.cornerRadius, range: cornerRadiusRange, label: cornerRadiusLabel)
        sliderRow("Espessura do contorno", value: $element.strokeWidth, range: strokeWidthRange, label: strokeWidthLabel)
        sliderRow("Opacidade", value: $element.opacity, range: opacityRange, label: opacityLabel)
        sliderRow("Rotação", value: $element.rotation, range: rotationRange, label: rotationLabel)
    }

    private var animationSection: some View {
        Section("Animação") {
            Picker("Entrada", selection: $element.entrance) {
                ForEach(element.kind.entranceOptions) { animation in
                    Text(animation.rawValue).tag(animation)
                }
            }
            Picker("Saída", selection: $element.exit) {
                ForEach(element.kind.exitOptions) { animation in
                    Text(animation.rawValue).tag(animation)
                }
            }
            sliderRow(
                "Duração da entrada",
                value: $element.entranceDuration,
                range: entranceDurationRange,
                label: entranceDurationLabel
            )
            sliderRow(
                "Duração da saída",
                value: $element.exitDuration,
                range: exitDurationRange,
                label: exitDurationLabel
            )
        }
    }

    private var positionSection: some View {
        Section {
            LazyVGrid(columns: Self.positionColumns, spacing: 8) {
                ForEach(Self.positions) { position in
                    positionButton(position.title, x: position.x, y: position.y)
                }
            }
            .buttonStyle(.bordered)
        } header: {
            Text("Posição")
        } footer: {
            Text("Você também pode arrastar direto na prévia.")
        }
    }

    private var timeSection: some View {
        Section("Tempo") {
            sliderRow("Início", value: $element.startTime, range: startRange, label: startLabel)
            sliderRow("Duração", value: $element.duration, range: durationRange, label: durationLabel)
        }
    }

    private var deleteSection: some View {
        Section {
            Button("Remover elemento", role: .destructive) {
                onDelete()
                dismiss()
            }
        }
    }

    private var maxDuration: Double {
        let remainingDuration: Double = episodeDuration - element.startTime
        return max(0.4, remainingDuration)
    }

    private func sliderRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        label: String
    ) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range)
            Text(label).monospacedDigit().frame(minWidth: 42)
        }
    }

    private func positionButton(_ title: String, x: Double, y: Double) -> some View {
        Button(title) {
            element.centerX = x
            element.centerY = y
        }
        .frame(maxWidth: .infinity)
    }
}
