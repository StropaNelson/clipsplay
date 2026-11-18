import Foundation

/// Portuguese instructions sent alongside the .clipbrief so ChatGPT/Copilot
/// replies with a JSON the app can validate and apply.
enum ClipPromptGenerator {
    /// The full ops table as a compact `op{params}` list — generated from the
    /// same ClipPlanContract.operationSpecs the brief advertises, so prompt
    /// and validator can never drift apart.
    private static var opsTable: String {
        ClipPlanContract.operationSpecs
            .map { "\($0.op)\($0.params)" }
            .joined(separator: " · ")
    }

    static func prompt(for brief: ClipBrief) -> String {
        let operationsNote = brief.episodes_state != nil
            ? "Como o pacote inclui \"episodes_state\", você também pode devolver \"operations\" com edições sobre os episódios existentes — elas são aplicadas direto na timeline (os ids ep_N/seg_N/txt_N/aud_N/ovl_N vêm do pacote — não invente novos)."
            : "Este pacote não tem \"episodes_state\"; responda só com \"outputs\" (novas saídas)."

        return """
        Você está ajudando a editar o vídeo "\(brief.project_name)" no app ClipStudio (iPad). \
        O usuário anexou um arquivo .clipbrief com a análise do vídeo (transcrição, cortes de cena, pausas, ganchos e assets). Se o arquivo não estiver anexado, peça ao usuário que o anexe antes de responder.

        Responda APENAS com um bloco de código ```json ... ``` — nenhum texto antes ou depois. Dentro do bloco vai UM JSON VÁLIDO no formato .clipplan abaixo:

        ```json
        {
          "clipplan_version": \(ClipPlanContract.planVersion),
          "outputs": [
            {
              "id": "out_1",
              "title": "Título curto da saída",
              "format": "9:16",
              "segments": [ { "source_in_ms": 12000, "source_out_ms": 45000, "role": "main" } ],
              "captions": { "enabled": true, "style": "dynamic" },
              "auto_framing": true,
              "intro": { "asset_id": "<id de um asset do pacote>", "in_ms": 0, "out_ms": 1500 },
              "texts": [ { "text": "Card curto", "start_ms": 0, "duration_ms": 2500, "position": "top", "style": "box", "color": "yellow" } ],
              "reason": "Por que este corte funciona"
            }
          ]
        }
        ```

        Ou, para editar episódios já existentes:

        ```json
        {
          "clipplan_version": \(ClipPlanContract.planVersion),
          "operations": [
            { "op": "cut_range", "target": "ep_1", "in_ms": 12000, "out_ms": 18000 },
            { "op": "set_volume", "target": "ep_1", "audio_id": "aud_1", "volume": 0.3 },
            { "op": "add_text", "target": "ep_1", "text": "Resumo", "start_ms": -4000, "duration_ms": 3000, "position": "top" }
          ]
        }
        ```

        REGRAS:
        - Use exatamente UM dos campos: "outputs" (criar novas saídas) ou "operations" (editar episódios existentes). Nunca os dois.
        - Todos os tempos são inteiros em milissegundos.
        - TEMPOS DE ORIGEM (source_in_ms, source_out_ms, in_ms, out_ms, at_ms) referem-se à sequência de origem inteira do pacote — source.duration_ms é o limite.
        - TEMPOS DE TIMELINE (start_ms, duration_ms, time_ms) de textos, overlays, áudios e marcadores referem-se à linha do tempo de CADA saída/episódio (0 até a duração da saída). Em episodes_state, cada seg_N traz timeline_in_ms/timeline_out_ms mostrando onde o trecho está — use-os para posicionar edições.
        - Para colocar um texto "perto do fim", use start_ms NEGATIVO contando a partir do fim (ex.: -4000 = últimos 4 s). Para prender um texto a um trecho específico, use at_segment (1-based: o N-ésimo segmento da saída, ou o índice do seg_N no episódio) com at = "start" ou "end"; start_ms ainda desloca a partir da âncora.
        - Máximo de \(ClipPlanContract.maxOutputs) saídas ou \(ClipPlanContract.maxOperations) operações por plano.
        - "format" só aceita: \(ClipPlanContract.formats.joined(separator: ", ")).
        - Não invente asset_id: use somente ids da lista "assets" do pacote (vinhetas precisam ser do tipo "video"; overlays, "video" ou "image"; áudios, "audio" ou "video").
        - Legendas ("captions") são geradas pelo app a partir da transcrição: nunca escreva o texto da legenda, só ligue/desligue com enabled e style ("dynamic" ou "static").
        - "texts" são cartões curtos (títulos/chamadas), não legendas.
        - Inclua sempre "reason" explicando a escolha em cada saída.
        - Escolha os "segments" como ideias completas: corte em fim de frase (use "transcript", "pauses" e "scene_cuts"), nunca no meio de uma frase.
        - Em "operations", cada item precisa de "op" e "target" (ep_N). Ops aceitas:
          \(opsTable)
        - positions: \(ClipPlanContract.textPositions.joined(separator: ", ")) · styles de texto: \(ClipPlanContract.textStyles.joined(separator: ", ")) · colors: \(ClipPlanContract.textColors.joined(separator: ", ")) · transições: \(ClipPlanContract.transitionStyles.joined(separator: ", ")) · kind de áudio: \(ClipPlanContract.audioKinds.joined(separator: ", ")).
        \(operationsNote)
        """
    }

    /// Compact instructions for the on-device model (small context window):
    /// the role, the ops vocabulary as one-liners and the answer contract —
    /// no examples, no formatting tables.
    static func miniPrompt(for brief: ClipBrief) -> String {
        let ops = ClipPlanContract.operationSpecs
            .map { spec -> String in
                guard let detail = spec.detail else { return "\(spec.op)\(spec.params)" }
                return "\(spec.op)\(spec.params) (\(detail))"
            }
            .joined(separator: " · ")
        return """
        Você edita o vídeo "\(brief.project_name)" no app ClipStudio. O JSON do usuário é um .clipbrief compacto com o estado do projeto: ids ep_N/seg_N/txt_N/aud_N/ovl_N em episodes_state (cada seg_N tem source_in/out_ms na origem e timeline_in/out_ms na linha do tempo) e assets em "assets".
        Responda SÓ com JSON válido {"clipplan_version":\(ClipPlanContract.planVersion),"operations":[{...}]} ou {"clipplan_version":\(ClipPlanContract.planVersion),"outputs":[{...}]} — sem texto fora do JSON. Cada operação tem "op" e "target"="ep_N"; ids vêm do pacote, não invente.
        Tempos sempre em ms: source_*/in_ms/out_ms/at_ms = sequência de origem (limite source.duration_ms); start_ms/duration_ms/time_ms = timeline do episódio; start_ms negativo conta a partir do fim.
        Ops: \(ops)
        Este pacote não inclui transcrição de fala: pedidos baseados no conteúdo falado podem sair imprecisos — prefira operações sobre os ids e tempos do pacote.
        """
    }
}
