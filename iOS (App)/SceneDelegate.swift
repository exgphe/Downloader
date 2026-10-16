//
//  SceneDelegate.swift
//  iOS (App)
//
//  Created by Xiaolin Wang on 08/10/2026.
//

import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let _ = (scene as? UIWindowScene) else { return }
        for context in connectionOptions.urlContexts { DownloadIncomingURL.handle(context.url) }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts { DownloadIncomingURL.handle(context.url) }
    }

}
