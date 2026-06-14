import SwiftUI
import AppKit

@main
struct RiffApp: App {
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .frame(minWidth: 980, minHeight: 640)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(after: .appInfo) {
                if environment.isSignedIn {
                    Button("Sign Out") { environment.signOut() }
                } else {
                    Button("Sign In…") { environment.isSignInSheetPresented = true }
                        .keyboardShortcut("L", modifiers: [.command, .shift])
                }
                Button("Settings…") { environment.isSettingsSheetPresented = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .windowArrangement) {
                MiniPlayerMenuItem()
            }
            CommandGroup(before: .toolbar) {
                TabSwitchMenuItems()
                Divider()
            }
            // Transport shortcuts — Space play/pause, ⌘← / ⌘→ for prev/next
            // track, ⌘↑ / ⌘↓ for volume nudge, ⌥⌘← / ⌥⌘→ for ±15 / ±30s
            // skip. Wired through `@FocusedValue(\.appEnvironment)` so the
            // bindings hit the active window's PlayerBridge.
            CommandMenu("Playback") {
                TransportMenuItems()
            }
            CommandGroup(replacing: .help) {
                RecapMenuItem()
                Divider()
                Button("Riff on GitHub") {
                    if let url = URL(string: "https://github.com/mvk24199/Riff") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Report an Issue…") {
                    if let url = URL(string: "https://github.com/mvk24199/Riff/issues/new") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Divider()
                Button("View License (AGPL-3.0)") {
                    if let url = URL(string: "https://www.gnu.org/licenses/agpl-3.0.en.html") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }

        // Always-on-top compact playback strip in a separate window.
        // Open via Window → Mini Player (⌥⌘M).
        Window("Mini Player", id: "mini-player") {
            FloatingMiniPlayerView()
                .environment(environment)
        }
        .defaultSize(width: 360, height: 70)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

/// Help menu entry that surfaces the "Your Riff Highlights" sheet. Lives
/// in its own struct so it can read `@FocusedValue(\.appEnvironment)`,
/// which the CommandGroup builder otherwise can't reach.
private struct RecapMenuItem: View {
    @FocusedValue(\.appEnvironment) private var env

    var body: some View {
        Button("Your Riff Highlights") {
            env?.isRecapSheetPresented = true
        }
        .disabled(env == nil)
    }
}

/// Re-usable menu item that opens the Mini Player window. Lives in its
/// own struct so it can use `@Environment(\.openWindow)`.
private struct MiniPlayerMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Mini Player") { openWindow(id: "mini-player") }
            .keyboardShortcut("M", modifiers: [.command, .option])
    }
}

/// View menu entries that switch the active main tab via ⌘1 / ⌘2 / ⌘3 / ⌘4.
/// Promoted out of MainTabs so we can read the AppEnvironment at the
/// command-builder layer.
private struct TabSwitchMenuItems: View {
    @FocusedValue(\.appEnvironment) private var env

    var body: some View {
        Button("Home") { env?.activeTab = .home }
            .keyboardShortcut("1", modifiers: .command)
            .disabled(env == nil)
        Button("Explore") { env?.activeTab = .explore }
            .keyboardShortcut("2", modifiers: .command)
            .disabled(env == nil)
        Button("Search") { env?.activeTab = .search }
            .keyboardShortcut("3", modifiers: .command)
            .disabled(env == nil)
        Button("Library") { env?.activeTab = .library }
            .keyboardShortcut("4", modifiers: .command)
            .disabled(env == nil)
    }
}

/// Playback menu — exposes Space (play/pause), arrow-key transport,
/// and volume-nudge shortcuts at the App command-builder layer. Lives
/// in its own struct so it can read `@FocusedValue(\.appEnvironment)`
/// to drive the active window's PlayerBridge. Disabled when the
/// PlayerBridge isn't available (no main window focused).
private struct TransportMenuItems: View {
    @FocusedValue(\.appEnvironment) private var env

    var body: some View {
        Button("Play / Pause") {
            guard let env else { return }
            Task { await env.player.togglePlay() }
        }
        // Space is the universal play/pause shortcut. Modifier-less so
        // it works without ⌘ — matches Apple Music, Spotify, YT Music.
        .keyboardShortcut(.space, modifiers: [])
        .disabled(env?.player.hasTrack != true)

        Button("Next Track") {
            guard let env else { return }
            Task { await env.player.next() }
        }
        .keyboardShortcut(.rightArrow, modifiers: .command)
        .disabled(env?.player.hasTrack != true)

        Button("Previous Track") {
            guard let env else { return }
            Task { await env.player.previous() }
        }
        .keyboardShortcut(.leftArrow, modifiers: .command)
        .disabled(env?.player.hasTrack != true)

        Divider()

        Button("Skip Forward 30s") {
            guard let env else { return }
            Task { await env.player.skip(by: 30) }
        }
        .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
        .disabled(env?.player.hasTrack != true)

        Button("Skip Back 15s") {
            guard let env else { return }
            Task { await env.player.skip(by: -15) }
        }
        .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
        .disabled(env?.player.hasTrack != true)

        Divider()

        Button("Volume Up") {
            guard let env else { return }
            // Step ~7% per press — coarse enough that holding the
            // shortcut moves volume audibly between repeats.
            let next = min(1.0, env.player.volume + 0.07)
            Task { await env.player.setVolume(next) }
        }
        .keyboardShortcut(.upArrow, modifiers: .command)

        Button("Volume Down") {
            guard let env else { return }
            let next = max(0.0, env.player.volume - 0.07)
            Task { await env.player.setVolume(next) }
        }
        .keyboardShortcut(.downArrow, modifiers: .command)

        Divider()

        Button("Toggle Like") {
            guard let env else { return }
            Task { await env.player.toggleLike() }
        }
        .keyboardShortcut("L", modifiers: .command)
        .disabled(env?.player.hasTrack != true)

        Divider()

        Button("Toggle Shuffle") {
            env?.player.toggleShuffle()
        }
        .keyboardShortcut("S", modifiers: [.command, .shift])

        Button("Cycle Repeat") {
            guard let env else { return }
            Task { await env.player.toggleRepeat() }
        }
        .keyboardShortcut("R", modifiers: [.command, .shift])
    }
}

/// FocusedValueKey that lets `CommandGroup` content reach the active
/// window's AppEnvironment. Set in RootView via `.focusedSceneValue`.
private struct AppEnvironmentFocusKey: FocusedValueKey {
    typealias Value = AppEnvironment
}
extension FocusedValues {
    fileprivate var appEnvironment: AppEnvironment? {
        get { self[AppEnvironmentFocusKey.self] }
        set { self[AppEnvironmentFocusKey.self] = newValue }
    }
}

struct RootView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var env = env
        ZStack {
            // Swap the entire main content rather than overlay it. SwiftUI's
            // .overlay was rendering around (rather than over) the
            // NavigationStack-wrapped tabs, leaking the home content through.
            if env.player.isFullPlayerOpen {
                NowPlayingView()
                    .transition(.move(edge: .bottom))
            } else {
                ZStack(alignment: .bottom) {
                    MainTabs()
                    if env.player.hasTrack {
                        MiniPlayerView()
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: env.player.isFullPlayerOpen)
        .background(Color.black.ignoresSafeArea())
        .focusedSceneValue(\.appEnvironment, env)
        .sheet(isPresented: $env.isSignInSheetPresented) {
            SignInView()
        }
        .sheet(isPresented: $env.isSettingsSheetPresented) {
            SettingsView()
        }
        .sheet(isPresented: $env.isNewPlaylistSheetPresented) {
            NewPlaylistSheet()
        }
        .sheet(isPresented: $env.isRecapSheetPresented) {
            RecapView()
        }
        .sheet(isPresented: $env.isQueueBuilderSheetPresented) {
            QueueBuilderSheet()
        }
    }
}

struct MainTabs: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(spacing: 0) {
            TopTabBar()
            Group {
                switch env.activeTab {
                case .home:    HomeView()
                case .explore: ExploreView()
                case .search:  SearchView()
                case .library: LibraryView()
                }
            }
        }
    }
}

struct TopTabBar: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        HStack(spacing: 24) {
            tab("Home", .home)
            tab("Explore", .explore)
            tab("Search", .search)
            tab("Library", .library)
            Spacer()
            AccountMenu()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private func tab(_ title: String, _ value: AppTab) -> some View {
        Button(action: {
            // Tapping the already-active tab pops its NavigationStack to
            // the root (so "Home" returns to the home grid even when the
            // user is deep inside an album/playlist detail page).
            if env.activeTab == value {
                switch value {
                case .home:    env.homeNavPath = NavigationPath()
                case .explore: env.exploreNavPath = NavigationPath()
                case .search:  env.searchNavPath = NavigationPath()
                case .library: env.libraryNavPath = NavigationPath()
                }
            } else {
                env.activeTab = value
            }
        }) {
            Text(title)
                .font(.system(size: 15, weight: env.activeTab == value ? .semibold : .regular))
                .foregroundStyle(env.activeTab == value ? .white : .secondary)
        }
        .buttonStyle(.plain)
    }
}

/// Top-right corner. Shows a "Sign In" pill when anonymous, a circular
/// initial avatar with a Menu (Sign Out) when authenticated. Lets users
/// see and manage auth state without going to the menu bar.
private struct AccountMenu: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        if env.isSignedIn {
            Menu {
                Button("Settings…") { env.isSettingsSheetPresented = true }
                Divider()
                Button("Sign Out") { env.signOut() }
            } label: {
                Circle()
                    .fill(Theme.red)
                    .frame(width: 28, height: 28)
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28, height: 28)
        } else {
            Button("Sign In") { env.isSignInSheetPresented = true }
                .buttonStyle(.borderedProminent)
                .tint(Theme.red)
                .controlSize(.small)
        }
    }
}
