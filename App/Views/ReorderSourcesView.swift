import Foundation
import SwiftUI
import UIKit

/// Pre-import step that lists the selected videos already sorted by recording
/// date and lets the user rearrange them before the project is created.
struct ReorderSourcesSheet: View {
    @Binding var videos: [PendingVideo]
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("Ordenados pela data de gravação — arraste para mudar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                List {
                    ForEach(videos) { video in
                        row(for: video)
                    }
                    .onMove(perform: move)
                }
                .listStyle(.plain)
                .environment(\.editMode, .constant(EditMode.active))

                Button(action: onConfirm) {
                    Text("Criar projeto")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding()
            }
            .navigationTitle("Ordem dos vídeos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    EditButton()
                }
            }
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        videos.move(fromOffsets: source, toOffset: destination)
    }

    private func position(of video: PendingVideo) -> Int {
        (videos.firstIndex(of: video) ?? 0) + 1
    }

    private func row(for video: PendingVideo) -> some View {
        HStack(spacing: 12) {
            Text("\(position(of: video))")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24)

            thumbnail(for: video)

            VStack(alignment: .leading, spacing: 3) {
                Text(video.name)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(subtitle(for: video))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func thumbnail(for video: PendingVideo) -> some View {
        if let url = video.thumbnailURL, let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 64, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.2))
                .frame(width: 64, height: 36)
                .overlay {
                    Image(systemName: "film")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
        }
    }

    private func subtitle(for video: PendingVideo) -> String {
        let duration = ReorderSourcesSheet.durationString(video.duration)
        guard let recordedAt = video.recordedAt else {
            return "\(duration) · data desconhecida"
        }
        return "\(duration) · \(ReorderSourcesSheet.dateFormatter.string(from: recordedAt))"
    }

    private static func durationString(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd/MM HH:mm"
        return formatter
    }()
}
