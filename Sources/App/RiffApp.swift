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
            }
        }
    }
}

struct RootView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var env = env
        ZStack(alignment: .bottom) {
            MainTabs()
            if env.player.hasTrack {
                MiniPlayerView()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Color.black.ignoresSafeArea())
        .sheet(isPresented: $env.isSignInSheetPresented) {
            OAuthSignInView()
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
    @Binding var selection: MainTabs.Tab

    var body: some View {
        HStack(spacing: 24) {
            tab("Home", .home)
            tab("Search", .search)
            tab("Library", .library)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private func tab(_ title: String, _ value: MainTabs.Tab) -> some View {
        Button(action: { selection = value }) {
            Text(title)
                .font(.system(size: 15, weight: selection == value ? .semibold : .regular))
                .foregroundStyle(selection == value ? .white : .secondary)
        }
        .buttonStyle(.plain)
    }
}
