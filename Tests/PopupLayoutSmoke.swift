import AppKit
import WebKit

/// Exercises the shipped popup HTML, CSS and JavaScript with native status
/// fixtures. It never reads browser cookies, Keychain or a live website.
@main
@MainActor
final class PopupLayoutSmoke: NSObject, WKNavigationDelegate {
    private var webView: WKWebView!
    private var window: NSWindow!
    private var root: URL!
    private var output: URL!
    private var cases: [(String, String, Bool)] = []
    private var current = ("", "", false)
    private var count = 0

    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let test = PopupLayoutSmoke()
        do { try test.start() } catch { print(error); exit(1) }
        withExtendedLifetime(test) { NSApplication.shared.run() }
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func start() throws {
        guard CommandLine.arguments.count == 3 else { fatalError("Usage: popup-test REPO OUTPUT.png") }
        root = URL(fileURLWithPath: CommandLine.arguments[1])
        output = URL(fileURLWithPath: CommandLine.arguments[2])
        for locale in ["en", "fr", "zh_TW", "zh_CN"] {
            for platform in ["macOS", "iOS", "visionOS"] { cases.append((locale, platform, false)) }
            cases.append((locale, "visionOS", true))
        }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 650), styleMask: [.borderless], backing: .buffered, defer: false)
        window.orderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 35) { print("Popup test timed out"); exit(1) }
        try next()
    }

    private func next() throws {
        guard !cases.isEmpty else { snapshot(); return }
        current = cases.removeFirst()
        let (locale, platform, failure) = current
        let config = WKWebViewConfiguration()
        let messages = try read("Shared (Extension)/Resources/_locales/\(locale)/messages.json")
        let fixture = """
        const messages = \(messages);
        window.browser = {
            i18n: {getMessage: (key, value) => (messages[key]?.message || key).replace('$arg1$', value || ''), getUILanguage: () => '\(locale)'},
            cookies: {getAll() { throw Error('Cookie access is forbidden in a layout test'); }},
            runtime: {sendMessage: async request => {
                await new Promise(resolve => setTimeout(resolve, 30));
                if (request.type === 'nativeStatus') return {ok: true, platform: '\(platform)', photosAuthorization: 'authorized',
                    videoEngine: {available: \(!failure), version: '2026.8.19', error: '\(failure ? String(repeating: "LongDiagnostic", count: 30) : "")'}};
                if (request.type === 'instagramSession') return {ok: true, instagramSession: {hasSession: true}};
                throw Error('Unexpected native request');
            }}
        };
        """
        var script = fixture + (try read("Shared (Extension)/Resources/instagram-session.js"))
        script += "\n(async () => {\n" + (try read("Shared (Extension)/Resources/popup.js"))
            .replacingOccurrences(of: "import \"./instagram-session.js\";", with: "") + "\nwindow.popupReady = true; })();"
        config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 650), configuration: config)
        webView.navigationDelegate = self
        window.contentView = webView
        let html = try read("Shared (Extension)/Resources/popup.html")
            .replacingOccurrences(of: "<link rel=\"stylesheet\" href=\"popup.css\">", with: "<style>" + read("Shared (Extension)/Resources/popup.css") + "</style>")
            .replacingOccurrences(of: "<script type=\"module\" src=\"popup.js\"></script>", with: "")
            .replacingOccurrences(of: "images/icon-96.png", with: "data:image/png;base64," + Data(contentsOf: root.appendingPathComponent("Shared (Extension)/Resources/images/icon-96.png")).base64EncodedString())
        webView.loadHTMLString(html, baseURL: root.appendingPathComponent("Shared (Extension)/Resources/"))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.verify() }
    }

    private func verify() {
        let width = current.1 == "visionOS" ? 480 : 350
        let report = """
        (() => {
            const html = document.documentElement, body = document.body, box = body.getBoundingClientRect();
            const overflow = [...body.querySelectorAll('*')].filter(el => {
                if (!el.getClientRects().length) return false;
                const r = el.getBoundingClientRect();
                return r.left < box.left - 1 || r.right > box.right + 1 || el.scrollWidth > el.clientWidth + 1;
            }).map(el => el.id || el.tagName);
            const buttons = [...document.querySelectorAll('.session-actions button')];
            const spatialButtons = html.dataset.platform !== 'visionOS' || buttons.every(b => b.getBoundingClientRect().height >= 44);
            return {ready: window.popupReady === true, width: html.getBoundingClientRect().width, bodyWidth: box.width,
                iconLoaded: document.querySelector('.mark img').naturalWidth > 0,
                overflow, spatialButtons, scrollable: body.scrollHeight <= body.clientHeight || getComputedStyle(body).overflowY === 'auto'};
        })()
        """
        webView.evaluateJavaScript(report) { result, error in
            guard error == nil, let report = result as? [String: Any], report["ready"] as? Bool == true,
                  report["width"] as? Int == width, report["bodyWidth"] as? Int == width,
                  (report["overflow"] as? [String])?.isEmpty == true, report["spatialButtons"] as? Bool == true,
                  report["iconLoaded"] as? Bool == true,
                  report["scrollable"] as? Bool == true else {
                print("Popup failed \(self.current): \(String(describing: result)) \(String(describing: error))"); exit(1)
            }
            self.count += 1
            print("Popup \(self.current): \(width)px, no horizontal clipping, controls reachable")
            do { try self.next() } catch { print(error); exit(1) }
        }
    }

    private func snapshot() {
        // Render the final spatial popup at its actual preferred width.
        window.setContentSize(NSSize(width: 480, height: 650))
        webView.setFrameSize(NSSize(width: 480, height: 650))
        webView.evaluateJavaScript("document.getElementById('video-status').textContent = 'yt-dlp 2026.8.19'; document.getElementById('video-dot').dataset.status = 'ready';") { _, _ in
            self.webView.takeSnapshot(with: nil) { image, error in
                guard let tiff = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:]) else {
                    print("Snapshot failed \(String(describing: error))"); exit(1)
                }
                do { try png.write(to: self.output) } catch { print(error); exit(1) }
                print("\(self.count) popup WebKit checks passed; snapshot: \(self.output.path)")
                exit(0)
            }
        }
    }
}
