# mako's timer

A timer app that's roughly (considering all of the factors below) *11 times more ergonomic* than any other timer app, despite also being utterly simple to use. Our optimizations:

- In most timer apps, it takes about 6 taps to make a new timer and start it. In this timer app, it takes just 1 or 2.

- It's designed to fit the hand: every part of the app is easily usable one-handed, even in larger phones. (*Despite the fact that around a decade ago all sides of the industry acknowledged that it's good practice to keep most interactive components of an app in the "thumb zone". Afaik literally no app other than this one has fully followed through on that.*)

- When a timer goes off, most timer apps essentially, repeatedly ask "but did you hear me" over and over again until the user pulls their phone up and unlocks it and interact with the app to acknowledge the alarm. Sometimes you want this, but when you don't need it, it's an inconvenience, so we make it optional, you can have your alarms just make a sound once and then stop. (*As far as we can tell, no other timer app has this.*)

- Timers are visually compact and color-coded, so users can easily find and reuse timers. (*No other timer app has this as far as we're aware.*)

It also has:

- Chained timers, which are often useful for, say, executing multi-stage cooking processes, and looping timers, which can be used in combination with chaining to make pomodoro timers, or any ad-hoc repeating reminder.

- A ludic nature.

<!-- ## donations

There is going to be a donation nag. In this house we believe that societies grow great by incentivizing good actions. Be the incentive you want to see in the world. (accordingly we will be forwarding some portion of the income to the open source projects that made ours possible). -->

## contributing

### our patterns

Things are generally persisted by setting a Mobj, which is a signal that persists the value to a sqlite db whenever it changes. A signal is like a stream but better, as it can be reacted to lazily. Signal.value gets the current value and subscribes to it if called from the builder of a SignalStatefulWidget or SignalBuilder or a Computed evaluator. Signal.peek() gets the value without subscribing. So, peek is mainly for event handlers.

### how we use AI

Some weakly reviewed slop code is acceptable if it's not architectural (eg, platform-specific API glue, ~leaf-code which no other code rests on) but code in `main.dart`, `boring.dart`, is generally expected to be minimal and beautiful, so you'll want to do at least one edit pass before pushing.

We're humanist singularitarians, so we only buy whoever's currently at the top of the [the AI safety index](https://futureoflife.org/ai-safety-index-summer-2026/) and we would ask contributors to do the same if they wouldn't mind.

All of the hundreds of design decisions that were made here (architecture, interaction, theme, style, animations, sound, writing, etc) were made by a human. Claude advised architecture decisions, but mostly just did typing, searching, and debugging.

### compensation

Naturally, if customers see fit to reward us, we will try to pass some of it along to anyone who's made a substantial contribution here. We don't want to exclude anyone from the club. The specifics of how much and when would have to be worked out on a case by case basis though.

## license

It's BSL-1.1(Apache-2.0, non-compete), a fair source license, which means you can use the code for anything as long as it isn't a directly competing project (a timer app). Even that restriction goes away after 4 years, at which point it converts to Apache 2. "mako's timer" and its logo are trademarks of the licensor.

The sound and icon assets are carved out of that license — see [ASSETS.md](ASSETS.md). Though many of them are already under permissive licenses, some are reserved only for distribution along with unmodified builds of the app. If people ever want to fork the old source (but why), we'll have to come up with some new icons and sounds for it.

## Building

`flutter create .` (we don't currently commit most generated flutter files. We want to try staying compatible with whatever the latest template for flutter projects is, so if the build fails with whatever comes out of this command, we want to make it not fail.)

`flutter pub get` to get build runner

`flutter pub run build_runner build --delete-conflicting-outputs` to build database.g.dart

Generate various resources using the gen scripts.

`flutter run`

### Testing

Whenever you push a change to the device, the foreground task connection will break. You will likely have to force stop the app and restart before the foreground task will connect correctly. This probably has something to do with sendChannels not surviving hot reloading, it may also involve the new install automatically booting the old background task code before the new version is installed. Idk, whatever it is, this fixes it, and this issue doesn't occur in deployment.
