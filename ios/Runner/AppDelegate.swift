import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var platformBridge: ShiriPlatformBridge?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      platformBridge = ShiriPlatformBridge(messenger: controller.binaryMessenger) { [weak self] in
        var presenter = self?.window?.rootViewController
        while let presented = presenter?.presentedViewController { presenter = presented }
        return presenter
      }
      if let url = launchOptions?[.url] as? URL { _ = platformBridge?.receive(url: url, cold: true) }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    if platformBridge?.receive(url: url) == true { return true }
    return super.application(app, open: url, options: options)
  }
}
