// Renders website/index.md into website/out/index.html (the deploy dir).
//
// Run from anywhere:  dart run website/build.dart
// Uses the `markdown` package, already available via pubspec.
import 'dart:io';
import 'package:markdown/markdown.dart' as md;

// --- Edit these as the app gets published ---------------------------------
const appStoreUrl = 'https://apps.apple.com/app/makos-timer/id000000000'; // TODO: real iOS App Store id
const googlePlayUrl =
    'https://play.google.com/store/apps/details?id=org.dreamshrine.makos_timer';
const dreamshrineUrl = 'https://dreamshrine.org';
const pageTitle = "mako's timer";
const pageDescription = 'The most ergonomic timer app. Set and start a timer with a single sweep.';
// ---------------------------------------------------------------------------

void main() {
  final scriptDir = File.fromUri(Platform.script).parent; // website/
  final source = File('${scriptDir.path}/index.md').readAsStringSync();

  final body = md.markdownToHtml(
    source,
    extensionSet: md.ExtensionSet.gitHubWeb,
  );

  final html = '''<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>$pageTitle</title>
  <meta name="description" content="$pageDescription">
  <link rel="icon" href="favicon.ico" sizes="any">
  <link rel="icon" href="favicon.svg" type="image/svg+xml">
  <link rel="apple-touch-icon" href="apple-touch-icon.png">
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter:wght@400;600;700&display=swap">
  <script>
    // Apple-OS users (iOS or macOS, any browser) get the App Store badge
    // only, with a text link to Android below.
    (function () {
      var ua = navigator.userAgent;
      var uad = navigator.userAgentData;
      var isApple =
        /iPhone|iPad|iPod|Macintosh|Mac OS X/.test(ua) ||
        (uad && uad.platform === 'macOS') ||
        (navigator.platform && /^(Mac|iPhone|iPad|iPod)/.test(navigator.platform));
      if (isApple) document.documentElement.classList.add('apple');
    })();
  </script>
  <style>
    :root { color-scheme: light dark; }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font: 17px/1.6 "Inter", -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      color: #1a1a1a;
      background: #faf8f4;
      padding: 2.5rem 1.25rem;
    }
    main { max-width: 42rem; margin: 0 auto; }
    h1 { font-size: 2.2rem; line-height: 1.15; margin: 0 0 1.5rem; }
    a { color: #b4541a; }
    p { margin: 1rem 0; }
    li { margin: 0.5rem 0; }
    em { color: #555; }
    .stores {
      display: flex;
      flex-wrap: wrap;
      gap: 0.75rem;
      align-items: center;
      margin: 2.5rem 0 1.5rem;
    }
    .stores img { height: 52px; width: auto; display: block; }
    .android-text { display: none; font-size: 0.95rem; margin-top: -0.75rem; }
    .apple .stores .play { display: none; }
    .apple .android-text { display: block; }
    footer {
      margin-top: 2rem;
      padding-top: 1.5rem;
      border-top: 1px solid rgba(0,0,0,0.1);
      font-size: 0.95rem;
      color: #555;
    }
    @media (prefers-color-scheme: dark) {
      body { color: #e8e6e2; background: #181614; }
      a { color: #f0935a; }
      em { color: #aaa; }
      footer { border-top-color: rgba(255,255,255,0.12); color: #aaa; }
    }
  </style>
</head>
<body>
  <main>
    <h1>$pageTitle</h1>
$body
    <div class="stores">
      <a href="$appStoreUrl">
        <img src="badges/app-store.svg" alt="Download on the App Store">
      </a>
      <a class="play" href="$googlePlayUrl">
        <img src="badges/google-play.svg" alt="Get it on Google Play">
      </a>
    </div>
    <p class="android-text">An <a href="$googlePlayUrl">Android version</a> is also available.</p>
    <footer>
      <a href="$dreamshrineUrl">dreamshrine.org</a>
    </footer>
  </main>
</body>
</html>
''';

  final out = File('${scriptDir.path}/out/index.html');
  out.parent.createSync(recursive: true);
  out.writeAsStringSync(html);
  stdout.writeln('Wrote ${out.path} (${html.length} bytes)');
}
