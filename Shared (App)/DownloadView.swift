import SwiftUI

#if os(macOS)
import AppKit
import SafariServices
#else
import UIKit
#endif

@MainActor
struct DownloadView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var center = DownloadCenter.shared
    @State private var link = ""
    @AppStorage("downloadDestination") private var destination: DownloadDestination = .photos
    @State private var submitting = false
    @State private var interfaceError: String?
    @State private var instagramSession: InstagramSessionStatus?
    @State private var showingInstagramGuide = false
#if os(macOS)
    @State private var extensionEnabled: Bool?
#endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                downloadForm
                taskList
                instagramLogin
                safariSettings
            }
            .frame(maxWidth: 620)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(pageBackground)
#if os(macOS)
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                refreshInstagramSession()
                Task { await center.recoverBackgroundTransfers() }
            }
        }
#else
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                refreshInstagramSession()
                Task { await center.recoverBackgroundTransfers() }
            }
        }
#endif
        .alert("Unable to download", isPresented: Binding(
            get: { interfaceError != nil },
            set: { if !$0 { interfaceError = nil } }
        )) {
            Button("OK", role: .cancel) { interfaceError = nil }
        } message: {
            Text(interfaceError ?? "")
        }
        .sheet(isPresented: $showingInstagramGuide) { InstagramLoginGuide() }
        .task {
            refreshInstagramSession()
#if os(macOS)
            extensionEnabled = (try? await SFSafariExtensionManager.stateOfSafariExtension(withIdentifier: "wang.xiaolin.Downloader.Extension"))?.isEnabled
#endif
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Downloader").font(.title2.weight(.semibold))
                Text("Keep videos and photos on your device.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var downloadForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Post or video link").font(.headline)
                TextField("YouTube, Instagram, or X URL", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { startDownload() }
#if !os(macOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
#endif
            }
            Picker("Save to", selection: $destination) {
                Text("Photos").tag(DownloadDestination.photos)
                Text("Files").tag(DownloadDestination.files)
            }
            .pickerStyle(.segmented)
            Text(destination == .photos
                 ? LocalizedStringKey("Best quality compatible with Photos.")
                 : LocalizedStringKey("Best source quality, including formats such as VP9 and AV1."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: startDownload) {
                Label("Download", systemImage: "arrow.down")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .disabled(submitting || link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(18)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var taskList: some View {
        if center.jobs.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray").font(.title2).accessibilityHidden(true)
                Text("Your downloads will appear here.").font(.subheadline)
                Text("You can also send a link from the system share menu.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("Downloads").font(.headline)
                ForEach(center.jobs) { job in
                    DownloadJobView(job: job, center: center, onLoginGuide: { showingInstagramGuide = true })
                }
            }
        }
    }

    private var instagramLogin: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Instagram login", systemImage: "person.crop.circle")
                .font(.subheadline.weight(.semibold))
            Text(instagramStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let importedAt = instagramSession?.importedAt {
                HStack(spacing: 4) {
                    Text("Last synced:")
                    Text(importedAt, style: .date)
                    Text(importedAt, style: .time)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let error = instagramSession?.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Use your Safari login for Instagram downloads on this device.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Button("How to sync login") { showingInstagramGuide = true }
                Button("Clear synced login", role: .destructive) {
                    do {
                        try InstagramSessionStore.clear()
                        refreshInstagramSession()
                    } catch { interfaceError = error.localizedDescription }
                }
            }
            .buttonStyle(.borderless)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 16))
    }

    private func refreshInstagramSession() {
        instagramSession = InstagramSessionStore.status()
    }

    private var instagramStatusText: LocalizedStringKey {
        if instagramSession?.errorMessage != nil { return "Could not read synced login" }
        return instagramSession?.hasSession == true ? "Login synced to this device" : "Login has not been synced"
    }

    private var safariSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Safari extension").font(.subheadline.weight(.semibold))
            Text("Download Instagram posts and X videos directly in Safari.")
                .font(.caption)
                .foregroundStyle(.secondary)
#if os(macOS)
            if extensionEnabled == true {
                Label("Enabled in Safari", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
#else
            Text("Enable Downloader in Settings → Apps → Safari → Extensions.")
                .font(.caption)
                .foregroundStyle(.secondary)
#endif
            Button("Open Safari extension settings", action: openSettings)
#if os(macOS)
                .buttonStyle(.link)
#else
                .buttonStyle(.borderless)
#endif
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func startDownload() {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !submitting else { return }
        submitting = true
        let selectedDestination = destination
        Task {
            defer { submitting = false }
            do {
                _ = try await center.enqueue(text, destination: selectedDestination)
                if link.trimmingCharacters(in: .whitespacesAndNewlines) == text { link = "" }
            } catch {
                interfaceError = error.localizedDescription
            }
        }
    }

    private func openSettings() {
#if os(macOS)
        SFSafariApplication.showPreferencesForExtension(withIdentifier: "wang.xiaolin.Downloader.Extension") { error in
            if let error { Task { @MainActor in interfaceError = error.localizedDescription } }
        }
#else
        if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(settingsURL)
        }
#endif
    }
}

@MainActor
private struct DownloadJobView: View {
    let job: DownloadJob
    @ObservedObject var center: DownloadCenter
    let onLoginGuide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.title.isEmpty ? job.sourceURL.host ?? "Download" : job.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Text(job.sourceURL.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if active {
                    Button("Cancel") { center.cancel(job.id) }
                        .buttonStyle(.borderless)
                } else if job.phase == .failed || job.phase == .cancelled {
                    Button("Retry") { Task { await center.retry(job.id) } }
                        .buttonStyle(.borderless)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: statusSymbol).accessibilityHidden(true)
                Text(statusText)
                Spacer(minLength: 0)
                if active, let progress = job.progress {
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(job.phase == .failed ? Color.red : Color.secondary)
            if active {
                if let progress = job.progress {
                    ProgressView(value: min(max(progress, 0), 1))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            if let error = job.error, job.phase == .failed {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if job.phase == .failed, needsInstagramLogin {
                Text("Sync your Instagram login from Safari, then retry this download.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("How to sync login", action: onLoginGuide)
                    .buttonStyle(.borderless)
            }
            if job.phase == .completed, !job.outputFiles.isEmpty {
                HStack(spacing: 16) {
                    ExportFilesButton(files: job.outputFiles)
                    ShareFilesButton(files: job.outputFiles)
                }
            }
        }
        .padding(16)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }

    private var needsInstagramLogin: Bool {
        ["instagram.com", "www.instagram.com"].contains(job.sourceURL.host?.lowercased() ?? "") &&
        ["loginRequired", "invalidInstagramSession", "instagramSessionInvalid", "instagramSessionExpired", "instagramSessionUnavailable"].contains(job.errorCode ?? "")
    }

    private var active: Bool {
        switch job.phase {
        case .queued, .resolving, .downloading, .saving: return true
        case .completed, .failed, .cancelled: return false
        }
    }

    private var statusText: LocalizedStringKey {
        switch job.phase {
        case .queued: return "Queued"
        case .resolving: return "Finding the best media…"
        case .downloading: return "Downloading…"
        case .saving: return job.destination == .photos ? "Saving to Photos…" : "Preparing files…"
        case .completed: return job.destination == .photos ? "Saved to Photos" : "Downloaded to Files"
        case .failed: return "Download failed"
        case .cancelled: return "Cancelled"
        }
    }

    private var statusSymbol: String {
        switch job.phase {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle"
        case .cancelled: return "xmark.circle"
        default: return "arrow.down.circle"
        }
    }
}

@MainActor
private struct InstagramLoginGuide: View {
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Sync Instagram login").font(.title2.weight(.semibold))
                    Spacer()
                    Button("Done") { dismiss() }
                }
                Text("Safari 18 or later is required.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("1. Open Safari and type instagram.com in the address bar. Sign in using the Safari profile you want to sync.")
                Button(copied ? LocalizedStringKey("Login URL copied") : LocalizedStringKey("Copy login URL")) {
#if os(macOS)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("https://www.instagram.com/", forType: .string)
#else
                    UIPasteboard.general.string = "https://www.instagram.com/"
#endif
                    copied = true
                }
                .buttonStyle(.borderless)
                Text("2. Enable Downloader in Safari Extensions and allow it to access instagram.com.")
                Text("3. Open the Downloader popup in Safari and tap Sync Instagram login.")
                Text("4. Return to Downloader or the share panel and retry the download.")
                Text("The synced login is used only for Instagram downloads on this device. Private browsing and other Safari profiles are not included automatically. Sync again after switching accounts or if the login expires.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(24)
        }
#if os(macOS)
        .frame(minWidth: 380, idealWidth: 520, minHeight: 440)
#endif
    }
}

@MainActor
private struct ExportFilesButton: View {
    let files: [URL]
    @State private var exporting = false
    @State private var exportError: String?
    @State private var exported = false
#if !os(macOS)
    @State private var showingExporter = false
#endif

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: exportFiles) {
                Label(exporting ? LocalizedStringKey("Saving files…") : LocalizedStringKey("Save files…"), systemImage: "folder")
            }
            .buttonStyle(.borderless)
            .disabled(exporting)
            if exported {
                Label("Files saved", systemImage: "checkmark")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .alert("Unable to save files", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: { Text(exportError ?? "") }
#if !os(macOS)
        .sheet(isPresented: $showingExporter) {
            DocumentExporter(files: files, onComplete: {
                showingExporter = false
                exported = true
            }, onCancel: { showingExporter = false })
        }
#endif
    }

    private func exportFiles() {
#if os(macOS)
        let panel = NSOpenPanel()
        panel.title = NSLocalizedString("Choose a destination folder", comment: "Download export folder")
        panel.prompt = NSLocalizedString("Save", comment: "Save downloaded files")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { result in
            guard result == .OK, let folder = panel.url else { return }
            exporting = true
            Task {
                defer { exporting = false }
                do {
                    let sourceFiles = files
                    try await Task.detached(priority: .userInitiated) {
                        let scoped = folder.startAccessingSecurityScopedResource()
                        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
                        for source in sourceFiles {
                            var target = folder.appendingPathComponent(source.lastPathComponent)
                            var index = 2
                            while FileManager.default.fileExists(atPath: target.path) {
                                let basename = source.deletingPathExtension().lastPathComponent
                                let suffix = source.pathExtension.isEmpty ? "" : "." + source.pathExtension
                                target = folder.appendingPathComponent("\(basename) \(index)\(suffix)")
                                index += 1
                            }
                            try FileManager.default.copyItem(at: source, to: target)
                        }
                    }.value
                    exported = true
                } catch { exportError = error.localizedDescription }
            }
        }
#else
        showingExporter = true
#endif
    }
}

#if !os(macOS)
private struct DocumentExporter: UIViewControllerRepresentable {
    let files: [URL]
    var onComplete: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onComplete: onComplete, onCancel: onCancel) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: files, asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onComplete: () -> Void
        let onCancel: () -> Void
        init(onComplete: @escaping () -> Void, onCancel: @escaping () -> Void) {
            self.onComplete = onComplete
            self.onCancel = onCancel
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onComplete() }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onCancel() }
    }
}
#endif

@MainActor
private struct ShareFilesButton: View {
    let files: [URL]

    var body: some View {
#if os(macOS)
        if #available(macOS 13.0, *) {
            ShareLink(items: files) { Label("Share files", systemImage: "square.and.arrow.up") }
                .buttonStyle(.borderless)
        } else {
            LegacyShareButton(files: files).frame(height: 24)
        }
#else
        ShareLink(items: files) { Label("Share files", systemImage: "square.and.arrow.up") }
            .buttonStyle(.borderless)
#endif
    }
}

#if os(macOS)
private struct LegacyShareButton: NSViewRepresentable {
    let files: [URL]

    func makeCoordinator() -> Coordinator { Coordinator(files: files) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: NSLocalizedString("Share files", comment: "Share downloaded media"),
                              target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.bezelStyle = .rounded
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) { context.coordinator.files = files }

    final class Coordinator: NSObject {
        var files: [URL]
        init(files: [URL]) { self.files = files }

        @objc func share(_ sender: NSButton) {
            NSSharingServicePicker(items: files).show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}
#endif

private var pageBackground: Color {
#if os(macOS)
    Color(nsColor: .windowBackgroundColor)
#else
    Color(uiColor: .systemGroupedBackground)
#endif
}

private var cardBackground: Color {
#if os(macOS)
    Color(nsColor: .controlBackgroundColor)
#else
    Color(uiColor: .secondarySystemGroupedBackground)
#endif
}
