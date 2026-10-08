import Foundation
import Photos
import WebKit

#if os(macOS)
import Cocoa
import SafariServices
typealias PlatformViewController = NSViewController
#else
import UIKit
typealias PlatformViewController = UIViewController
#endif

private let extensionBundleIdentifier = "wang.xiaolin.Downloader.Extension"

final class ViewController: PlatformViewController, WKNavigationDelegate, WKScriptMessageHandler {
    @IBOutlet var webView: WKWebView!

#if os(visionOS)
    override func loadView() {
        webView = WKWebView(frame: .zero)
        view = webView
    }
#endif

    override func viewDidLoad() {
        super.viewDidLoad()
        webView.navigationDelegate = self
        webView.configuration.userContentController.add(self, name: "controller")
#if os(macOS)
        preferredContentSize = NSSize(width: 620, height: 740)
#else
        webView.scrollView.isScrollEnabled = true
#endif
        guard let page = Bundle.main.url(forResource: "Main", withExtension: "html"),
              let resources = Bundle.main.resourceURL else { return }
        webView.loadFileURL(page, allowingReadAccessTo: resources)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
#if os(macOS)
        webView.evaluateJavaScript("show('mac')", completionHandler: nil)
        SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: extensionBundleIdentifier) { [weak self] state, _ in
            DispatchQueue.main.async {
                guard let self, let state else { return }
                self.webView.evaluateJavaScript("show('mac', \(state.isEnabled))", completionHandler: nil)
            }
        }
#elseif os(visionOS)
        webView.evaluateJavaScript("show('vision')", completionHandler: nil)
#else
        webView.evaluateJavaScript("show('ios')", completionHandler: nil)
#endif
        showPhotosStatus()
    }

    private func showPhotosStatus() {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let value: String
        switch status {
        case .authorized, .limited: value = "authorized"
        case .denied, .restricted: value = "denied"
        case .notDetermined: value = "notDetermined"
        @unknown default: value = "unknown"
        }
        webView.evaluateJavaScript("showPhotosStatus('\(value)')", completionHandler: nil)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              message.frameInfo.request.url?.isFileURL == true,
              let action = message.body as? String else { return }
        switch action {
        case "authorize-photos":
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] _ in
                DispatchQueue.main.async { self?.showPhotosStatus() }
            }
        case "open-preferences":
#if os(macOS)
            SFSafariApplication.showPreferencesForExtension(withIdentifier: extensionBundleIdentifier) { [weak self] error in
                guard let error else { return }
                DispatchQueue.main.async { self?.showError(error.localizedDescription) }
            }
#else
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
#endif
        default: break
        }
    }

    private func showError(_ message: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: [message]),
              let encoded = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("showError(\(encoded)[0])", completionHandler: nil)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if url.isFileURL { decisionHandler(.allow); return }
        decisionHandler(.cancel)
        guard navigationAction.navigationType == .linkActivated,
              url.scheme == "https", ["www.instagram.com", "x.com"].contains(url.host ?? "") else { return }
#if os(macOS)
        NSWorkspace.shared.open(url)
#else
        UIApplication.shared.open(url)
#endif
    }
}
