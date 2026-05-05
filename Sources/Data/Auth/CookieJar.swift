import Foundation
import WebKit

/// Bridges cookies between the hidden WKWebView's WKWebsiteDataStore and
/// HTTPCookieStorage so the InnerTubeClient can authenticate against
/// music.youtube.com without re-prompting the user.
///
/// The user signs in once via the WebView; both surfaces then share the session.
@MainActor
enum CookieJar {
    static func syncFromWebView() async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let cookies = await store.allCookies()
        for cookie in cookies where cookie.domain.hasSuffix("youtube.com") {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }
}
