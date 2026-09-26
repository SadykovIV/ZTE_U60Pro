import SwiftUI
import WebKit

struct ModemTerminalView: NSViewRepresentable {
    @ObservedObject var session: ModemTerminalSession
    let resources: URL
    func makeCoordinator() -> Coordinator { Coordinator(session: session) }
    func makeNSView(context: Context) -> WKWebView {
        let content = WKUserContentController(); content.add(context.coordinator, name: "terminal")
        let config = WKWebViewConfiguration(); config.userContentController = content
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator; view.uiDelegate = context.coordinator
        context.coordinator.view = view
        let directory = resources.appendingPathComponent("Terminal")
        context.coordinator.directory = directory.standardizedFileURL
        view.loadFileURL(directory.appendingPathComponent("index.html"), allowingReadAccessTo: directory)
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) { context.coordinator.flush() }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "terminal")
        view.navigationDelegate = nil; view.uiDelegate = nil
        coordinator.view = nil
    }
    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        let session: ModemTerminalSession
        weak var view: WKWebView?
        var directory: URL?
        var ready = false, cursor = 0
        var generation: UInt64?
        init(session: ModemTerminalSession) { self.session = session }
        func flush() {
            guard ready, let view else { return }
            if generation != session.screenGeneration {
                generation = session.screenGeneration; cursor = 0
                view.evaluateJavaScript("terminalReset()", completionHandler: nil)
            }
            let output = session.output(from: cursor)
            if output.truncated { view.evaluateJavaScript("terminalReset()", completionHandler: nil) }
            cursor = output.end
            if !output.data.isEmpty { view.evaluateJavaScript("terminalWrite('\(output.data.base64EncodedString())')", completionHandler: nil) }
            view.evaluateJavaScript("terminalConnected(\(session.connected ? "true" : "false"))", completionHandler: nil)
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let object = message.body as? [String: Any], let type = object["type"] as? String else { return }
            switch type {
            case "ready": ready = true; flush()
            case "input": if let text = object["value"] as? String { session.send(text) }
            case "binary": if let text = object["value"] as? String { session.send(Data(text.utf16.map { UInt8(truncatingIfNeeded: $0) })) }
            case "resize":
                if let value = object["value"] as? [String: Int], let cols = value["cols"], let rows = value["rows"] { session.resize(columns: cols, rows: rows) }
            default: break
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard action.targetFrame?.isMainFrame == true, let url = action.request.url, url.isFileURL,
                  url.standardizedFileURL == directory?.appendingPathComponent("index.html").standardizedFileURL else { decisionHandler(.cancel); return }
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    }
}
