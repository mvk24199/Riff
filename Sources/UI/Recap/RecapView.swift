import SwiftUI

// MARK: - Pure stats

/// Aggregated stats computed from `PlayerBridge.queue.playedHistory`.
///
/// Held as a plain value type so the SwiftUI sheet stays a thin presenter
/// and the math is trivially unit-testable — `RecapStatsTests` feeds
/// fixture `[MediaItem]` arrays directly without standing up a PlayerBridge.
///
/// The "Year in Riff" framing is intentionally avoided: `playedHistory` is
/// capped at 50 entries (see `QueueManager.historyCap`), so anything
/// labeled "year" would lie about the sample. We call it "Highlights".
struct RecapStats: Equatable, Sendable {
    /// One entry in the top-artists list.
    struct ArtistCount: Equatable, Hashable, Sendable {
        let name: String
        let count: Int
    }

    /// One entry in the top-tracks list. We keep a representative
    /// `MediaItem` per id so the row can render artwork + tap-to-play.
    struct TrackCount: Equatable, Hashable, Sendable {
        let item: MediaItem
        let count: Int
    }

    let totalPlays: Int
    let uniqueTracks: Int
    let topArtists: [ArtistCount]
    let topTracks: [TrackCount]
    /// Average release year across tracks that carry one. nil unless at
    /// least 3 tracks supplied a year — fewer than that and the
    /// "average" is just one or two data points, which we don't show.
    let averageYear: Int?
    /// Sum of `durationSeconds` across the history. nil when no track
    /// in the history carried a duration at all (rare, but possible —
    /// see `MediaItem.durationSeconds` docs).
    let totalRuntimeSeconds: Int?
    let firstPlayed: MediaItem?
    let mostRecent: MediaItem?

    var isEmpty: Bool { totalPlays == 0 }

    /// Threshold below which the average-year stat is suppressed.
    static let minYearSampleSize = 3

    /// The single entry point: takes the oldest-→-newest played history
    /// array and produces the full aggregation. Pure function; safe to
    /// call from any thread, but typed `@MainActor`-free on purpose so
    /// tests can run it directly.
    static func compute(from history: [MediaItem]) -> RecapStats {
        let totalPlays = history.count
        let uniqueTracks = Set(history.map(\.id)).count

        // Bucket artists case-insensitively on the subtitle. We keep
        // the first-seen casing of the name for display — YT's
        // subtitle field is consistent for a given artist within a
        // session, so the first occurrence is a reasonable canonical.
        var artistBuckets: [String: (name: String, count: Int)] = [:]
        for item in history {
            let trimmed = item.subtitle.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if let existing = artistBuckets[key] {
                artistBuckets[key] = (existing.name, existing.count + 1)
            } else {
                artistBuckets[key] = (trimmed, 1)
            }
        }
        let topArtists = artistBuckets.values
            .map { ArtistCount(name: $0.name, count: $0.count) }
            // Sort by count desc; tie-break alphabetically so the
            // output is stable across runs (Set/Dictionary iteration
            // isn't ordered, which would flake tests otherwise).
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .prefix(5)

        // Bucket tracks by id; keep the first occurrence's MediaItem
        // so we have artwork + title to render.
        var trackBuckets: [String: (item: MediaItem, count: Int)] = [:]
        for item in history {
            if let existing = trackBuckets[item.id] {
                trackBuckets[item.id] = (existing.item, existing.count + 1)
            } else {
                trackBuckets[item.id] = (item, 1)
            }
        }
        let topTracks = trackBuckets.values
            .map { TrackCount(item: $0.item, count: $0.count) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.item.title.localizedCaseInsensitiveCompare(rhs.item.title) == .orderedAscending
            }
            .prefix(10)

        // Average year — only when we have enough samples to make it
        // meaningful. `Double` division then rounded to the nearest
        // year for display.
        let years = history.compactMap(\.year)
        let averageYear: Int?
        if years.count >= minYearSampleSize {
            let sum = years.reduce(0, +)
            averageYear = Int((Double(sum) / Double(years.count)).rounded())
        } else {
            averageYear = nil
        }

        let durations = history.compactMap(\.durationSeconds)
        let totalRuntime: Int? = durations.isEmpty ? nil : durations.reduce(0, +)

        return RecapStats(
            totalPlays: totalPlays,
            uniqueTracks: uniqueTracks,
            topArtists: Array(topArtists),
            topTracks: Array(topTracks),
            averageYear: averageYear,
            totalRuntimeSeconds: totalRuntime,
            firstPlayed: history.first,
            mostRecent: history.last
        )
    }
}

// MARK: - Formatting helpers (file-private)

