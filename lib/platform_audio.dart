import 'package:flutter/services.dart';

enum PlatformAudioType {
  ringtone,
  notification,
  alarm,
}

class AudioInfo {
  /// a null uri means "use the default for the given category"
  final String? uri;
  final String name;
  final bool isLong;

  const AudioInfo({
    required this.uri,
    required this.name,
    required this.isLong,
  });

  static const defaultRingtone =
      AudioInfo(uri: null, name: 'Default Ringtone', isLong: true);
  static const defaultNotification =
      AudioInfo(uri: null, name: 'Default Notification', isLong: false);
  static const defaultAlarm =
      AudioInfo(uri: null, name: 'Default Alarm', isLong: true);

  factory AudioInfo.fromMap(Map<dynamic, dynamic> map) {
    return AudioInfo(
      uri: map['uri'] as String?,
      name: map['name'] as String,
      isLong: map['isLong'] as bool,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'uri': uri,
      'name': name,
      'isLong': isLong,
    };
  }
}

class PlatformAudio {
  static const MethodChannel _channel = MethodChannel('platform_audio');

  static Future<List<AudioInfo>> getPlatformAudio(
      PlatformAudioType type) async {
    try {
      final String typeString = type.name;
      final List<dynamic> result = await _channel.invokeMethod(
        'getPlatformAudio',
        {'type': typeString},
      );

      return result.map((item) => AudioInfo.fromMap(item)).toList();
    } on PlatformException catch (e) {
      throw Exception('Failed to get platform audio: ${e.message}');
    }
  }

  static Future<AudioInfo?> getDefaultAudio(PlatformAudioType type) async {
    try {
      final String typeString = type.name;
      final Map<dynamic, dynamic>? result = await _channel.invokeMethod(
        'getDefaultAudio',
        {'type': typeString},
      );

      if (result == null) return null;
      return AudioInfo.fromMap(result);
    } on PlatformException catch (e) {
      throw Exception('Failed to get default audio: ${e.message}');
    }
  }

  static Future<void> playAudio(AudioInfo a) async {
    try {
      await _channel.invokeMethod('playAudio', {'uri': a.uri});
    } on PlatformException catch (e) {
      throw Exception('Failed to play audio: ${e.message}');
    }
  }

  static Future<void> pauseAudio() async {
    try {
      await _channel.invokeMethod('pauseAudio');
    } on PlatformException catch (e) {
      throw Exception('Failed to pause audio: ${e.message}');
    }
  }

  static Future<void> playAudioUri(String uri) async {
    try {
      await _channel.invokeMethod('playAudio', {'uri': uri});
    } on PlatformException catch (e) {
      throw Exception('Failed to play audio: ${e.message}');
    }
  }

  static Future<void> stopAudio() async {
    try {
      await _channel.invokeMethod('stopAudio');
    } on PlatformException catch (e) {
      throw Exception('Failed to stop audio: ${e.message}');
    }
  }

  static const List<AudioInfo> assetSounds = [
    AudioInfo(
        uri: 'asset://assets/sounds/june_russel_mako_timer_e-piano_1.ogg',
        name: 'JR - Announcement',
        isLong: false),
    AudioInfo(
        uri: 'asset://assets/sounds/jingles_STEEL16.ogg',
        name: 'Steel Jingle 16',
        isLong: false),
  ];
}
