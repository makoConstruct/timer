## Just One Motion

Initially, the interface was just one big dial.

I started with an intuition that it ought to be possible to create, set, and start a timer with just one interaction. You'd simply turn the dial until you had the number you wanted, and you'd release it, and then it would start winding back, and when it hit 0 the timer would sound.

That intuition was right, but through other means. It seemed like there was no way to make the dial feel good. Under the simplest approach, you'd usually land one to three seconds off from the exact time that you wanted, which wouldn't matter on a practical level, but it felt horrible. The timer would be *wrong*, not quite the timer you wanted, and you'd feel the pressure of its wrongness hanging over you.

I could make the dial clicky, limit it to 30 second increments, but then we'd lose the analog qualities that made a dial interesting to begin with.

So I came to appreciate the digital precision of the number pad. I then noticed some optimizations I could apply to a numpad. First came the upward drag to launch, which brought us down to about two interactions per median timer-creation. Then came dragging left, to add two zeroes and launch, which brought it down to about one interaction. At this point, I was excited about the design.

## Tribulations

At one point, morale was severely under threat. None of my friends believed in me. My cook friend from auckland told me that he would not and could not use a phone app timer in his kitchen due to aerosol grease, and due to the fact that he already had a bunch of physical timers. A designer friend from wellington, frustrated that I was allowing timer app to distract me from our admittedly much more important project of building a better web, threatened to ship me thirty physical "chook timers", which are a certain kind of egg-shaped timer that you can twist and release, which I would then be forced to appreciate the neatness and adequacy of. There was a real risk that if they had done this, they would have sated my hunger for timer, and I never would have completed the app.

There were other morale challenges. Flutter, the UI framework this app was built on, was in many ways incomplete. But I'd become familiar enough with flutter to know that I'd be able to complete it. Uniquely among UI frameworks, flutter is simple enough to be understood, and flexible enough to be fixed.

## General Automatic Animation of Layout

No UI framework has a robust approach to the automatic animation of positioning and sizing. I had to develop the very first one.

At the center of the app is a "Wrap" container widget. A wrap takes many widgets, in our case, the timers, and arranges them in a flow, in the same way that a paragraph arranges its words, from left to right in lines and the lines go from top to bottom, or you can flip it so that the lines go up instead of down, or so that they flow from right to left, or it can all be rotated by 90 degrees, and the lines can be aligned with the start or the end, or evenly spread over the page, and they can be splayed or bunched up at the end. (In our case, all we did was flip the line direction to right to left, or not, depending on whether you're right handed). So, a Wrap widget is somewhat complex. Which means that when you add or remove a timer, sometimes the layout can change in somewhat surprising ways, you might not be able to visually understand what happened, especially when wraps are being nested.

But if you animate the layout change, it becomes immediately visually comprehensible. The human visual system can easily track how things have moved around.

I began this journey by going in the wrong direction, by building a special "Wrap" container widget that animates its layout changes automatically when items are added, removed, or reordered. I later realized that I also wanted timers to be draggable, and to animate nicely when dragged, and an animated container couldn't help with animating anything that happened outside of it.

So I considered using animated_to, which animates *all* movement, by checking for screenspace position changes, at paint time. After much reflection, I came to the conclusion that the solution to layout animation is going to look more like animated_to than my animated_containers. It hadn't been a complete waste to make my own special Wrap container, though, as this made it easy for me to introduce the `InsertionPoint insertionOf(GlobalKey<IWrap> key, Offset globalOffset)` function, which you need for drag and drop. What it does is, given a mouse position offset (`globalOffset`), it tells you which item within the wrap (with the wrap specified by `key`) your mouse is closest to (and whether you're in front of or behind it), roughly speaking (It's a bit more intelligent than "closest to". In fact it turned out that just returning the closest item felt weird and confusing.)

There was an embarrassing moment where I reimplemented my own spin on animated_to ("animover") in order to add "AnimoveFrames", which you'd put around, say, a scroll view, which would make it possible to scroll a tray of animated widgets without them animating prematurely and lagging behind the scroll. And then when I assembled a comparison test app, it turned out that AnimatedTo actually already had such a thing (which they called "AnimatedToBoundary").

My embarrassment was swiftly exorcised from me, shortly later, again, when I realised that AnimatedTo actually didn't have frames last time I'd evaluated it, so it wasn't such a big mistake. The exorcism was completed when I noticed certain severe bugs in AnimatedTo that made transfers between frames look awful, which I found easier to solve in my own version. I also came up with RanimatedContainer. While AnimatedTo-likes animate position changes, RanimatedContainer animates the remaining part of layout change, the size changes.

At that, a general solution had been found.

My animation framework can be had here: [github:animover](https://github.com/makoConstruct/animover)

## I Hate Graphic Design

It is sickening how much work it takes to make a thing look simple. I'm not sure how to explain this. I'll attempt an abstract explanantion: Human perception/need is itself complex, so to make something simple for a human, you have to produce the compliment of human perception/need, which will match its complexity. That seems a bit speculative to me. How about something concrete examples.

- If you look at a list, in this app, the settings sections, or the drop down timer menu, it will look simply evenly spaced. In order to make it look evenly spaced to your human eyes, I had to introduce a smart padding widget that checks its ancestry for a list, and asks the list whether it's at the very top or at the very bottom, and if it is, it adds extra padding to its top or bottom respectively (*On the web, this could be implemented with margins, but margins introduce unclickable dead zone between items, so I disapprove of them*). If you don't do this, if you implement things the simple way, the padding between the edge of the list and the first item will not appear equal to the padding between the first item and its next sibling, because the simple way just puts equal padding on each side, so there will be two units of padding between the items, the padding of each one, and only one unit of padding at the edges. You will interpret the simple approach as cramped or uneven, and the complex approach as nothing at all.

- The space between the clock dial and the numbers appears equal. If this had been implemented the simple way, it would appear even most of the time nad uneven when a timer is placed into a timercule, because the clockface outline would no longer be visible against the backdrop of the timercule (which is the same color), so it would appear that there's additional extra space. So I programmed the spacer between the clockface and the numbers to shrink to zero when placed into a timercule. This only took the addition of one tween animated watch widget, since the framework is very good, but again, it's a mechanism that exists just to prevent you from noticing its absense.

I would like to move to an industrial culture where none of this is necessary. Where we can expose the guts of the mechanism, where simple things will be seen as simple. Maybe this culture isn't far away.

## Persisted Signals are Good

Signals are the correct way to do dynamic reactivity. They're like streams, they have a current value and you can subscribe to them and respond to them whenever they change, but unlike streams, you can also subscribe to them lazily, or check the previous value without subscribing, which prevents a critical performance issue that long braided chains of streams would sometimes run into, and often simplifies update logic.

If you take a signal and have it write its state to the database every time it changes, you have a persisted signal, and now you have an utterly minimal way of preserving app settings and memories between restarts.

This was the first time in my life when I'd been truly satisfied with my medium. Instead of endlessly reworking *platform bullshit* and persnickety foot-shooting boilerplate, everything was ready, and made sense, I was able to just directly describe the features I wanted with utterly succinct code. I was happy. I enjoyed the work every day. Except when things went wrong on the lower layers and I would be plunged back into the platform bullshit again. But one always trudges out of it again, eventually.

It isn't a perfect platform. It has nothing in the way of remote/multiplayer sync.

I will have to leave this sunny glade, for harsher places, now. The problem of sync (essentially: parallel mutation of shared data) remains unsolved. Many have tried and failed. Many still try. If we are ever going to make computers beautiful, I must join them.
