import Foundation
import SafariServices
/// The background script sends one media item per request and owns the post queue.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let request = context.inputItems.first as? NSExtensionItem
        guard let message = request?.userInfo?[SFExtensionMessageKey] as? [String: Any],
              let type = message["type"] as? String else {
            reply(["ok": false, "code": "invalidRequest", "error": "Invalid native message."], to: context)
            return
        }
        if type == "status" {
            reply(["ok": true, "platform": NativePhotoSaver.platform,
                   "photosAuthorization": NativePhotoSaver.authorizationName], to: context)
            return
        }
        guard type == "saveMedia" else {
            reply(["ok": false, "code": "unsupportedRequest", "error": "Unknown native message type."], to: context)
            return
        }
        Task {
            let response: [String: Any]
            do {
                try await NativePhotoSaver.save(NativeMediaRequest(message))
                response = ["ok": true, "saved": 1]
            } catch let failure as MediaSaveError {
                response = ["ok": false, "code": failure.code, "error": failure.message]
            } catch {
                response = ["ok": false, "code": "saveFailed", "error": error.localizedDescription]
            }
            self.reply(response, to: context)
        }
    }

    private func reply(_ message: [String: Any], to context: NSExtensionContext) {
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: message]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}
