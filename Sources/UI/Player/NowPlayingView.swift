import SwiftUI

struct NowPlayingView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let track = env.player.currentTrack
        ZStack {
            // Blurred backdrop fed by the artwork.
            AsyncImage(url: track?.thumbnailURL) { phase in
                if case .success(let img) = phase {
                    img.resizable().scaledToFill().blur(radius: 80).opacity(0.6)
                } else { Color.black }
            }
            .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer(minLength: 32)
                AsyncImage(url: track?.thumbnailURL) { phase in
                    switch phase {
                    case .success(let img): img.resizable().aspectRatio(contentMode: .fit)
                    default: Color.gray.opacity(0.2)
                    }
                }
                .frame(maxWidth: 360, maxHeight: 360)
                .clipShape(RoundedRectangle(cornerRadius: 16))

                VStack(spacing: 4) {
                    Text(track?.title ?? "—").font(.system(size: 22, weight: .bold))
                    Text(track?.subtitle ?? "").font(.system(size: 16)).foregroundStyle(.secondary)
                }

                ProgressView(value: env.player.progress)
                    .tint(.white)
                    .padding(.horizontal, 32)

                HStack(spacing: 32) {
                    Button(action: { Task { await env.player.previous() } }) {
                        Image(systemName: "backward.fill").font(.system(size: 28))
                    }
                    Button(action: { Task { await env.player.togglePlay() } }) {
                        Image(systemName: env.player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 56))
                    }
                    Button(action: { Task { await env.player.next() } }) {
                        Image(systemName: "forward.fill").font(.system(size: 28))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)

                Spacer()
            }
            .padding(.horizontal, 32)
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 480, minHeight: 720)
    }
}
