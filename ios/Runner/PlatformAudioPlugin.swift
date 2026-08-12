import AVFoundation
import AudioToolbox
import Flutter
import UIKit

/// iOS counterpart to PlatformAudioPlugin.kt, serving the 'platform_audio'
/// channel.
///
/// iOS exposes no way to enumerate or address the device's own ringtones and
/// alarm sounds, so `getPlatformAudio` is empty here and the picker's "Device
/// ringtones" sections don't render. A null uri means the category default,
/// which is the closest iOS equivalent: one of the undocumented-but-stable
/// SystemSoundIDs. — Opus 5
class PlatformAudioPlugin: NSObject, FlutterPlugin {
  static let channelName = "platform_audio"

  private var registrar: FlutterPluginRegistrar?
  private var player: AVAudioPlayer?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    let instance = PlatformAudioPlugin()
    instance.registrar = registrar
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]

    switch call.method {
    case "getPlatformAudio":
      result([])
    case "getDefaultAudio":
      result(defaultAudio(for: args?["type"] as? String))
    case "playAudio":
      play(uri: args?["uri"] as? String, looping: false)
      result(nil)
    case "playAudioLooping":
      play(uri: args?["uri"] as? String, looping: true)
      result(nil)
    case "pauseAudio":
      player?.pause()
      result(nil)
    case "stopAudio":
      player?.stop()
      player = nil
      deactivateSession()
      result(nil)
    case "pickAudioFile":
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func defaultAudio(for type: String?) -> [String: Any?] {
    switch type {
    case "ringtone":
      return ["uri": nil, "name": "Default Ringtone", "isLong": true]
    case "alarm":
      return ["uri": nil, "name": "Default Alarm", "isLong": true]
    default:
      return ["uri": nil, "name": "Default Notification", "isLong": false]
    }
  }

  /// .playback is what lets an alarm sound through the silent switch while the
  /// app is frontmost. It says nothing about backgrounded alarms, which are the
  /// notification's job. — Opus 5
  private func activateSession() {
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback)
      try AVAudioSession.sharedInstance().setActive(true)
    } catch {
      NSLog("audio session activation failed: \(error.localizedDescription)")
    }
  }

  private func deactivateSession() {
    try? AVAudioSession.sharedInstance().setActive(
      false,
      options: .notifyOthersOnDeactivation
    )
  }

  private func play(uri: String?, looping: Bool) {
    player?.stop()
    player = nil

    guard let uri = uri else {
      // 1005 is the system alarm sound. AudioServices ignores the looping
      // request; a category default is a one-shot here. — Opus 5
      AudioServicesPlaySystemSound(SystemSoundID(1005))
      return
    }

    guard let url = resolve(uri: uri) else {
      NSLog("could not resolve audio uri: \(uri)")
      return
    }

    activateSession()
    do {
      let p = try AVAudioPlayer(contentsOf: url)
      p.numberOfLoops = looping ? -1 : 0
      p.prepareToPlay()
      p.play()
      player = p
    } catch {
      // AVFoundation has no Ogg Vorbis decoder, so every asset still shipping
      // as .ogg lands here. — Opus 5
      NSLog("failed to play \(uri): \(error.localizedDescription)")
    }
  }

  private func resolve(uri: String) -> URL? {
    if uri.hasPrefix("asset://") {
      let asset = String(uri.dropFirst("asset://".count))
      guard let key = registrar?.lookupKey(forAsset: asset),
        let path = Bundle.main.path(forResource: key, ofType: nil)
      else { return nil }
      return URL(fileURLWithPath: path)
    }
    if uri.hasPrefix("file://") || uri.hasPrefix("http://")
      || uri.hasPrefix("https://")
    {
      return URL(string: uri)
    }
    return URL(fileURLWithPath: uri)
  }
}
