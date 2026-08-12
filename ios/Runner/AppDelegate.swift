import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Our own plugins aren't in GeneratedPluginRegistrant, which only covers
    // pub packages. — Claude Opus 5
    PlatformNotificationPlugin.register(
      with: engineBridge.pluginRegistry.registrar(forPlugin: "PlatformNotificationPlugin")!)
    PlatformAudioPlugin.register(
      with: engineBridge.pluginRegistry.registrar(forPlugin: "PlatformAudioPlugin")!)
  }
}
