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
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                Canvas { context, canvasSize in
                    context.withCGContext { cgContext in
                        for element in elements {
                            MotionRenderer.draw(element, at: currentTime, canvasSize: canvasSize, in: cgContext)
                        }
                    }
                }
                .allowsHitTesting(false)
                ForEach(elements) { element in
                    let rect = MotionRenderer.frameRect(element, canvasSize: size)
                    Color.white.opacity(0.001)
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
                        .gesture(
                            DragGesture(coordinateSpace: .named("motionCanvas"))
                                .onChanged { value in
                                    onMove(
                                        element.id,
                                        clamp(value.location.x / size.width),
                                        clamp(value.location.y / size.height),
                                        false
                                    )
                                }
                                .onEnded { value in
                                    onMove(
                                        element.id,
                                        clamp(value.location.x / size.width),
                                        clamp(value.location.y / size.height),
                                        true
                                    )
                                }
                        )
                }
            }
            .frame(width: size.width, height: size.height)
            .coordinateSpace(name: "motionCanvas")
        }
    }

    private func clamp(_ value: CGFloat) -> Double {
        Double(min(0.98, max(0.02, value)))
    }
}

struct AddMotionSheet: View {
    let currentTime: Double
    let timelineDuration: Double
    let onAdd: (MotionElement) -> Void

    @Environment(\.dismiss) private var dismiss

    private var start: Double { min(currentTime, max(0, timelineDuration - 0.3)) }
    private var duration: Double { max(0.3, min(3, timelineDuration - start)) }

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

    private func preset(_ title: String, icon: String, element: () -> MotionElement) -> some View {
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
            set: { element.fillColor = $0 ? (element.fillColor ?? RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.6)) : nil }
        )
    }

    private var hasStroke: Binding<Bool> {
        Binding(
            get: { element.strokeColor != nil },
            set: { element.strokeColor = $0 ? (element.strokeColor ?? element.textColor) : nil }
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
        element.startTime + min(element.duration, element.entranceDuration + 0.1)
    }

    var body: some View {
        NavigationStack {
            Form {
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

                Section("Conteúdo") {
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
                        sliderRow("Duração da contagem", value: $element.countDuration, range: 0.3...5, label: String(format: "%.1fs", element.countDuration))
                    case .shape:
                        Picker("Forma", selection: $element.shape) {
                            ForEach(MotionShape.allCases) { shape in
                                Text(shape.rawValue).tag(shape)
                            }
                        }
                    }
                }

                Section("Aparência") {
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
                    Toggle("Negrito", isOn: $element.isBold)
                    sliderRow("Tamanho da fonte", value: $element.fontScale, range: 0.02...0.2, label: "\(Int(element.fontScale * 100))%")
                    sliderRow("Largura", value: $element.widthFraction, range: 0.05...1, label: "\(Int(element.widthFraction * 100))%")
                    sliderRow("Altura", value: $element.heightFraction, range: 0.04...0.8, label: "\(Int(element.heightFraction * 100))%")
                    sliderRow("Cantos", value: $element.cornerRadius, range: 0...0.5, label: "\(Int(element.cornerRadius * 100))%")
                    sliderRow("Espessura do contorno", value: $element.strokeWidth, range: 0.001...0.04, label: "\(Int(element.strokeWidth * 1000))‰")
                    sliderRow("Opacidade", value: $element.opacity, range: 0.05...1, label: "\(Int(element.opacity * 100))%")
                    sliderRow("Rotação", value: $element.rotation, range: -180...180, label: "\(Int(element.rotation))°")
                }

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
                    sliderRow("Duração da entrada", value: $element.entranceDuration, range: 0.1...3, label: String(format: "%.1fs", element.entranceDuration))
                    sliderRow("Duração da saída", value: $element.exitDuration, range: 0.1...2, label: String(format: "%.1fs", element.exitDuration))
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
                    sliderRow("Início", value: $element.startTime, range: 0...max(episodeDuration - 0.3, 0.1), label: TimelineView.rulerLabel(element.startTime))
                    sliderRow(
                        "Duração",
                        value: $element.duration,
                        range: 0.3...max(maxDuration, 0.4),
                        label: String(format: "%.1fs", element.duration)
                    )
                }

                Section {
                    Button("Remover elemento", role: .destructive) {
                        onDelete()
                        dismiss()
                    }
                }
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

    private var maxDuration: Double {
        max(0.4, episodeDuration - element.startTime)
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
