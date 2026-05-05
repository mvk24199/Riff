import SwiftUI
import AppKit

/// User-facing OAuth credential setup. Shown when:
/// 1. The user explicitly opens it from the menu bar / account menu, or
/// 2. They tap a Library section while signed in with default credentials
///    (which can't reach Data API v3).
///
/// The default `client_id` we ship is the public YouTube TV one, which
/// works for sign-in but its GCP project doesn't have Data API v3
/// enabled — so Library calls 403. Pasting their own credentials here
/// fixes that.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var clientId: String = ""
    @State private var clientSecret: String = ""
    @State private var saved = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    accountSection
                    Divider().background(Theme.divider)
                    keyboardShortcutsSection
                    Divider().background(Theme.divider)
                    libraryAccessSection
                    Divider().background(Theme.divider)
                    aboutSection
                }
                .padding(28)
            }
        }
        .frame(minWidth: 540, minHeight: 620)
        .onAppear {
            let config = OAuthClientConfig.load()
            if config.isCustom {
                clientId = config.clientId
                clientSecret = config.clientSecret
            }
        }
    }

    // MARK: - Sections

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Account")
            HStack(spacing: 14) {
                Circle()
                    .fill(env.isSignedIn ? Theme.red : Color.white.opacity(0.1))
                    .frame(width: 36, height: 36)
                    .overlay(
                        Image(systemName: env.isSignedIn ? "person.fill" : "person")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(env.isSignedIn ? "Signed in to YouTube Music" : "Not signed in")
                        .font(.system(size: 13, weight: .semibold))
                    Text(env.isSignedIn
                         ? "Library + personalized recommendations are available."
                         : "Anonymous browse + click-to-play work; sign in for Library access.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.65))
                }
                Spacer()
                if env.isSignedIn {
                    Button("Sign Out") {
                        env.signOut()
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("Sign In…") {
                        env.isSignInSheetPresented = true
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.red)
                }
            }
        }
    }

    private var keyboardShortcutsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Keyboard shortcuts")
            shortcutRow("Sign in",         keys: "⇧ ⌘ L")
            shortcutRow("Settings",        keys: "⌘ ,")
            shortcutRow("Mini Player",     keys: "⌥ ⌘ M")
            shortcutRow("Close player",    keys: "⎋")
            shortcutRow("Quit",            keys: "⌘ Q")
        }
    }

    private var libraryAccessSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Library access (advanced)")
            Text("Riff signs you in via Google's WebView flow which gives you full Library access through the YouTube Music cookie session — no setup required. The OAuth Device Flow path below is only useful if you want to access the YouTube Data API directly. Most users can ignore this.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Configure custom OAuth credentials") {
                VStack(alignment: .leading, spacing: 16) {
                    setupSteps
                    credentialsBlock
                }
                .padding(.top, 12)
            }
            .font(.system(size: 12, weight: .semibold))
            .tint(.white)
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("About")
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Riff")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Native macOS YouTube Music client • AGPL-3.0")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                Text("v0.1.0")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .tracking(1.2)
            .foregroundStyle(.white.opacity(0.55))
    }

    private func shortcutRow(_ label: String, keys: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
            Text(keys)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Library access")
                .font(.system(size: 22, weight: .bold))
            Text("Riff signs you in via Google's Device Flow using a public YouTube TV OAuth client. That works for sign-in, but the underlying Google Cloud project doesn't expose the YouTube Data API — which is what we need to read your liked songs and playlists.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
            Text("To unlock the Library tab, register your own OAuth Limited-Input client in Google Cloud (free, ~5 min) and paste the credentials below.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var setupSteps: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Setup")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .textCase(.uppercase)
                .tracking(1.2)

            stepRow(n: 1, title: "Open Google Cloud Console") {
                Button {
                    NSWorkspace.shared.open(URL(string: "https://console.cloud.google.com/apis/library/youtube.googleapis.com")!)
                } label: {
                    Label("Open Cloud Console", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
            }
            stepRow(n: 2, title: "Enable the YouTube Data API v3 on a new or existing project.") { EmptyView() }
            stepRow(n: 3, title: "Go to Credentials → Create Credentials → OAuth client ID. Pick \u{201C}TVs and Limited Input devices\u{201D} as the application type.") { EmptyView() }
            stepRow(n: 4, title: "Copy the client ID and client secret into the fields below and click Save.") { EmptyView() }
        }
    }

    private func stepRow<Content: View>(n: Int, title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.red)
                .frame(width: 22, height: 22)
                .background(Color.white.opacity(0.06))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                content()
            }
        }
    }

    private var credentialsBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("OAuth credentials")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .textCase(.uppercase)
                .tracking(1.2)
            VStack(alignment: .leading, spacing: 6) {
                Text("Client ID")
                    .font(.system(size: 12, weight: .semibold))
                TextField("xxxxxxxxx-xxxxxxxx.apps.googleusercontent.com", text: $clientId)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Client secret")
                    .font(.system(size: 12, weight: .semibold))
                SecureField("GOCSPX-…", text: $clientSecret)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }
            HStack {
                Button("Save & sign out") {
                    let config = OAuthClientConfig(
                        clientId: clientId.trimmingCharacters(in: .whitespacesAndNewlines),
                        clientSecret: clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    config.save()
                    env.signOut()
                    saved = true
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.red)
                .disabled(clientId.isEmpty || clientSecret.isEmpty)

                Button("Reset to defaults") {
                    OAuthClientConfig.reset()
                    clientId = ""
                    clientSecret = ""
                    env.signOut()
                }
                .buttonStyle(.bordered)

                if saved {
                    Text("Saved. Sign in again to use the new credentials.")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                }
            }
            .padding(.top, 4)
        }
    }
}
