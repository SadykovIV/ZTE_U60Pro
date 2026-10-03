import AppKit
import Foundation
import SwiftUI
import WebKit

// Standalone offline harness. Compile only this file with ModemTerminal.swift
// and UITerminalView.swift; these stubs deliberately exclude modem/settings IO.
// From MacIMEI: xcrun swiftc -swift-version 5 Sources/ModemTerminal.swift
// Sources/UITerminalView.swift Tests/TerminalLayoutTests.swift -o /tmp/TerminalLayoutTests
// Run on the local macOS GUI host (WKWebView cannot launch inside its sandbox).
struct Identity { let cid: String }
struct Connection {
    let host: String, port: String, keyPath: String, knownHostsPath: String
    func validate() throws {}
}
struct TerminalLayoutError: Error { let message: String }
func require(_ value: Bool, _ message: String) throws {
    if !value { throw TerminalLayoutError(message: message) }
}
func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

@main @MainActor final class TerminalLayoutTests: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var web: WKWebView!
    private var bridge: ModemTerminalView.Coordinator!
    private let session = ModemTerminalSession()
    private let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    private var checks = 0

    static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared, delegate = TerminalLayoutTests()
        app.delegate = delegate; app.setActivationPolicy(.accessory); app.run()
        withExtendedLifetime(delegate) {}
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await run(); session.disconnect(); print("TerminalLayoutTests: \(checks) PASS"); NSApp.terminate(nil) }
            catch { session.disconnect(); print("TerminalLayoutTests FAIL: \(error)"); exit(1) }
        }
    }
    private func pause() async { try? await Task.sleep(nanoseconds: 300_000_000) }
    private func js(_ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript(script) { result, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: result) }
            }
        }
    }
    private func check(_ value: Bool, _ message: String) throws {
        try require(value, message); checks += 1; print("PASS " + message)
    }
    private func run() async throws {
        bridge = ModemTerminalView.Coordinator(session: session)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(bridge, name: "terminal")
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 860, height: 460), configuration: configuration)
        bridge.view = web; bridge.directory = project.appendingPathComponent("Resources/Terminal").standardizedFileURL
        web.navigationDelegate = bridge; web.uiDelegate = bridge
        window = NSWindow(contentRect: web.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Terminal layout · offline verification"; window.contentView = web
        window.makeKeyAndOrderFront(nil)
        web.loadFileURL(bridge.directory!.appendingPathComponent("index.html"), allowingReadAccessTo: bridge.directory!)
        for _ in 0..<40 { if bridge.ready { break }; await pause() }
        try check(bridge.ready, "Bundled terminal loaded in actual WKWebView")
        try session.launch(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", """
        i=1; while [ "$i" -le 90 ]; do printf 'Local test line %s\\n' "$i"; i=$((i+1)); done
        printf 'FINAL_PROMPT# '
        while IFS= read -r line; do
          case "$line" in size) stty size ;; *) printf 'ECHO:%s\\n' "$line" ;; esac
          printf 'FINAL_PROMPT# '
        done
        """])
        await pause(); bridge.flush(); await pause()
        var clippingObserved = false
        let baseline = CommandLine.arguments.contains("--expect-clipping")
        for size in [NSSize(width: 860, height: 460), NSSize(width: 520, height: 310),
                     NSSize(width: 340, height: 180), NSSize(width: 860, height: 460)] {
            window.setContentSize(size); await pause()
            _ = try await js("term.input('size\\r', true)")
            await pause(); bridge.flush(); await pause()
            let metrics = try await js("""
            (() => {
              const b=term.buffer.active, s=document.querySelector('.xterm-screen').getBoundingClientRect();
              const cell=s.height/term.rows, cursorBottom=s.top+(b.cursorY+1)*cell;
              return {width:innerWidth,height:innerHeight,screenBottom:s.bottom,screenRight:s.right,
                cursorBottom,rows:term.rows,cols:term.cols,atBottom:b.viewportY===b.baseY,
                prompt:b.getLine(b.baseY+b.cursorY).translateToString(true),
                output:Array.from({length:b.length},(_,i)=>b.getLine(i).translateToString(true)).join('\\n')};
            })()
            """) as! [String: Any]
            let width = metrics["width"] as! Double, height = metrics["height"] as! Double
            let bottom = metrics["screenBottom"] as! Double, right = metrics["screenRight"] as! Double
            let cursor = metrics["cursorBottom"] as! Double
            let rows = metrics["rows"] as! Int, cols = metrics["cols"] as! Int
            print("LAYOUT \(Int(width))x\(Int(height)) grid=\(cols)x\(rows) screenBottom=\(bottom) cursorBottom=\(cursor)")
            clippingObserved = clippingObserved || bottom > height + 0.5 || right > width + 0.5
            if !baseline {
                try check(bottom <= height - 12 + 0.5 && right <= width - 12 + 0.5, "Entire terminal grid fits inside padding at \(Int(width))x\(Int(height))")
                try check(cursor <= height - 12 + 0.5 && metrics["atBottom"] as? Bool == true &&
                          (metrics["prompt"] as? String)?.contains("FINAL_PROMPT#") == true,
                          "Final prompt and cursor remain visible after resize")
                try check((metrics["output"] as? String)?.contains("\(rows) \(cols)") == true,
                          "Local PTY dimensions match visible terminal grid")
                if Int(width) == 520 { try await snapshot(named: "terminal-small.png") }
            }
        }
        if baseline { try check(clippingObserved, "Original CSS reproduces clipped bottom/right edge"); return }
        _ = try await js("term.scrollToTop()")
        await pause()
        try check(try await js("term.buffer.active.viewportY===0") as? Bool == true, "Earlier output remains scrollable")
        _ = try await js("term.scrollToBottom()")
        await pause()
        try check(try await js("term.buffer.active.viewportY===term.buffer.active.baseY") as? Bool == true, "Returning to bottom restores prompt")
        try await snapshot(named: "terminal-layout.png")
    }
    private func snapshot(named name: String) async throws {
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            web.takeSnapshot(with: nil) { image, error in
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: error ?? TerminalLayoutError(message: "No snapshot")) }
            }
        }
        let directory = project.appendingPathComponent(".build/terminal-layout-20261003")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: directory.appendingPathComponent(name))
        }
    }
}
