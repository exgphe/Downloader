import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

private struct ShareDownloadView: View {
    @ObservedObject var model: ShareDownloadModel
    @State private var copiedLoginURL = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Image(systemName: "arrow.down.circle.fill").font(.title).foregroundColor(.accentColor)
                    Text("下载媒体").font(.title2.bold())
                    Spacer()
                }
                if model.loading {
                    ProgressView("正在读取链接…")
                } else if !model.source.isEmpty {
                    Text(model.source).font(.footnote).foregroundColor(.secondary).lineLimit(3).textSelection(.enabled)
                    if model.starting { ProgressView("正在开始下载…") }
                    if model.starting || model.job.map({ !$0.phase.isFinished }) == true {
                        Text("解析期间请保持此面板打开。媒体传输可在后台继续；系统限制可能使后续处理需要重新打开 App。")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                }
                if let job = model.job {
                    Text(model.status).font(.body)
                    if !job.phase.isFinished {
                        if let progress = job.progress { ProgressView(value: progress) }
                        else { ProgressView() }
                        Button("取消下载", role: .destructive, action: model.cancel)
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
        .frame(minWidth: 310, idealWidth: 420, minHeight: 300)
    }

    private var retryButton: some View {
        Button {
            Task { await model.retry() }
        } label: {
            Label(model.retrying || model.starting ? "正在重试…" : "重试下载", systemImage: "arrow.clockwise")
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
            Label("请从 Safari 同步 Instagram 登录", systemImage: "person.crop.circle")
                .font(.headline)
            Text("需要 Safari 18 或更高版本。")
            Text("1. 手动打开 Safari，在地址栏输入 instagram.com，并在要同步的 Safari 配置文件中登录。")
            Button(copiedLoginURL ? "登录网址已复制" : "复制登录网址") {
#if os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("https://www.instagram.com/", forType: .string)
#else
                UIPasteboard.general.string = "https://www.instagram.com/"
#endif
                copiedLoginURL = true
            }
            .buttonStyle(.borderless)
            Text("2. 在 Safari 中启用 Downloader，并允许它访问 instagram.com。")
            Text("3. 打开 Safari 的 Downloader 弹窗，点击「同步 Instagram 登录」。")
            Text("4. 返回 Downloader 或分享面板，重新下载。")
            Text("同步的登录仅供本设备下载 Instagram 内容使用。无痕浏览和其他配置文件不会自动包含。切换账号或登录过期后，请重新同步。")
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
        let hosting = NSHostingController(rootView: ShareDownloadView(model: model))
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
        let hosting = UIHostingController(rootView: ShareDownloadView(model: model))
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
