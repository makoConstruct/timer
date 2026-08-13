import Flutter
import UIKit
import UserNotifications

/// iOS counterpart to PlatformNotificationPlugin.kt, serving the same
/// 'platform_notifications' channel.
///
/// There are no notification channels on iOS, so `ensureChannel` does the
/// iOS-only setup (authorization, and the category carrying the dismiss action)
/// and the Dart call site stays as it is.
///
/// `showCompletion` delivers immediately, which only reaches the user if the app
/// is awake at completion time. iOS suspends backgrounded apps, so on the way
/// out `scheduleCompletions` hands over the whole upcoming set at once, and
/// replaces it wholesale each time rather than amending it. — Opus 5
class PlatformNotificationPlugin: NSObject, FlutterPlugin, UNUserNotificationCenterDelegate {
  static let channelName = "platform_notifications"
  static let categoryIdentifier = "makos_timer.completion"
  static let dismissActionIdentifier = "dismiss"

  private static var channels: [FlutterMethodChannel] = []

  /// UNUserNotificationCenter holds its delegate weakly. — Opus 5
  private static var retainedInstance: PlatformNotificationPlugin?

  private var registrar: FlutterPluginRegistrar?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    let instance = PlatformNotificationPlugin()
    instance.registrar = registrar
    registrar.addMethodCallDelegate(instance, channel: channel)
    channels.append(channel)
    retainedInstance = instance
    UNUserNotificationCenter.current().delegate = instance
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "ensureChannel":
      ensureReady()
      result(nil)
    case "showCompletion":
      guard let args = call.arguments as? [String: Any],
        let id = args["id"] as? Int
      else {
        result(FlutterError(code: "BAD_ARGS", message: "id required", details: nil))
        return
      }
      post(
        id: id,
        title: args["title"] as? String ?? "",
        subtitle: args["subtitle"] as? String,
        soundUri: args["soundUri"] as? String,
        after: nil
      )
      result(nil)
    case "scheduleCompletion":
      guard let args = call.arguments as? [String: Any],
        let id = args["id"] as? Int,
        let seconds = args["seconds"] as? Double
      else {
        result(FlutterError(code: "BAD_ARGS", message: "id and seconds required", details: nil))
        return
      }
      post(
        id: id,
        title: args["title"] as? String ?? "",
        subtitle: args["subtitle"] as? String,
        soundUri: args["soundUri"] as? String,
        after: seconds
      )
      result(nil)
    case "scheduleCompletions":
      guard let args = call.arguments as? [String: Any],
        let items = args["items"] as? [[String: Any]]
      else {
        result(FlutterError(code: "BAD_ARGS", message: "items required", details: nil))
        return
      }
      scheduleAll(items)
      result(nil)
    case "pendingCount":
      UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
        DispatchQueue.main.async { result(requests.count) }
      }
    case "requestAuthorization":
      // Kept out of ensureChannel so the one prompt iOS ever gives us is spent
      // when the user makes a timer, not on a launch screen. — Opus 5
      UNUserNotificationCenter.current().requestAuthorization(
        options: [.alert, .sound, .badge]
      ) { granted, error in
        if let error = error {
          NSLog("notification authorization failed: \(error.localizedDescription)")
        }
        DispatchQueue.main.async { result(granted) }
      }
    case "notificationStatus":
      UNUserNotificationCenter.current().getNotificationSettings { settings in
        let status: String
        switch settings.authorizationStatus {
        case .notDetermined: status = "notDetermined"
        case .denied: status = "denied"
        case .authorized: status = "authorized"
        case .provisional: status = "provisional"
        case .ephemeral: status = "ephemeral"
        @unknown default: status = "unknown"
        }
        DispatchQueue.main.async { result(status) }
      }
    case "openSystemSettings":
      guard let url = URL(string: UIApplication.openSettingsURLString) else {
        result(false)
        return
      }
      UIApplication.shared.open(url) { opened in result(opened) }
    case "cancelAll":
      let center = UNUserNotificationCenter.current()
      center.removeAllPendingNotificationRequests()
      center.removeAllDeliveredNotifications()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func ensureReady() {
    let center = UNUserNotificationCenter.current()

    // .customDismissAction is what makes a swipe-away report back to us, and
    // omitting .foreground keeps dismissal from raising the app, matching the
    // broadcast receiver on the Kotlin side. — Opus 5
    let dismiss = UNNotificationAction(
      identifier: Self.dismissActionIdentifier,
      title: "dismiss",
      options: []
    )
    let category = UNNotificationCategory(
      identifier: Self.categoryIdentifier,
      actions: [dismiss],
      intentIdentifiers: [],
      options: [.customDismissAction]
    )
    center.setNotificationCategories([category])
  }

  private func post(
    id: Int,
    title: String,
    subtitle: String?,
    soundUri: String?,
    after: TimeInterval?
  ) {
    // The detail goes in the subtitle rather than the body: it renders in the
    // same weight as the title, directly under it, where a body would be a
    // dimmer third line. — Opus 5
    let content = UNMutableNotificationContent()
    content.title = title
    content.subtitle = subtitle ?? ""
    content.sound = notificationSound(for: soundUri)
    content.categoryIdentifier = Self.categoryIdentifier

    // Carries the alarm through Focus modes. It does not defeat the hardware
    // silent switch — only a critical alert does, and that needs an entitlement
    // Apple has to grant. — Opus 5
    if #available(iOS 15.0, *) {
      content.interruptionLevel = .timeSensitive
    }

    var trigger: UNNotificationTrigger?
    if let after = after {
      trigger = UNTimeIntervalNotificationTrigger(
        timeInterval: max(after, 0.1),
        repeats: false
      )
    }

    let request = UNNotificationRequest(
      identifier: String(id),
      content: content,
      trigger: trigger
    )
    UNUserNotificationCenter.current().add(request) { error in
      if let error = error {
        NSLog("failed to post notification \(id): \(error.localizedDescription)")
      }
    }
  }

  /// Replaces the whole pending set in one go: Dart owns the schedule, and a
  /// cancel-then-add split would leave a window with no alarms pending at all.
  /// — Opus 5
  private func scheduleAll(_ items: [[String: Any]]) {
    let center = UNUserNotificationCenter.current()
    center.removeAllPendingNotificationRequests()

    for item in items {
      guard let identifier = item["identifier"] as? String,
        let seconds = item["seconds"] as? Double
      else { continue }

      let content = UNMutableNotificationContent()
      content.title = item["title"] as? String ?? ""
      content.subtitle = item["subtitle"] as? String ?? ""
      content.sound = notificationSound(for: item["soundUri"] as? String)
      content.categoryIdentifier = Self.categoryIdentifier
      if #available(iOS 15.0, *) {
        content.interruptionLevel = .timeSensitive
      }

      let request = UNNotificationRequest(
        identifier: identifier,
        content: content,
        trigger: UNTimeIntervalNotificationTrigger(
          timeInterval: max(seconds, 0.1),
          repeats: false
        )
      )
      center.add(request) { error in
        if let error = error {
          NSLog("failed to schedule \(identifier): \(error.localizedDescription)")
        }
      }
    }
  }

  /// UNNotificationSound only resolves names against the main bundle and
  /// Library/Sounds, and flutter_assets is neither, so the chosen sound is
  /// copied across on first use. iOS also only accepts PCM in wav/aiff/caf here
  /// — which is why these assets stopped being ogg. — Opus 5
  private func notificationSound(for uri: String?) -> UNNotificationSound {
    guard let uri = uri, uri.hasPrefix("asset://") else { return .default }
    let asset = String(uri.dropFirst("asset://".count))
    guard let key = registrar?.lookupKey(forAsset: asset),
      let source = Bundle.main.path(forResource: key, ofType: nil)
    else {
      NSLog("no bundled asset for \(uri), falling back to the default sound")
      return .default
    }

    let name = (asset as NSString).lastPathComponent
    let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    let sounds = library.appendingPathComponent("Sounds", isDirectory: true)
    let destination = sounds.appendingPathComponent(name)

    if !FileManager.default.fileExists(atPath: destination.path) {
      do {
        try FileManager.default.createDirectory(
          at: sounds,
          withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
          at: URL(fileURLWithPath: source),
          to: destination
        )
      } catch {
        NSLog("could not install \(name) as a notification sound: \(error.localizedDescription)")
        return .default
      }
    }
    return UNNotificationSound(named: UNNotificationSoundName(name))
  }

  private static func dispatch(event: String) {
    DispatchQueue.main.async {
      for channel in channels {
        channel.invokeMethod("notificationEvent", arguments: ["event": event])
      }
    }
  }

  /// Without this iOS suppresses notifications while the app is frontmost,
  /// whereas the Kotlin side posts regardless of app state. — Opus 5
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    if #available(iOS 14.0, *) {
      completionHandler([.banner, .list, .sound])
    } else {
      completionHandler([.alert, .sound])
    }
  }

  /// Event names match the Kotlin side: swipe-away is "dismiss", tap and the
  /// dismiss button are both "action". — Opus 5
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    switch response.actionIdentifier {
    case UNNotificationDismissActionIdentifier:
      Self.dispatch(event: "dismiss")
    default:
      Self.dispatch(event: "action")
    }
    completionHandler()
  }
}
