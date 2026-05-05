import AppKit
import WebKit
import Observation

/// Offscreen WKWebView that loads music.youtube.com and plays audio.
///
/// Lives in a 1x1 transparent window with a 0 alpha. Never visible after the
/// initial sign-in flow. SwiftUI controls it via `evaluateJavaScript`; the page
/// posts state changes back via `WKScriptMessageHandler`.
@MainActor
final class HiddenPlayerWebView: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: WKWebView
    private let window: NSWindow

    var onEvent: ((BridgeEvent) -> Void)?

    enum BridgeEvent {
        case ready
        case stateChanged(isPlaying: Bool)
        case progress(currentTime: Double, duration: Double)
        case trackChanged(videoId: String, title: String, artist: String, artwork: URL?)
    }

    override init() {
        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        if let scriptURL = Bundle.main.url(forResource: "player-bridge", withExtension: "js"),
           let source = try? String(contentsOf: scriptURL) {
            userContent.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        config.userContentController = userContent
        config.mediaTypesRequiringUserActionForPlayback = []

        self.webView = WKWebView(frame: .init(x: 0, y: 0, width: 1, height: 1), configuration: config)

        self.window = NSWindow(
            contentRect: .init(x: -1000, y: -1000, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        self.window.alphaValue = 0
        self.window.isOpaque = false
        self.window.backgroundColor = .clear
        self.window.contentView = webView
        self.window.orderOut(nil)

        super.init()

        userContent.add(self, name: "bridge")
        webView.navigationDelegate = self

        if let url = URL(string: "https://music.youtube.com") {
            webView.load(URLRequest(url: url))
        }
    }

    // MARK: WKScriptMessageHandler

    nonisolated func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        // Decode message.body and forward via onEvent on the main actor.
    }
}
