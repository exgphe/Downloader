import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

private struct ShareDownloadView: View {
    @ObservedObject var model: ShareDownloadModel
    let close: () -> Void
    @State private var copiedLoginURL = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "arrow.down.circle.fill").font(.title).foregroundColor(.accentColor)
                Text("Download media").font(.title2.bold())
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Close share sheet")
                .help("Close share sheet")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            Divider()
            downloadContent
        }
        .frame(minWidth: 310, idealWidth: 420, minHeight: 300)
    }

    private var downloadContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if model.loading {
                    ProgressView("Reading link…")
                } else if !model.source.isEmpty {
                    Text(model.source).font(.footnote).foregroundColor(.secondary).lineLimit(3).textSelection(.enabled)
                    if model.starting { ProgressView("Starting download…") }
                    if model.starting || model.job.map({ !$0.phase.isFinished }) == true {
                        Text("Keep this sheet open while Downloader reads the link. Downloads can continue in the background. You may need to reopen Downloader to finish processing.")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                }
                if let job = model.job {
                    Text(model.status).font(.body)
                    if !job.phase.isFinished {
                        if let progress = job.progress { ProgressView(value: progress) }
                        else { ProgressView() }
                        Button("Cancel download", role: .destructive, action: model.cancel)
                    } else if job.phase == .failed || job.phase == .cancelled {
                        if needsInstagramLogin(job) { instagramLoginGuide }
                        retryButton
                    }
                }
                if let error = model.error {
                    Text(error).foregroundColor(.red).font(.callout)
                    if model.job == nil && !model.source.isEmpty { retryButton }
                }
            }
            .padding(24)
        }
    }

    private var retryButton: some View {
        Button {
            Task { await model.retry() }
        } label: {
            Label(model.retrying || model.starting ? LocalizedStringKey("Retrying…") : LocalizedStringKey("Retry download"), systemImage: "arrow.clockwise")
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.retrying || model.starting)
    }

    private func needsInstagramLogin(_ job: DownloadJob) -> Bool {
        ["instagram.com", "www.instagram.com"].contains(job.sourceURL.host?.lowercased() ?? "") &&
        ["loginRequired", "invalidInstagramSession", "instagramSessionInvalid", "instagramSessionExpired", "instagramSessionUnavailable"].contains(job.errorCode ?? "")
    }

    private var instagramLoginGuide: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Sync your Instagram login from Safari", systemImage: "person.crop.circle")
                .font(.headline)
            Text("Safari 18 or later is required.")
            Text("1. Open Safari and type instagram.com in the address bar. Sign in using the Safari profile you want to sync.")
            Button(copiedLoginURL ? LocalizedStringKey("Login URL copied") : LocalizedStringKey("Copy login URL")) {
#if os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("https://www.instagram.com/", forType: .string)
#else
                UIPasteboard.general.string = "https://www.instagram.com/"
#endif
                copiedLoginURL = true
            }
            .buttonStyle(.borderless)
            Text("2. Enable Downloader in Safari Extensions and allow it to access instagram.com.")
            Text("3. Open the Downloader popup in Safari and tap Sync Instagram login.")
            Text("4. Return to Downloader or the share panel and retry the download.")
            Text("The synced login is used only for Instagram downloads on this device. Private browsing and other Safari profiles are not included automatically. Sync again after switching accounts or if the login expires.")
                .foregroundColor(.secondary)
        }
        .font(.footnote)
        .fixedSize(horizontal: false, vertical: true)
    }
}

#if os(macOS)
final class ShareViewController: NSViewController {
    private let model = ShareDownloadModel()
    override func loadView() {
        let hosting = NSHostingController(rootView: ShareDownloadView(model: model, close: { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }))
        addChild(hosting)
        view = hosting.view
        preferredContentSize = NSSize(width: 440, height: 380)
        Task { await model.load(extensionContext) }
    }
}
#else
final class ShareViewController: UIViewController {
    private let model = ShareDownloadModel()
    override func viewDidLoad() {
        super.viewDidLoad()
        let hosting = UIHostingController(rootView: ShareDownloadView(model: model, close: { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }))
        addChild(hosting)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        hosting.didMove(toParent: self)
        preferredContentSize = CGSize(width: 440, height: 380)
        Task { await model.load(extensionContext) }
    }
}
#endif
