import SwiftUI

struct HomeView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var sections: [HomeSection] = []
    @State private var loading = true
    @State private var errorMessage: String?

    var body: some View {
        @Bindable var env = env
        NavigationStack(path: $env.homeNavPath) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 32) {
                    GreetingHeader()
                        .padding(.bottom, 4)
                    if let errorMessage {
                        ErrorBanner(message: errorMessage) {
                            Task { await load() }
                        }
                    }
                    if loading && sections.isEmpty {
                        HomeSkeleton()
                    } else {
                        ForEach(sections) { section in
                            HomeSectionRow(section: section)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .navigationDestination(for: MediaItem.self) { DetailView(item: $0) }
            .task { await load() }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let raw = try await env.innerTube.browseHome()
            // Filter blocked artists out of every carousel. We drop
            // empty sections too so a section that only contained
            // blocked artists doesn't render as a titled void.
            sections = raw.compactMap { sec in
                let kept = sec.items.filter { !env.isBlocked($0) }
                guard !kept.isEmpty else { return nil }
                return HomeSection(id: sec.id, title: sec.title, items: kept)
            }
            errorMessage = nil
        } catch {
            errorMessage = LoadErrorPresenter.message(for: error, env: env)
            // Keep stale sections visible (if any) so the user can still
            // interact with them while the banner indicates the failure.
        }
    }
}

struct HomeSection: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let items: [MediaItem]
}

/// "Good morning" / "Good afternoon" / "Good evening" header — adds the
/// touch of personality that YT Music iOS opens with. Falls back to the
/// generic "Welcome back" line when we don't have time data (we always do,
/// but the fallback keeps the view total in case Date misbehaves).
private struct GreetingHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(timeOfDayGreeting())
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
            Text("Listen to anything, anywhere.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.75))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func timeOfDayGreeting() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:  return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default:      return "Late night listening"
        }
    }
}

/// Skeleton rows shown while `browseHome()` is in flight. Two carousels'
/// worth of placeholder tiles with a soft pulse, so an empty Home tab
/// reads as "loading" instead of "broken".
private struct HomeSkeleton: View {
    @State private var pulse = false
    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 12) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(pulse ? 0.10 : 0.06))
                        .frame(width: 180, height: 22)
                    HStack(spacing: 16) {
                        ForEach(0..<5, id: \.self) { _ in
                            VStack(alignment: .leading, spacing: 8) {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.white.opacity(pulse ? 0.10 : 0.06))
                                    .frame(width: 180, height: 180)
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.white.opacity(pulse ? 0.10 : 0.06))
                                    .frame(width: 140, height: 12)
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.white.opacity(pulse ? 0.10 : 0.06))
                                    .frame(width: 100, height: 10)
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

struct HomeSectionRow: View {
    let section: HomeSection

    /// "Quick picks" rails on YT Music iOS are dense 2-column grids
    /// (4 rows × 2 cols of small list rows) rather than wide tile carousels.
    /// We detect by title and render accordingly.
    private var renderAsQuickPicks: Bool {
        let lower = section.title.lowercased()
        return lower.contains("quick picks") || lower == "quick picks"
    }

    /// Friendly subtitles for known section titles, mirroring YT Music iOS
    /// micro-copy. Falls through to nil for sections we don't recognise.
    private var subtitle: String? {
        switch section.title.lowercased() {
        case "listen again":         return "Hits you've had on repeat"
        case "quick picks":          return "Tap to play"
        case "mixed for you":        return "Personal mixes refreshed daily"
        case "new releases for you": return "From artists you follow"
        case "trending":             return "Popular right now"
        case "forgotten favorites":  return "From your library, rediscovered"
        case "shows for you":        return "Podcasts we think you'll like"
        case "recommended for you":  return "Picked just for you"
        default:                     return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(section.title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }

            if renderAsQuickPicks {
                quickPicksGrid
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 16) {
                        ForEach(section.items) { item in
                            ThumbnailButton(item: item)
                        }
                    }
                }
            }
        }
    }

    /// Compact 2-column list rows — the "Quick picks" pattern from YT
    /// Music iOS. Shows up to 8 items in a 2×4 layout with thumbnails on
    /// the left and title/subtitle to the right.
    private var quickPicksGrid: some View {
        let items = Array(section.items.prefix(8))
        return LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 16),
                      GridItem(.flexible(), spacing: 16)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(items) { item in
                QuickPickRow(item: item)
            }
        }
    }
}

/// Single row inside a Quick Picks grid — small thumbnail + title /
/// subtitle, hover-to-play button overlay on the artwork.
private struct QuickPickRow: View {
    @Environment(AppEnvironment.self) private var env
    let item: MediaItem
    @State private var hovering: Bool = false

    var body: some View {
        Button {
            Task { await play() }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    AsyncImage(url: item.thumbnailURL) { phase in
                        if case .success(let img) = phase {
                            img.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Color.white.opacity(0.06)
                        }
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    if hovering {
                        ZStack {
                            Color.black.opacity(0.5)
                            Image(systemName: "play.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(item.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(Color.white.opacity(hovering ? 0.06 : 0.0))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private func play() async {
        switch item.kind {
        case .song, .episode: await env.player.play(item: item)
        case .album:          await env.player.playAlbum(id: item.id)
        case .playlist:       await env.player.playPlaylist(id: item.id)
        case .artist:         await env.player.playArtistRadio(id: item.id)
        case .podcast:        await env.player.playPodcast(id: item.id)
        }
    }
}
