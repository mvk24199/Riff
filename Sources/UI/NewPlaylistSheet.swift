import SwiftUI

/// Tiny sheet that prompts for a playlist name, then creates it and adds
/// the currently-playing track in one flow.
struct NewPlaylistSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var creating: Bool = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Playlist")
                .font(.system(size: 16, weight: .semibold))
            Text("Creates a private playlist and adds the currently-playing track.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)

            TextField("Playlist name", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit { create() }

            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    create()
                } label: {
                    if creating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Create")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.red)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || creating)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func create() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        creating = true
        error = nil
        Task {
            do {
                _ = try await env.player.createPlaylistWithCurrentTrack(title: trimmed)
                env.reloadUserPlaylists()
                await MainActor.run {
                    creating = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    self.error = "Couldn't create playlist: \(error.localizedDescription)"
                    creating = false
                }
            }
        }
    }
}
