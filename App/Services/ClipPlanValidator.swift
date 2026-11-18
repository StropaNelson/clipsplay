import Foundation

/// Checks a decoded ClipPlan against the package (or live project) it was
/// authored for, returning Portuguese error strings. An empty result is valid.
enum ClipPlanValidator {
    static let supportedPlanVersion = ClipPlanContract.planVersion

    /// Everything the validator needs: either rebuilt from the live project
    /// (ClipBriefBuilder.validationContext) or taken from a decoded brief.
    struct Context {
        /// Source-sequence duration in ms.
        var duration_ms: Int
        /// Assets by id (UUID string).
        var assets: [String: ClipBriefAsset]
        /// Episode states in project order; position = ep_N - 1.
        var episodes: [ClipBriefEpisodeState]
        /// Whether a transcript exists (needed to honour captions requests).
        var hasTranscript: Bool

        init(duration_ms: Int, assets: [ClipBriefAsset], episodes: [ClipBriefEpisodeState], hasTranscript: Bool) {
            self.duration_ms = duration_ms
            self.assets = Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            self.episodes = episodes
            self.hasTranscript = hasTranscript
        }

        init(brief: ClipBrief) {
            self.init(
                duration_ms: brief.source.duration_ms,
                assets: brief.assets,
                episodes: brief.episodes_state ?? [],
                hasTranscript: !brief.transcript.isEmpty
            )
        }
    }

    static func validate(_ plan: ClipPlan, project: Project) -> [String] {
        validate(plan, context: ClipBriefBuilder.validationContext(project: project))
    }

    static func validate(_ plan: ClipPlan, context: Context) -> [String] {
        var errors: [String] = []

        if plan.clipplan_version > supportedPlanVersion {
            errors.append("clipplan_version \(plan.clipplan_version) não é suportado (máximo \(supportedPlanVersion)).")
        }
        if plan.clipplan_version < 1 {
            errors.append("clipplan_version precisa ser pelo menos 1.")
        }

        let hasOutputs = plan.outputs != nil
        let hasOperations = plan.operations != nil
        if hasOutputs && hasOperations {
            errors.append("O plano tem \"outputs\" e \"operations\"; envie só um deles.")
            return errors
        }
        if !hasOutputs && !hasOperations {
            errors.append("O plano precisa ter \"outputs\" ou \"operations\".")
            return errors
        }

        if let outputs = plan.outputs {
            errors.append(contentsOf: validateOutputs(outputs, context: context))
        }
        if let operations = plan.operations {
            errors.append(contentsOf: validateOperations(operations, context: context))
        }
        return errors
    }

    // MARK: - outputs

