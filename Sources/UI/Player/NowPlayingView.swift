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

                if !env.player.upNext.isEmpty {
                    UpNextList(items: env.player.upNext)
                        .frame(maxHeight: 240)
                }

                Spacer()
            }
            .padding(.horizontal, 32)
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 480, minHeight: 720)
    }
}

private struct UpNextList: View {
    let items: [MediaItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Up Next")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(items) { item in
                        HStack(spacing: 12) {
                            AsyncImage(url: item.thumbnailURL) { phase in
                                if case .success(let img) = phase {
                                    img.resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    Color.gray.opacity(0.2)
                                }
                            }
                            .frame(width: 36, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.system(size: 13)).lineLimit(1)
                                Text(item.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                }
            }
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
