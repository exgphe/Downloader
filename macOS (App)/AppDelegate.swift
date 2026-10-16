//
//  AppDelegate.swift
//  macOS (App)
//
//  Created by Xiaolin Wang on 08/10/2026.
//

import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await DownloadCenter.shared.start() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { DownloadIncomingURL.handle(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

}
