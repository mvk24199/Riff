import SwiftUI
import WebKit
import AppKit

/// SwiftUI host for the hidden WKWebView, used by the audio-to-video
/// toggle on Now Playing. The architectural rule (CLAUDE.md) says the
/// WKWebView is never visible after sign-in — this view is the one
/// scoped exception: an opt-in, dismissible pane embedded inside the
/// Now Playing player itself.
///
/// Reparents the WKWebView owned by HiddenPlayerWebView into a
/// container NSView so the same video element (and its current
/// playback position, src, audio output) keeps running. When the host
/// view is torn down, the WebView is reattached to its original
/// offscreen 1x1 window via PlayerBridge.reattachWebViewOffscreen().
///
/// We use a container NSView rather than handing the WKWebView straight
/// to NSViewRepresentable so the same WKWebView instance can survive
/// repeated attach / detach cycles without SwiftUI ever destroying it.
struct VideoPaneView: NSViewRepresentable {
    let webView: WKWebView
    let onDismantle: @MainActor () -> Void

    @MainActor
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        attach(webView: webView, into: container)
        return container
    }

    @MainActor
    func updateNSView(_ nsView: NSView, context: Context) {
        if webView.superview !== nsView {
            attach(webView: webView, into: nsView)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        // SwiftUI guarantees dismantle is called on the main thread.
        MainActor.assumeIsolated { coordinator.fireDismantle() }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismantle: onDismantle)
    }

    @MainActor
    final class Coordinator {
        private let onDismantle: @MainActor () -> Void
        private var fired = false
        init(onDismantle: @escaping @MainActor () -> Void) {
            self.onDismantle = onDismantle
        }
        func fireDismantle() {
            guard !fired else { return }
            fired = true
            onDismantle()
        }
    }

    @MainActor
    private func attach(webView: WKWebView, into container: NSView) {
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}
