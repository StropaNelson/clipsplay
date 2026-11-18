import Foundation

/// Portuguese instructions sent alongside the .clipbrief so ChatGPT/Copilot
/// replies with a JSON the app can validate and apply.
enum ClipPromptGenerator {
    static func prompt(for brief: ClipBrief) -> String {
        let operationsNote = brief.episodes_state != nil
            ? "Como o pacote inclui \"episodes_state\", você também pode devolver \"operations\" com edições sobre os episódios existentes — elas são aplicadas direto na timeline (os ids ep_N/seg_N/txt_N/aud_N vêm do pacote — não invente novos)."
            : "Este pacote não tem \"episodes_state\"; responda só com \"outputs\" (novas saídas)."

        return """
        Você está ajudando a editar o vídeo "\(brief.project_name)" no app ClipStudio (iPad). \
        O usuário anexou um arquivo .clipbrief com a análise do vídeo (transcrição, cortes de cena, pausas, ganchos e assets). Se o arquivo não estiver anexado, peça ao usuário que o anexe antes de responder.

        A SUA RESPOSTA DEVE SER SOMENTE UM JSON VÁLIDO no formato .clipplan abaixo — sem explicações, sem markdown, sem bloco de código:

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

        Ou, para editar episódios já existentes:

        {
          "clipplan_version": \(ClipPlanContract.planVersion),
          "operations": [
            { "op": "cut_range", "target": "ep_1", "in_ms": 12000, "out_ms": 18000 },
            { "op": "set_volume", "target": "ep_1", "audio_id": "aud_1", "volume": 0.3 },
            { "op": "add_text", "target": "ep_1", "text": "Resumo", "start_ms": 0, "duration_ms": 2000, "position": "top" }
          ]
        }

        REGRAS:
        - Use exatamente UM dos campos: "outputs" (criar novas saídas) ou "operations" (editar episódios existentes). Nunca os dois.
        - Todos os tempos são inteiros em milissegundos sobre a sequência de origem do pacote (source.duration_ms é o limite).
        - Máximo de \(ClipPlanContract.maxOutputs) saídas ou \(ClipPlanContract.maxOperations) operações por plano.
        - "format" só aceita: \(ClipPlanContract.formats.joined(separator: ", ")).
        - Não invente asset_id: use somente ids da lista "assets" do pacote (vinhetas precisam ser do tipo "video").
        - Legendas ("captions") são geradas pelo app a partir da transcrição: nunca escreva o texto da legenda, só ligue/desligue com enabled e style ("dynamic" ou "static").
        - "texts" são cartões curtos (títulos/chamadas), não legendas.
        - Escolha os "segments" como ideias completas: corte em fim de frase (use "transcript", "pauses" e "scene_cuts"), nunca no meio de uma frase.
        - Em "operations", cada item precisa de "op" e "target" (ep_N). Ops aceitas: \(ClipPlanContract.operationKinds.joined(separator: ", ")).
          cut_range{in_ms,out_ms} · remove_silences{min_ms?} · set_volume{segment_id|audio_id,volume 0-1} · move_text{text_id,position} · set_text_style{text_id,style?,color?,size?} · set_aspect{format} · set_transition{segment_id,style:\(ClipPlanContract.transitionStyles.joined(separator: "|"))} · add_text{text,start_ms,duration_ms,position?,style?,color?} · set_captions{enabled,style} · auto_framing{enabled} · set_vinheta{track:\(ClipPlanContract.vinhetaTracks.joined(separator: "|")),asset_id,in_ms,out_ms}
        - positions: \(ClipPlanContract.textPositions.joined(separator: ", ")) · styles de texto: \(ClipPlanContract.textStyles.joined(separator: ", ")) · colors: \(ClipPlanContract.textColors.joined(separator: ", ")).
        \(operationsNote)
        """
    }
}
