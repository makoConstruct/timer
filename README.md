# mako's timer

A timer app that's roughly 20 times more ergonomic than any other timer app. Our optimizations:

- In most timer apps, it takes about 6 keypresses to make a new timer and start it. In this timer app, it takes just 1 or 2.

- Every part of the app is easily usable one-handed. (*No other timer app is like this. Despite it being acknowledged by all sides of the industry around 2016 that it's good practice to keep most interactive components of an app in "the thumb zone". Afaik literally no app other than this one has fully implemented that.*)

- When a timer goes off, most timer apps require the user to pull their phone up and unlock it and interact with the app and physically acknowledge the alarm before it will shut up. Sometimes you want this, because it makes absolutely sure that you heard the alarm, and we do have that as an option, but if you don't need that, it's a really annoying behavior, so by default, you don't have to do that here.

- Timers are visually compact and color-coded, so users can easily find and reuse timers. (*No other timer app has this as far as we're aware.*)

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

- Has games. [only one so far (it's small and horrible, but also unique)] (*No other timer app has games.*)

<!-- ## donations

There is going to be a donation nag. In this house we believe that societies grow great by incentivizing good actions. Be the incentive you want to see in the world. (accordingly we will be forwarding some portion of the income to the open source projects that made ours possible). -->

<!-- ## contributions

Contributions that are accepted will be compensated if they're substantial enough. -->

<!-- ## audio assets

These are currently not committed, as I haven't decided which ones I want to include.

credit goes mostly to [Kenney](kenney.nl) for the short audio sound effects. -->

## License

It's BSL-1.1(Apache-2.0, non-compete), a fair use license, which means you can use the code for anything as long as it isn't a directly competing project (a timer app). Even that restriction goes away after 4 years, at which point it converts to Apache 2. 

## building

<!-- You'll need to fetch those audio assets. -->

`flutter create .`

`flutter pub get` to get build runner

`flutter pub run build_runner build --delete-conflicting-outputs` to build database.g.dart

`flutter run`

### testing

Whenever you push a change to the device, the foreground task connection will break. You will likely have to force stop the app and restart before the foreground task will connect correctly. This probably has something to do with sendChannels not surviving hot reloading, it may also involve the new install automatically booting the old background task code before the new version is installed. Idk, whatever it is, this fixes it, and this issue doesn't occur in deployment.