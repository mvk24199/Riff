import SwiftUI
import WebKit

/// Optional sign-in surface. Manually invoked from the menu bar
/// ("Riff › Sign In…", ⇧⌘L) or the Library tab's empty-state CTA.
///
/// **Known limitation**: Google blocks Google-account sign-in from embedded
/// webviews ("Couldn't sign you in. This browser or app may not be secure")
/// as an anti-account-takeover measure. UA spoofing alone doesn't beat the
/// fingerprinting (navigator.webdriver / plugins / network stack). Until we
/// implement OAuth Device Flow as a Phase 2 task, this sheet ships as a
/// best-effort stub: cookies will be picked up correctly *if* the user
/// somehow gets past the wall, but the typical experience is "this doesn't
/// work, dismiss and use anonymous mode." Anonymous browse + click-to-play
/// works fully — only Library and personalization need the session.
///
/// On successful sign-in (SAPISID cookie present), `CookieJar.syncFromWebView`
/// mirrors cookies into `HTTPCookieStorage` so `InnerTubeClient` picks them up.
struct SignInView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sign in to YouTube Music")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            SignInWebView { didSignIn in
                if didSignIn {
                    Task { await CookieJar.syncFromWebView() }
                    env.isSignInSheetPresented = false
                }
            }
            .frame(minWidth: 480, minHeight: 640)
        }
        .frame(minWidth: 480, minHeight: 700)
    }
}

private struct SignInWebView: NSViewRepresentable {
    /// Called when the webview reaches a signed-in state.
    let onComplete: (Bool) -> Void

    func makeNSView(context: Context) -> WKWebView {
        // Reuse the default data store so the hidden audio WKWebView shares
        // cookies; CookieJar then mirrors them into HTTPCookieStorage for
        // InnerTubeClient.
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: config)
        // Pose as Chrome — YT Music's web app blocks Safari/WebKit with a
        // "not optimized for your browser" interstitial.
        view.customUserAgent = InnerTubeClient.userAgent
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: URL(string: "https://music.youtube.com/")!))
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onComplete: (Bool) -> Void
        init(onComplete: @escaping (Bool) -> Void) { self.onComplete = onComplete }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let host = webView.url?.host, host.contains("music.youtube.com") else { return }
            Task { [weak webView] in
                guard let webView else { return }
                let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                let signedIn = cookies.contains { $0.name == "SAPISID" || $0.name == "__Secure-3PAPISID" }
                if signedIn {
                    await MainActor.run { self.onComplete(true) }
                }
            }
        }
    }
}
