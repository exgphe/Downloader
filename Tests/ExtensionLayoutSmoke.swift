import AppKit
import WebKit

/// Renders the actual extension scripts/styles in WebKit, without network or
/// browser credentials. Run with the repository path and a PNG output path.
@main
@MainActor
final class ExtensionLayoutSmoke: NSObject, WKNavigationDelegate {
    private var webView: WKWebView!
    private var window: NSWindow!
    private var widths = [360, 480, 960]
    private var output: URL!
    private var checks = 0

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let test = ExtensionLayoutSmoke()
        do { try test.start() } catch { print(error); exit(1) }
        withExtendedLifetime(test) { app.run() }
    }

    func start() throws {
        guard CommandLine.arguments.count == 3 else { fatalError("Usage: layout-test REPO OUTPUT.png") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        output = URL(fileURLWithPath: CommandLine.arguments[2])
        func read(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
        let config = WKWebViewConfiguration()
        var script = try read("Shared (Extension)/Resources/media-core.js")
        // loadHTMLString has an about:blank location. Only the URL is supplied
        // by the harness; collection, injection and CSS remain product code.
        script += "\n" + (try read("Shared (Extension)/Resources/content.js"))
            .replacingOccurrences(of: "location.href", with: "'https://www.instagram.com/'")
        config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 1150), configuration: config)
        webView.navigationDelegate = self
        window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderFront(nil)
        let html = try read("Tests/extension/layout.html") + "<style>" + (try read("Shared (Extension)/Resources/content.css")) + "</style>"
        webView.loadHTMLString(html, baseURL: root)
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { print("WebKit layout test timed out"); exit(1) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { next() }

    private func next() {
        guard !widths.isEmpty else { snapshot(); return }
        let width = widths.removeFirst()
        window.setContentSize(NSSize(width: width, height: 1150))
        webView.setFrameSize(NSSize(width: width, height: 1150))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.webView.evaluateJavaScript("layoutReport()") { result, error in
                guard error == nil, let rows = result as? [[String: Any]], rows.count == 4 else {
                    print("Missing layout report: \(String(describing: error))"); exit(1)
                }
                for row in rows {
                    guard row["count"] as? Int == 1, row["parent"] as? String == row["expected"] as? String,
                          row["afterShare"] as? Bool == true, row["aligned"] as? Bool == true,
                          row["following"] as? Bool == true, row["dimensions"] as? Bool == true,
                          row["overflow"] as? Bool == false else {
                        print("Layout failed at \(width)px: \(row)"); exit(1)
                    }
                    self.checks += 1
                }
                print("WebKit \(width)px: feed, deep wrappers, grouped actions and Reel rail passed")
                self.next()
            }
        }
    }

    private func snapshot() {
        webView.takeSnapshot(with: nil) { image, error in
            guard let tiff = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                print("Snapshot failed: \(String(describing: error))"); exit(1)
            }
            do { try png.write(to: self.output) } catch { print(error); exit(1) }
            print("\(self.checks) WebKit layout checks passed; snapshot: \(self.output.path)")
            exit(0)
        }
    }
}
