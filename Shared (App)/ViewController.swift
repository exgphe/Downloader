import SwiftUI
import WebKit

#if os(macOS)
import Cocoa
typealias PlatformViewController = NSViewController
#else
import UIKit
typealias PlatformViewController = UIViewController
#endif

/// Keeps the storyboard entry points while hosting the same native UI on both
/// platforms. The outlet is retained for the existing storyboard layouts.
final class ViewController: PlatformViewController {
    @IBOutlet private weak var webView: WKWebView?

    override func viewDidLoad() {
        super.viewDidLoad()
        webView?.removeFromSuperview()

#if os(macOS)
        let hosting = NSHostingController(rootView: DownloadView())
        preferredContentSize = NSSize(width: 620, height: 740)
        addChild(hosting)
        view.addSubview(hosting.view)
#else
        let hosting = UIHostingController(rootView: DownloadView())
        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
#endif
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
}
