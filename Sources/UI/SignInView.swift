import SwiftUI
import WebKit

/// The single place a WKWebView is visible to the user.
///
/// Presented as a sheet on first launch; loads the YouTube Music sign-in flow
/// directly so the user authenticates via Google's normal pages. Once the
/// webview lands on a `music.youtube.com/*` URL with the `SAPISID` cookie set,
/// the parent flips `AppEnvironment.hasSignedIn = true`, dismisses the sheet,
/// and `CookieJar.syncFromWebView()` mirrors cookies into `HTTPCookieStorage`
/// so `InnerTubeClient` requests carry the session. From that point on the
/// WKWebView the audio engine uses is offscreen — see [HiddenPlayerWebView].
struct SignInView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sign in to YouTube Music")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            SignInWebView { didSignIn in
                if didSignIn {
                    env.hasSignedIn = true
                    dismiss()
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
