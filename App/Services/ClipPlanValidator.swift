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
                let timeline_ms = Int(((totalSeconds + vinhetaSeconds) * 1000).rounded())
                for text in texts {
                    if text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        errors.append("\(prefix): texto de card vazio.")
                    }
                    if text.start_ms == nil && text.at_segment == nil {
                        errors.append("\(prefix): card \"\(text.text)\" precisa de start_ms ou at_segment.")
                    }
                    if text.duration_ms <= 0 {
                        errors.append("\(prefix): card \"\(text.text)\" tem duration_ms inválido.")
                    }
                    if let at = text.at, !ClipPlanContract.anchorKinds.contains(at) {
                        errors.append("\(prefix): at \"\(at)\" inválido (use start ou end).")
                    }
                    if let resolved = outputTextStart_ms(text, merged: merged, timeline_ms: timeline_ms) {
                        if resolved + text.duration_ms > timeline_ms + 50 {
                            errors.append("\(prefix): card \"\(text.text)\" fora da linha do tempo da saída.")
                        }
                    } else if text.at_segment != nil {
                        errors.append("\(prefix): at_segment \(text.at_segment ?? 0) do card \"\(text.text)\" não existe nesta saída.")
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
        /// Approximate episode timeline duration in ms (ignores transition overlaps).
        let timeline_ms = episode.segments.reduce(0) { $0 + max(0, $1.source_out_ms - $1.source_in_ms) }

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
        func overlayExists(_ id: String?) -> Bool {
            guard let id = id else { return false }
            return (episode.overlays ?? []).contains { $0.id == id }
        }
        func segmentMissing(_ field: String = "segment_id") {
            if operation.segment_id == nil { missing(field) } else {
                errors.append("\(prefix): segment_id \"\(operation.segment_id ?? "")\" não existe em \(episode.episode_id).")
            }
        }
        /// Resolves a (possibly negative) timeline ms against the episode end.
        func resolvedTimeline(_ startMs: Int?) -> Int? {
            episodeStart_ms(
                startMs: startMs,
                atSegment: nil,
                at: nil,
                episode: episode,
                timeline_ms: timeline_ms
            )
        }

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
            guard let durationMs = operation.duration_ms else { missing("duration_ms"); break }
            if durationMs <= 0 {
                errors.append("\(prefix): duration_ms precisa ser maior que zero.")
            }
            if operation.start_ms == nil && operation.at_segment == nil {
                errors.append("\(prefix): informe start_ms ou at_segment.")
                break
            }
            if let at = operation.at, !ClipPlanContract.anchorKinds.contains(at) {
                errors.append("\(prefix): at \"\(at)\" inválido (use start ou end).")
            }
            guard let resolved = episodeStart_ms(
                startMs: operation.start_ms,
                atSegment: operation.at_segment,
                at: operation.at,
                episode: episode,
                timeline_ms: timeline_ms
            ) else {
                errors.append("\(prefix): at_segment \(operation.at_segment ?? 0) não existe em \(episode.episode_id).")
                break
            }
            // Negative start_ms always resolves (clamped to 0 by the executor);
            // only a start running past the episode end is rejected.
            if resolved + durationMs > timeline_ms + 50 {
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
        case "set_speed":
            guard segmentExists(operation.segment_id) else { segmentMissing(); break }
            guard let speed = operation.speed else { missing("speed"); break }
            if speed < 0.2 || speed > 4 {
                errors.append("\(prefix): speed precisa ficar entre 0,2 e 4.")
            }
        case "set_adjustments":
            guard segmentExists(operation.segment_id) else { segmentMissing(); break }
            if operation.brightness == nil && operation.contrast == nil && operation.saturation == nil
                && operation.warmth == nil && operation.vignette == nil && operation.remove_background == nil {
                errors.append("\(prefix): informe ao menos um de brightness, contrast, saturation, warmth, vignette ou remove_background.")
            }
            for (name, value) in [("brightness", operation.brightness), ("warmth", operation.warmth)] {
                if let value = value, value < -1 || value > 1 {
                    errors.append("\(prefix): \(name) precisa ficar entre -1 e 1.")
                }
            }
            if let contrast = operation.contrast, contrast < 0.25 || contrast > 4 {
                errors.append("\(prefix): contrast precisa ficar entre 0,25 e 4.")
            }
            if let saturation = operation.saturation, saturation < 0 || saturation > 2 {
                errors.append("\(prefix): saturation precisa ficar entre 0 e 2.")
            }
            if let vignette = operation.vignette, vignette < 0 || vignette > 1 {
                errors.append("\(prefix): vignette precisa ficar entre 0 e 1.")
            }
        case "set_transform":
            guard segmentExists(operation.segment_id) else { segmentMissing(); break }
            if operation.scale == nil && operation.rotation == nil
                && operation.offset_x == nil && operation.offset_y == nil {
                errors.append("\(prefix): informe ao menos um de scale, rotation, offset_x ou offset_y.")
            }
            if let scale = operation.scale, scale < 0.25 || scale > 4 {
                errors.append("\(prefix): scale precisa ficar entre 0,25 e 4.")
            }
            if let rotation = operation.rotation, rotation < -180 || rotation > 180 {
                errors.append("\(prefix): rotation precisa ficar entre -180 e 180.")
            }
            for (name, value) in [("offset_x", operation.offset_x), ("offset_y", operation.offset_y)] {
                if let value = value, value < -1 || value > 1 {
                    errors.append("\(prefix): \(name) precisa ficar entre -1 e 1.")
                }
            }
        case "trim_segment":
            guard let segmentID = operation.segment_id else { missing("segment_id"); break }
            guard let seg = episode.segments.first(where: { $0.id == segmentID }) else {
                errors.append("\(prefix): segment_id \"\(segmentID)\" não existe em \(episode.episode_id).")
                break
            }
            if operation.in_ms == nil && operation.out_ms == nil {
                errors.append("\(prefix): informe ao menos um de in_ms ou out_ms.")
                break
            }
            for (name, value) in [("in_ms", operation.in_ms), ("out_ms", operation.out_ms)] {
                guard let value = value else { continue }
                if value < 0 {
                    errors.append("\(prefix): \(name) \(value) ms inválido (mínimo 0).")
                } else if seg.track == "main" && value > context.duration_ms {
                    errors.append("\(prefix): \(name) \(value) ms além da sequência (0–\(context.duration_ms) ms).")
                }
            }
            let newIn = operation.in_ms ?? seg.source_in_ms
            let newOut = operation.out_ms ?? seg.source_out_ms
            if newOut - newIn <= 50 {
                errors.append("\(prefix): o trecho resultante ficaria curto demais (mínimo 0,05 s).")
            }
        case "split":
            guard let segmentID = operation.segment_id else { missing("segment_id"); break }
            guard let seg = episode.segments.first(where: { $0.id == segmentID }) else {
                errors.append("\(prefix): segment_id \"\(segmentID)\" não existe em \(episode.episode_id).")
                break
            }
            guard seg.track == "main" else {
                errors.append("\(prefix): split só vale para clipes main (track \"main\").")
                break
            }
            guard let atMs = operation.at_ms else { missing("at_ms"); break }
            if atMs <= seg.source_in_ms + 50 || atMs >= seg.source_out_ms - 50 {
                errors.append("\(prefix): at_ms \(atMs) precisa ficar dentro do trecho \(seg.source_in_ms)–\(seg.source_out_ms) ms (com 0,05 s de margem).")
            }
        case "remove_segment":
            guard segmentExists(operation.segment_id) else { segmentMissing(); break }
        case "reorder":
            guard let ids = operation.order, !ids.isEmpty else { missing("order"); break }
            let mainIDs = episode.segments.filter { $0.track == "main" }.map(\.id)
            if ids.count != mainIDs.count || Set(ids) != Set(mainIDs) {
                errors.append("\(prefix): order precisa ser uma permutação dos clipes main do episódio (\(mainIDs.joined(separator: ", "))).")
            }
        case "rename":
            guard let title = operation.title,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                missing("title"); break
            }
            if title.count > 80 {
                errors.append("\(prefix): título longo demais (máximo 80 caracteres).")
            }
        case "delete_episode":
            // No params: the episode named by target is removed after all other ops.
            break
        case "set_audio":
            guard audioExists(operation.audio_id) else {
                if operation.audio_id == nil { missing("audio_id") } else {
                    errors.append("\(prefix): audio_id \"\(operation.audio_id ?? "")\" não existe em \(episode.episode_id).")
                }
                break
            }
            if operation.volume == nil && operation.fade_in_ms == nil
                && operation.fade_out_ms == nil && operation.duck_level == nil {
                errors.append("\(prefix): informe ao menos um de volume, fade_in_ms, fade_out_ms ou duck_level.")
            }
            for (name, value) in [("volume", operation.volume), ("duck_level", operation.duck_level)] {
                if let value = value, value < 0 || value > 1 {
                    errors.append("\(prefix): \(name) precisa ficar entre 0 e 1.")
                }
            }
            for (name, value) in [("fade_in_ms", operation.fade_in_ms), ("fade_out_ms", operation.fade_out_ms)] {
                if let value = value, value < 0 {
                    errors.append("\(prefix): \(name) precisa ser maior ou igual a zero.")
                }
            }
        case "remove_audio":
            guard audioExists(operation.audio_id) else {
                if operation.audio_id == nil { missing("audio_id") } else {
                    errors.append("\(prefix): audio_id \"\(operation.audio_id ?? "")\" não existe em \(episode.episode_id).")
                }
                break
            }
        case "add_audio":
            guard let assetID = operation.asset_id else { missing("asset_id"); break }
            guard let asset = context.assets[assetID] else {
                errors.append("\(prefix): asset_id \"\(assetID)\" não existe no pacote.")
                break
            }
            if asset.type == "image" {
                errors.append("\(prefix): add_audio precisa de um asset de áudio ou vídeo.")
            }
            if let kind = operation.kind, !ClipPlanContract.audioKinds.contains(kind) {
                errors.append("\(prefix): kind \"\(kind)\" inválido (use \(ClipPlanContract.audioKinds.joined(separator: ", "))).")
            }
            let sourceIn = operation.source_in_ms ?? 0
            let sourceOut = operation.source_out_ms ?? asset.duration_ms
            if sourceIn < 0 || sourceOut <= sourceIn || sourceOut > asset.duration_ms {
                errors.append("\(prefix): trecho de origem \(sourceIn)–\(sourceOut) ms fora dos limites do asset (0–\(asset.duration_ms) ms).")
            }
            for (name, value) in [("volume", operation.volume), ("duck_level", operation.duck_level)] {
                if let value = value, value < 0 || value > 1 {
                    errors.append("\(prefix): \(name) precisa ficar entre 0 e 1.")
                }
            }
            for (name, value) in [("fade_in_ms", operation.fade_in_ms), ("fade_out_ms", operation.fade_out_ms)] {
                if let value = value, value < 0 {
                    errors.append("\(prefix): \(name) precisa ser maior ou igual a zero.")
                }
            }
            if let start = resolvedTimeline(operation.start_ms), start > timeline_ms + 50 {
                errors.append("\(prefix): start_ms \(operation.start_ms ?? 0) fora da linha do tempo de \(episode.episode_id).")
            }
        case "add_overlay":
            guard let assetID = operation.asset_id else { missing("asset_id"); break }
            guard let asset = context.assets[assetID] else {
                errors.append("\(prefix): asset_id \"\(assetID)\" não existe no pacote.")
                break
            }
            if asset.type == "audio" {
                errors.append("\(prefix): add_overlay precisa de um asset de vídeo ou imagem.")
            }
            if let duration = operation.duration_ms, duration <= 0 {
                errors.append("\(prefix): duration_ms precisa ser maior que zero.")
            }
            if let start = resolvedTimeline(operation.start_ms), start > timeline_ms + 50 {
                errors.append("\(prefix): start_ms \(operation.start_ms ?? 0) fora da linha do tempo de \(episode.episode_id).")
            }
            validateOverlayParams(operation, prefix: prefix, errors: &errors)
        case "set_overlay":
            guard overlayExists(operation.overlay_id) else {
                if operation.overlay_id == nil { missing("overlay_id") } else {
                    errors.append("\(prefix): overlay_id \"\(operation.overlay_id ?? "")\" não existe em \(episode.episode_id).")
                }
                break
            }
            let anyParam = operation.center_x != nil || operation.center_y != nil
                || operation.width_fraction != nil || operation.start_ms != nil
                || operation.duration_ms != nil || operation.source_start_ms != nil
                || operation.opacity != nil
                || operation.rotation != nil || operation.volume != nil
                || operation.chroma_enabled != nil || operation.chroma_r != nil
                || operation.chroma_g != nil || operation.chroma_b != nil
                || operation.chroma_tolerance != nil
            if !anyParam {
                errors.append("\(prefix): informe ao menos um parâmetro para editar o overlay.")
            }
            if let duration = operation.duration_ms, duration <= 0 {
                errors.append("\(prefix): duration_ms precisa ser maior que zero.")
            }
            if let sourceStart = operation.source_start_ms, sourceStart < 0 {
                errors.append("\(prefix): source_start_ms precisa ser maior ou igual a zero.")
            }
            if let start = resolvedTimeline(operation.start_ms), start > timeline_ms + 50 {
                errors.append("\(prefix): start_ms \(operation.start_ms ?? 0) fora da linha do tempo de \(episode.episode_id).")
            }
            validateOverlayParams(operation, prefix: prefix, errors: &errors)
        case "remove_overlay":
            guard overlayExists(operation.overlay_id) else {
                if operation.overlay_id == nil { missing("overlay_id") } else {
                    errors.append("\(prefix): overlay_id \"\(operation.overlay_id ?? "")\" não existe em \(episode.episode_id).")
                }
                break
            }
        case "set_chroma":
            // Chroma key is an overlay (ovl_N) feature — targeting a storyline
            // seg_N is rejected with the dedicated message.
            if operation.overlay_id == nil && operation.segment_id == nil {
                errors.append("\(prefix): informe overlay_id (ovl_N).")
                break
            }
            if let segmentID = operation.segment_id {
                if episode.segments.contains(where: { $0.id == segmentID }) {
                    errors.append("\(prefix): chroma só em overlays — use o overlay_id (ovl_N) de \(episode.episode_id).")
                } else {
                    errors.append("\(prefix): segment_id \"\(segmentID)\" não existe em \(episode.episode_id).")
                }
                break
            }
            guard overlayExists(operation.overlay_id) else {
                errors.append("\(prefix): overlay_id \"\(operation.overlay_id ?? "")\" não existe em \(episode.episode_id).")
                break
            }
            if operation.enabled == nil { missing("enabled"); break }
            if let color = operation.color {
                let trimmed = color.trimmingCharacters(in: .whitespaces)
                let hex = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
                guard hex.count == 6, hex.allSatisfy({ $0.isHexDigit }) else {
                    errors.append("\(prefix): color \"\(color)\" inválida (use \"#RRGGBB\").")
                    break
                }
            }
            if let tolerance = operation.tolerance, tolerance < 0 || tolerance > 1 {
                errors.append("\(prefix): tolerance precisa ficar entre 0 e 1.")
            }
        case "add_marker":
            guard let timeMs = operation.time_ms else { missing("time_ms"); break }
            if timeMs < 0 || timeMs > timeline_ms + 50 {
                errors.append("\(prefix): time_ms \(timeMs) fora da linha do tempo de \(episode.episode_id).")
            }
        case "remove_marker":
            guard let timeMs = operation.time_ms else { missing("time_ms"); break }
            if timeMs < 0 {
                errors.append("\(prefix): time_ms \(timeMs) inválido (mínimo 0).")
                break
            }
            if !(episode.markers ?? []).contains(where: { abs($0 - timeMs) <= 500 }) {
                errors.append("\(prefix): não há marcador perto de \(timeMs) ms em \(episode.episode_id).")
            }
        default:
            errors.append("\(prefix): op \"\(operation.op)\" desconhecido.")
        }
        return errors
    }

    /// Shared range checks for add_overlay / set_overlay geometry, color and
    /// chroma params (start/duration handled by the callers).
    private static func validateOverlayParams(
        _ operation: ClipPlanOperation,
        prefix: String,
        errors: inout [String]
    ) {
        for (name, value) in [("center_x", operation.center_x), ("center_y", operation.center_y)] {
            if let value = value, value < 0 || value > 1 {
                errors.append("\(prefix): \(name) precisa ficar entre 0 e 1.")
            }
        }
        if let width = operation.width_fraction, width < 0.05 || width > 1 {
            errors.append("\(prefix): width_fraction precisa ficar entre 0,05 e 1.")
        }
        for (name, value) in [("opacity", operation.opacity), ("volume", operation.volume)] {
            if let value = value, value < 0 || value > 1 {
                errors.append("\(prefix): \(name) precisa ficar entre 0 e 1.")
            }
        }
        if let rotation = operation.rotation, rotation < -180 || rotation > 180 {
            errors.append("\(prefix): rotation precisa ficar entre -180 e 180.")
        }
        for (name, value) in [
            ("chroma_r", operation.chroma_r), ("chroma_g", operation.chroma_g),
            ("chroma_b", operation.chroma_b), ("chroma_tolerance", operation.chroma_tolerance)
        ] {
            if let value = value, value < 0 || value > 1 {
                errors.append("\(prefix): \(name) precisa ficar entre 0 e 1.")
            }
        }
    }

    /// Resolved start (ms) of an output text card: `at_segment` anchors to the
    /// Nth merged piece's cumulative position on the output timeline (1-based),
    /// a negative `start_ms` counts back from the output's end.
    private static func outputTextStart_ms(
        _ text: ClipPlanText,
        merged: [ClosedRange<Double>],
        timeline_ms: Int
    ) -> Int? {
        let shift = text.start_ms ?? 0
        if let atSegment = text.at_segment {
            guard merged.indices.contains(atSegment - 1) else { return nil }
            var cursor = 0
            for range in merged.prefix(atSegment - 1) {
                cursor += Int(((range.upperBound - range.lowerBound) * 1000).rounded())
            }
            if text.at == "end" {
                let anchor = merged[atSegment - 1]
                cursor += Int(((anchor.upperBound - anchor.lowerBound) * 1000).rounded())
            }
            return cursor + shift
        }
        if shift < 0 { return timeline_ms + shift }
        return shift
    }

    /// Resolved timeline ms for an episode op: `at_segment` anchors to seg_N's
    /// storyline position (timeline_in/out fields when present, else the
    /// cumulative source durations), negative counts back from the episode end.
    private static func episodeStart_ms(
        startMs: Int?,
        atSegment: Int?,
        at: String?,
        episode: ClipBriefEpisodeState,
        timeline_ms: Int
    ) -> Int? {
        let shift = startMs ?? 0
        if let atSegment = atSegment {
            guard episode.segments.indices.contains(atSegment - 1) else { return nil }
            let seg = episode.segments[atSegment - 1]
            let anchor: Int
            if let timelineIn = seg.timeline_in_ms, let timelineOut = seg.timeline_out_ms {
                anchor = at == "end" ? timelineOut : timelineIn
            } else {
                var cursor = 0
                for item in episode.segments.prefix(atSegment - 1) {
                    cursor += max(0, item.source_out_ms - item.source_in_ms)
                }
                anchor = at == "end"
                    ? cursor + max(0, seg.source_out_ms - seg.source_in_ms)
                    : cursor
            }
            return anchor + shift
        }
        if shift < 0 { return timeline_ms + shift }
        return shift
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