    private static func validateOutputs(_ outputs: [ClipPlanOutput], context: Context) -> [String] {
        var errors: [String] = []
        if outputs.isEmpty {
            errors.append("A lista \"outputs\" está vazia.")
            return errors
        }
        if outputs.count > ClipPlanContract.maxOutputs {
            errors.append("O plano tem \(outputs.count) saídas; o máximo é \(ClipPlanContract.maxOutputs).")
        }
        for (index, output) in outputs.enumerated() {
            let label = output.id ?? "out_\(index + 1)"
            let prefix = "Saída \"\(label)\""

            if !ClipPlanContract.formats.contains(output.format) {
                errors.append("\(prefix): formato \"\(output.format)\" inválido (use \(ClipPlanContract.formats.joined(separator: ", "))).")
            }
            if let title = output.title, title.count > 80 {
                errors.append("\(prefix): título longo demais (máximo 80 caracteres).")
            }
            if output.segments.isEmpty {
                errors.append("\(prefix): precisa de ao menos um trecho em \"segments\".")
            }
            var pieceSeconds: [ClosedRange<Double>] = []
            for segment in output.segments {
                if segment.role != "main" {
                    errors.append("\(prefix): role \"\(segment.role)\" inválido (use \"main\").")
                }
                if segment.source_in_ms < 0 || segment.source_out_ms <= segment.source_in_ms
                    || segment.source_out_ms > context.duration_ms {
                    errors.append("\(prefix): trecho \(segment.source_in_ms)–\(segment.source_out_ms) ms fora dos limites (0–\(context.duration_ms) ms).")
                } else {
                    pieceSeconds.append(
                        Double(segment.source_in_ms) / 1000...Double(segment.source_out_ms) / 1000
                    )
                }
            }
            let merged = mergeRanges(pieceSeconds)
            let totalSeconds = merged.reduce(0.0) { $0 + ($1.upperBound - $1.lowerBound) }
            for piece in merged where piece.upperBound - piece.lowerBound <= 0.2 {
                errors.append("\(prefix): um trecho ficou curto demais (mínimo 0,2 s).")
                break
            }
            if !output.segments.isEmpty && totalSeconds <= 0.2 {
                errors.append("\(prefix): a duração total dos trechos é curta demais (mínimo 0,2 s).")
            }

            if let captions = output.captions {
                if let style = captions.style, !ClipPlanContract.captionStyles.contains(style) {
                    errors.append("\(prefix): estilo de legenda \"\(style)\" inválido (use \(ClipPlanContract.captionStyles.joined(separator: ", "))).")
                }
                if captions.enabled && !context.hasTranscript {
                    errors.append("\(prefix): legendas pedidas, mas o pacote não tem transcrição.")
                }
            }

            var vinhetaSeconds = 0.0
            for (track, vinheta) in [("intro", output.intro), ("outro", output.outro)] {
                guard let vinheta = vinheta else { continue }
                guard let asset = context.assets[vinheta.asset_id] else {
                    errors.append("\(prefix): asset_id \"\(vinheta.asset_id)\" da vinheta \(track) não existe no pacote.")
                    continue
                }
                if asset.type != "video" {
                    errors.append("\(prefix): vinheta \(track) precisa ser um asset de vídeo.")
                }
                if vinheta.in_ms < 0 || vinheta.out_ms <= vinheta.in_ms || vinheta.out_ms > asset.duration_ms {
                    errors.append("\(prefix): vinheta \(track) fora dos limites do asset (0–\(asset.duration_ms) ms).")
                } else {
                    vinhetaSeconds += Double(vinheta.out_ms - vinheta.in_ms) / 1000
                }
            }

            if let texts = output.texts {
                let timelineSeconds = totalSeconds + vinhetaSeconds
                for text in texts {
                    if text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        errors.append("\(prefix): texto de card vazio.")
                    }
                    if text.start_ms < 0 || text.duration_ms <= 0
                        || Double(text.start_ms + text.duration_ms) / 1000 > timelineSeconds + 0.05 {
                        errors.append("\(prefix): card \"\(text.text)\" fora da linha do tempo da saída.")
                    }
                    if let position = text.position, !ClipPlanContract.textPositions.contains(position) {
                        errors.append("\(prefix): posição \"\(position)\" inválida (use \(ClipPlanContract.textPositions.joined(separator: ", "))).")
                    }
                    if let style = text.style, !ClipPlanContract.textStyles.contains(style) {
                        errors.append("\(prefix): estilo de texto \"\(style)\" inválido (use \(ClipPlanContract.textStyles.joined(separator: ", "))).")
                    }
                    if let color = text.color, !ClipPlanContract.textColors.contains(color) {
                        errors.append("\(prefix): cor de texto \"\(color)\" inválida (use \(ClipPlanContract.textColors.joined(separator: ", "))).")
                    }
                }
            }
        }
        return errors
    }

    // MARK: - operations

    private static func validateOperations(_ operations: [ClipPlanOperation], context: Context) -> [String] {
        var errors: [String] = []
        if operations.isEmpty {
            errors.append("A lista \"operations\" está vazia.")
            return errors
        }
        if operations.count > ClipPlanContract.maxOperations {
            errors.append("O plano tem \(operations.count) operações; o máximo é \(ClipPlanContract.maxOperations).")
        }
        for (index, operation) in operations.enumerated() {
            let prefix = "Operação \(index + 1) (\(operation.op))"
            guard ClipPlanContract.operationKinds.contains(operation.op) else {
                errors.append("Operação \(index + 1): op \"\(operation.op)\" desconhecido.")
                continue
            }
            guard let episode = context.episodes.first(where: { $0.episode_id == operation.target }) else {
                errors.append("\(prefix): alvo \"\(operation.target)\" não existe (use ids ep_N do pacote).")
                continue
            }
            errors.append(contentsOf: validateOperation(operation, prefix: prefix, episode: episode, context: context))
        }
        return errors
    }

    private static func validateOperation(
        _ operation: ClipPlanOperation,
        prefix: String,
        episode: ClipBriefEpisodeState,
        context: Context
    ) -> [String] {
        var errors: [String] = []

        func missing(_ field: String) {
            errors.append("\(prefix): falta o parâmetro \"\(field)\".")
        }
        func segmentExists(_ id: String?) -> Bool {
            guard let id = id else { return false }
            return episode.segments.contains { $0.id == id }
        }
        func textExists(_ id: String?) -> Bool {
            guard let id = id else { return false }
            return episode.texts.contains { $0.id == id }
        }
        func audioExists(_ id: String?) -> Bool {
            guard let id = id else { return false }
            return episode.audio.contains { $0.id == id }
        }
        /// Approximate episode timeline duration in ms (ignores transition overlaps).
        let timeline_ms = episode.segments.reduce(0) { $0 + max(0, $1.source_out_ms - $1.source_in_ms) }

        switch operation.op {
        case "cut_range":
            guard let inMs = operation.in_ms else { missing("in_ms"); break }
            guard let outMs = operation.out_ms else { missing("out_ms"); break }
            if inMs < 0 || outMs <= inMs || outMs > context.duration_ms {
                errors.append("\(prefix): intervalo \(inMs)–\(outMs) ms fora dos limites (0–\(context.duration_ms) ms).")
            }
        case "remove_silences":
            if let minMs = operation.min_ms, minMs <= 0 {
                errors.append("\(prefix): min_ms precisa ser maior que zero.")
            }
        case "set_volume":
            guard let volume = operation.volume else { missing("volume"); break }
            if volume < 0 || volume > 1 {
                errors.append("\(prefix): volume precisa ficar entre 0 e 1.")
            }
            let hasSegment = segmentExists(operation.segment_id)
            let hasAudio = audioExists(operation.audio_id)
            if operation.segment_id == nil && operation.audio_id == nil {
                errors.append("\(prefix): informe segment_id ou audio_id.")
            } else if !hasSegment && !hasAudio {
                errors.append("\(prefix): segment_id/audio_id não existe em \(episode.episode_id).")
            }
        case "move_text":
            guard textExists(operation.text_id) else {
                if operation.text_id == nil { missing("text_id") } else {
                    errors.append("\(prefix): text_id \"\(operation.text_id ?? "")\" não existe em \(episode.episode_id).")
                }
                break
            }
            guard let position = operation.position else { missing("position"); break }
            if !ClipPlanContract.textPositions.contains(position) {
                errors.append("\(prefix): position \"\(position)\" inválida (use \(ClipPlanContract.textPositions.joined(separator: ", "))).")
            }
        case "set_text_style":
            guard textExists(operation.text_id) else {
                if operation.text_id == nil { missing("text_id") } else {
                    errors.append("\(prefix): text_id \"\(operation.text_id ?? "")\" não existe em \(episode.episode_id).")
                }
                break
            }
            if operation.style == nil && operation.color == nil && operation.size == nil {
                errors.append("\(prefix): informe ao menos um de style, color ou size.")
            }
            if let style = operation.style, !ClipPlanContract.textStyles.contains(style) {
                errors.append("\(prefix): style \"\(style)\" inválido (use \(ClipPlanContract.textStyles.joined(separator: ", "))).")
            }
            if let color = operation.color, !ClipPlanContract.textColors.contains(color) {
                errors.append("\(prefix): color \"\(color)\" inválida (use \(ClipPlanContract.textColors.joined(separator: ", "))).")
            }
            if let size = operation.size, size <= 0 || size > 0.5 {
                errors.append("\(prefix): size precisa ficar entre 0 e 0,5.")
            }
        case "set_aspect":
            guard let format = operation.format else { missing("format"); break }
            if !ClipPlanContract.formats.contains(format) {
                errors.append("\(prefix): format \"\(format)\" inválido (use \(ClipPlanContract.formats.joined(separator: ", "))).")
            }
        case "set_transition":
            guard segmentExists(operation.segment_id) else {
                if operation.segment_id == nil { missing("segment_id") } else {
                    errors.append("\(prefix): segment_id \"\(operation.segment_id ?? "")\" não existe em \(episode.episode_id).")
                }
                break
            }
            guard let style = operation.style else { missing("style"); break }
            if !ClipPlanContract.transitionStyles.contains(style) {
                errors.append("\(prefix): style \"\(style)\" inválido (use \(ClipPlanContract.transitionStyles.joined(separator: ", "))).")
            }
        case "add_text":
            guard let text = operation.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                missing("text"); break
            }
            guard let startMs = operation.start_ms else { missing("start_ms"); break }
            guard let durationMs = operation.duration_ms else { missing("duration_ms"); break }
            if startMs < 0 || durationMs <= 0 || startMs + durationMs > timeline_ms + 50 {
                errors.append("\(prefix): texto fora da linha do tempo de \(episode.episode_id).")
            }
            if let position = operation.position, !ClipPlanContract.textPositions.contains(position) {
                errors.append("\(prefix): position \"\(position)\" inválida (use \(ClipPlanContract.textPositions.joined(separator: ", "))).")
            }
            if let style = operation.style, !ClipPlanContract.textStyles.contains(style) {
                errors.append("\(prefix): style \"\(style)\" inválido (use \(ClipPlanContract.textStyles.joined(separator: ", "))).")
            }
            if let color = operation.color, !ClipPlanContract.textColors.contains(color) {
                errors.append("\(prefix): color \"\(color)\" inválida (use \(ClipPlanContract.textColors.joined(separator: ", "))).")
            }
        case "set_captions":
            if operation.enabled == nil { missing("enabled") }
            if let style = operation.style, !ClipPlanContract.captionStyles.contains(style) {
                errors.append("\(prefix): style \"\(style)\" inválido (use \(ClipPlanContract.captionStyles.joined(separator: ", "))).")
            }
            if operation.enabled == true && !context.hasTranscript {
                errors.append("\(prefix): legendas pedidas, mas o pacote não tem transcrição.")
            }
        case "auto_framing":
            if operation.enabled == nil { missing("enabled") }
        case "set_vinheta":
            guard let track = operation.track else { missing("track"); break }
            if !ClipPlanContract.vinhetaTracks.contains(track) {
                errors.append("\(prefix): track \"\(track)\" inválida (use \(ClipPlanContract.vinhetaTracks.joined(separator: ", "))).")
            }
            guard let assetID = operation.asset_id else { missing("asset_id"); break }
            guard let inMs = operation.in_ms else { missing("in_ms"); break }
            guard let outMs = operation.out_ms else { missing("out_ms"); break }
            guard let asset = context.assets[assetID] else {
                errors.append("\(prefix): asset_id \"\(assetID)\" não existe no pacote.")
                break
            }
            if asset.type != "video" {
                errors.append("\(prefix): a vinheta precisa ser um asset de vídeo.")
            }
            if inMs < 0 || outMs <= inMs || outMs > asset.duration_ms {
                errors.append("\(prefix): vinheta fora dos limites do asset (0–\(asset.duration_ms) ms).")
            }
        default:
            errors.append("\(prefix): op \"\(operation.op)\" desconhecido.")
        }
        return errors
    }

    // MARK: - helpers

    private static func mergeRanges(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) where range.upperBound > range.lowerBound {
            if let last = result.last, range.lowerBound <= last.upperBound + 0.02 {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }
}
