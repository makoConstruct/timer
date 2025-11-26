# mako's timer

A timer app with optimal ergonomics.

The optimizations:

- Timers are visually compact and color-coded, so users can easily find and reuse timers they need often.

- Every part of the app is laid out to be easily usable one-handed.

- The app pretty much only has one screen, so the user will always be confident that when they open it the app will be in the state they expect.

- Begining to type on the input pad immediately creates a new timer.

- Swiping up on the final numeral starts the new timer, and swiping to the left or right [not quite in yet, about to do that] adds zeroes to the end as well, cutting down the number of keypresses needed sometimes by 4x (*eg, you can create and start a 5 minute timer by just touching 5 and swiping right, while the default google app this would require at least four taps, Create, 5, 00, Play*).

- Most timer apps require the user to pull their phone up and interact with the app after the timer goes off to make it shut up. Sometimes you want this, because it makes absolutely sure that the user heard the timer, and we support it [though that isn't in yet], but in many cases a user is confident that they'll hear the timer when it goes off, and they don't want to be forced to get their phone out of their pocket and interact with it to shut it up, so we provide a "notification" mode that lets the timer shut up on its own.

<!--
maybe explicitly count the interactions to make it clear, we're twice as efficient in general

get
unlock
open
create
first digit
second digit
third digit
start timer
return to pocket
[timer goes off] retreive from pocket
dismiss timer

get
unlock
open
first digit [creates]
second digit
third digit [+ start timer]

// or arguably

create
first digit
second digit
third digit
start timer
return to pocket
[timer goes off] retreive from pocket
dismiss timer

first digit [creates]
second digit
third digit [+ start timer]
-->

Special features:

- Chained timers [this isn't in yet], which are often useful for, say, executing multi-stage cooking processes, and looping timers [also isn't in yet], which can be used in combination with chaining to make pomodoro timers.

<!-- ## donations

There is going to be a donation nag. In this house we believe that societies grow great by incentivizing good actions. Be the incentive you want to see in the world. (accordingly we will be forwarding some portion of the income to the open source projects that made ours possible). -->

<!-- ## contributions

Contributions that are accepted will be compensated if they're substantial enough. -->

<!-- ## audio assets

These are currently not committed, as I haven't decided which ones I want to include.

credit goes mostly to [Kenney](kenney.nl) for the short audio sound effects. -->

## building

<!-- You'll need to fetch those audio assets. -->

`flutter create .`

`flutter pub get` to get build runner

`flutter pub run build_runner build --delete-conflicting-outputs` to build database.g.dart

`flutter run`

### debugging

Whenever you push a change to the device, the foreground task connection will break. You will likely have to force stop the app and restart before the foreground task will connect correctly. This probably has something to do with hot reloading and sendChannels not surviving it, it may also involve the new install automatically booting the old background task code before the new version is installed. Idk, whatever it is, this fixes it, and it doesn't happen in deployment.