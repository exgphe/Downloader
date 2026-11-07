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
                   "photosAuthorization": NativePhotoSaver.authorizationName,
                   "videoEngine": EmbeddedVideoResolver.status], to: context)
            return
        }
        if ["instagramSession", "importInstagramSession", "clearInstagramSession"].contains(type) {
            do {
                let status: InstagramSessionStatus
                if type == "importInstagramSession" {
                    guard let cookies = message["cookies"] as? [Any] else {
                        throw InstagramSessionValidation.invalid
                    }
                    status = try InstagramSessionStore.importCookies(cookies)
                } else {
                    if type == "clearInstagramSession" { try InstagramSessionStore.clear() }
                    status = InstagramSessionStore.status()
                }
                reply(["ok": true, "instagramSession": status.nativeMessage], to: context)
            } catch let failure as MediaSaveError {
                reply(["ok": false, "code": failure.code, "error": failure.message], to: context)
            } catch {
                reply(["ok": false, "code": "instagramSessionUnavailable", "error": "The Instagram session could not be synced. Try again from the Downloader extension."], to: context)
            }
            return
        }
        if type == "resolveStory" {
            guard let address = message["postURL"] as? String,
                  let postURL = NativeMediaRequest.postURL(address),
                  let identifier = NativeMediaRequest.instagramStoryID(postURL) else {
                reply(["ok": false, "code": "invalidPost", "error": "Provide an Instagram Story link with its media ID."], to: context)
                return
            }
            Task {
                do {
                    let manifest = try await EmbeddedMediaResolver.resolve(sourceURL: postURL, destination: .photos)
                    guard manifest.media.count == 1, let item = manifest.media.first, item.id == identifier,
                          item.streams.count == 1, let stream = item.streams.first,
                          MediaURLPolicy().allows(stream.url) else {
                        throw MediaSaveError(code: "invalidStoryResult", message: "The built-in media engine returned an invalid Story media item.")
                    }
                    self.reply(["ok": true, "media": [["url": stream.url.absoluteString,
                               "kind": item.kind.rawValue, "filename": item.filename]]], to: context)
                } catch let failure as MediaSaveError {
                    self.reply(["ok": false, "code": failure.code, "error": failure.message], to: context)
                } catch {
                    self.reply(["ok": false, "code": "storyResolutionFailed", "error": "The Instagram Story could not be resolved. Sync your Instagram login and try again."], to: context)
                }
            }
            return
        }
        if type == "resolvePost" {
            guard let address = message["postURL"] as? String,
                  let postURL = NativeMediaRequest.postURL(address) else {
                reply(["ok": false, "code": "invalidPost", "error": "Provide a supported Instagram or X post URL."], to: context)
                return
            }
            Task {
                do {
                    let media = try await EmbeddedVideoResolver.resolve(postURL: postURL)
                    guard !media.isEmpty, media.count <= 20,
                          media.allSatisfy({ item in
                              guard item["kind"] as? String == "video", let address = item["url"] as? String,
                                    let url = URL(string: address) else { return false }
                              return MediaURLPolicy().allows(url)
                          }) else {
                        throw MediaSaveError(code: "invalidVideoResult", message: "The built-in video engine returned an unsupported media location.")
                    }
                    self.reply(["ok": true, "media": media], to: context)
                } catch let failure as MediaSaveError {
                    self.reply(["ok": false, "code": failure.code, "error": failure.message], to: context)
                } catch {
                    self.reply(["ok": false, "code": "videoResolutionFailed", "error": error.localizedDescription], to: context)
                }
            }
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
