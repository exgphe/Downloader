import SwiftUI

@main
struct DownloaderApp: App {
    var body: some Scene {
        WindowGroup {
            DownloadView()
                .frame(minWidth: 500, idealWidth: 620, minHeight: 600, idealHeight: 740)
                .task { await DownloadCenter.shared.start() }
                .onOpenURL { DownloadIncomingURL.handle($0) }
        }
        .defaultSize(width: 620, height: 740)
    }
}
