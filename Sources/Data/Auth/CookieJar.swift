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
        var bridged = 0
        for cookie in cookies {
            let domain = cookie.domain
            if domain.hasSuffix("youtube.com") || domain.hasSuffix("google.com") || domain.hasSuffix("googleusercontent.com") {
                HTTPCookieStorage.shared.setCookie(cookie)
                bridged += 1
            }
        }
        Log.innertube.debug("CookieJar bridged \(bridged) cookies from WebView → HTTPCookieStorage")
    }
}
