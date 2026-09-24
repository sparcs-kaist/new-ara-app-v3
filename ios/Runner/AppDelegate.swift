import UIKit
import Flutter

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
  private var keyboardObservers: [NSObjectProtocol] = []

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(name: "ara/keyboard", binaryMessenger: controller.binaryMessenger)
      let send = { (note: Notification, visible: Bool) in
        let info = note.userInfo ?? [:]
        let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0
        var height = 0.0
        if visible, let frame = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue {
          height = Double(max(0, UIScreen.main.bounds.height - frame.origin.y))
        }
        let args: [String: Any] = [
          "height": height, "visible": visible, "durationMs": Int(duration * 1000), "curve": "ios",
        ]
        channel.invokeMethod("changed", arguments: args)
      }
      let center = NotificationCenter.default
      keyboardObservers = [
        center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { send($0, true) },
        center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { send($0, false) },
      ]
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