/// "1h 42m" / "42 min" / "0 min". Total-runtime stat uses minute
/// granularity — seconds aren't interesting at history scale.
fileprivate func formatRuntime(_ totalSeconds: Int) -> String {
    let totalMinutes = totalSeconds / 60
    if totalMinutes < 60 {
        return "\(totalMinutes) min"
    }
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    return "\(hours)h \(minutes)m"
}

// MARK: - View

/// Sheet body for the "Your Riff Highlights" view. Reached via the
/// Help menu's "Your Riff Highlights" entry; presented over RootView.
///
/// Pure presentation — all aggregation runs through `RecapStats.compute`
/// on the played history snapshot taken in `body`. No network, no
/// InnerTube calls.
struct RecapView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let stats = RecapStats.compute(from: env.player.playedHistory)

        VStack(spacing: 0) {
            header
            Divider()
            if stats.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        intro
                        statsGrid(stats: stats)
                        if !stats.topArtists.isEmpty {
                            topArtistsSection(stats: stats)
                        }
                        if !stats.topTracks.isEmpty {
                            topTracksSection(stats: stats)
                        }
                        if let recent = stats.mostRecent {
                            mostRecentSection(item: recent)
                        }
                    }
                    .padding(28)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 620)
    }

    // MARK: header / chrome

    private var header: some View {
        HStack {
            Text("Your Riff Highlights")
                .font(.system(size: 16, weight: .semibold))
            Spacer()
            Button("Close") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("From this session's playback")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
            Text("Riff tracks your recent plays locally — never uploaded. Up to the last 50 tracks count toward these stats.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 2x2 stat tiles

    @ViewBuilder
    private func statsGrid(stats: RecapStats) -> some View {
        // Two columns, two rows. Adaptive grid would re-flow on narrow
        // widths, but the sheet has a fixed minWidth so the 2-column
        // layout is stable.
        let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        LazyVGrid(columns: columns, spacing: 12) {
            statTile(value: "\(stats.totalPlays)", label: "Total plays")
            statTile(value: "\(stats.uniqueTracks)", label: "Unique tracks")
            statTile(
                value: stats.totalRuntimeSeconds.map(formatRuntime) ?? "—",
                label: "Listening time"
            )
            statTile(
                value: stats.averageYear.map(String.init) ?? "—",
                label: "Average year"
            )
        }
    }

    private func statTile(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.red)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: top artists

    @ViewBuilder
    private func topArtistsSection(stats: RecapStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Top artists")
            VStack(spacing: 4) {
                ForEach(Array(stats.topArtists.enumerated()), id: \.offset) { index, entry in
                    artistRow(rank: index + 1, entry: entry, stats: stats)
                }
            }
        }
    }

    private func artistRow(rank: Int, entry: RecapStats.ArtistCount, stats: RecapStats) -> some View {
        // Walk the topTracks list once to find an artistId for this
        // artist name. Some tracks carry it (MediaItem.artistId); when
        // none do, the row is static. Cheap — up to 10 tracks.
        let artistId = stats.topTracks
            .first(where: {
                $0.item.subtitle.localizedCaseInsensitiveCompare(entry.name) == .orderedSame
                    && $0.item.artistId != nil
            })?.item.artistId

        return Button {
            if let id = artistId {
                env.navigateToBrowseId(id, kind: .artist, fallbackTitle: entry.name)
                dismiss()
            }
        } label: {
            HStack(spacing: 12) {
                Text("\(rank)")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 22, alignment: .trailing)
                Text(entry.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(entry.count) \(entry.count == 1 ? "play" : "plays")")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(artistId == nil)
    }

    // MARK: top tracks

    @ViewBuilder
    private func topTracksSection(stats: RecapStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Top tracks")
            VStack(spacing: 4) {
                ForEach(Array(stats.topTracks.enumerated()), id: \.offset) { index, entry in
                    trackRow(rank: index + 1, entry: entry)
                }
            }
        }
    }

    private func trackRow(rank: Int, entry: RecapStats.TrackCount) -> some View {
        Button {
            Task { await env.player.play(item: entry.item) }
        } label: {
            HStack(spacing: 12) {
                Text("\(rank)")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 22, alignment: .trailing)
                AsyncImage(url: entry.item.thumbnailURL) { phase in
                    if case .success(let img) = phase {
                        img.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.white.opacity(0.06)
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(entry.item.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("\(entry.count)x")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.red)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: most recent

    private func mostRecentSection(item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Most recent")
            Button {
                Task { await env.player.play(item: item) }
            } label: {
                HStack(spacing: 12) {
                    AsyncImage(url: item.thumbnailURL) { phase in
                        if case .success(let img) = phase {
                            img.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Color.white.opacity(0.06)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(item.subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.red)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.white.opacity(0.35))
            Text("Nothing to highlight yet")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
            Text("Play a few tracks and come back — Riff will summarize what you listened to.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: small helpers

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .tracking(1.2)
            .foregroundStyle(.white.opacity(0.55))
    }
}
