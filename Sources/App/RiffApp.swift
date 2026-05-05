import SwiftUI

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
        }
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
        .sheet(isPresented: $env.isSignInSheetPresented) {
            SignInView()
        }
        .sheet(isPresented: $env.isSettingsSheetPresented) {
            SettingsView()
        }
    }
}

struct MainTabs: View {
    @State private var tab: Tab = .home

    enum Tab: Hashable { case home, search, library }

    var body: some View {
        VStack(spacing: 0) {
            TopTabBar(selection: $tab)
            Group {
                switch tab {
                case .home:    HomeView()
                case .search:  SearchView()
                case .library: LibraryView()
                }
            }
        }
    }
}

struct TopTabBar: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var selection: MainTabs.Tab

    var body: some View {
        HStack(spacing: 24) {
            tab("Home", .home)
            tab("Search", .search)
            tab("Library", .library)
            Spacer()
            AccountMenu()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private func tab(_ title: String, _ value: MainTabs.Tab) -> some View {
        Button(action: {
            // Tapping the already-active tab pops its NavigationStack to
            // the root (so "Home" returns to the home grid even when the
            // user is deep inside an album/playlist detail page).
            if selection == value {
                switch value {
                case .home:    env.homeNavPath = NavigationPath()
                case .search:  env.searchNavPath = NavigationPath()
                case .library: env.libraryNavPath = NavigationPath()
                }
            } else {
                selection = value
            }
        }) {
            Text(title)
                .font(.system(size: 15, weight: selection == value ? .semibold : .regular))
                .foregroundStyle(selection == value ? .white : .secondary)
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
