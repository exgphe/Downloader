import SwiftUI

@main
struct DownloaderApp: App {
    var body: some Scene {
        WindowGroup {
            SetupView()
                .frame(minWidth: 500, idealWidth: 620, minHeight: 650, idealHeight: 780)
        }
        .defaultSize(width: 620, height: 780)
    }
}

private struct SetupView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> ViewController { ViewController() }
    func updateUIViewController(_ uiViewController: ViewController, context: Context) {}
}
