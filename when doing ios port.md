# Notes for a future iOS port

## Arbitrary sound files as notification alarms

On Android, a user can pick any audio file on their device via the SAF
document picker and have it play when a timer alarm fires. The `AlarmSoundPickerScreen`
shows a "Pick file…" tile on Android only. The content URI is persisted across
app restarts via `takePersistableUriPermission`.

On iOS, notification sounds appear to be restricted: the OS only plays sounds
that are either bundled in the app at build time or copied into the app's
`Library/Sounds` directory, referenced by filename through `UNNotificationSound`.
It is not obvious whether arbitrary user-chosen files from the `Files` app can
be copied in at runtime and then referenced this way — they probably can, since
`Library/Sounds` is just a directory the app owns. Worth investigating before
declaring this feature unavailable on iOS.

If it really does turn out to be impossible: show the user a note in the sound
picker explaining that iOS doesn't allow arbitrary files as alarm sounds, and
that if they don't like it they can message their local MP. (Phrasing tbd.)
