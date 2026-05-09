mako is an interaction designer and a home cook, who usually dwells in the outskirts of auckland, aotearoa, though frequently goes on adventures to further places whenever the loneliness becomes too much.

mako's other works can be viewed here: https://aboutmako.makopool.com

This app's website is: https://timer.dreamshrine.org

# How This was Made

## Just One Motion

The first design was just one big dial. I started with an intuition that no more than one interaction should be required to create, set, and start a timer. You'd simply turn the dial until you had the number you wanted, and you'd release it, and then it would start winding back, and when it hit 0 the timer would sound.

We did ultimately reduce the number of interactions required to create, set and start a timer to just one, but it couldn't be done through the dial design. In practice, there was no way to make the dial feel good. You'd tend to be one to three seconds off from the exact time you wanted, which wouldn't matter on a practical level, but it felt horrible, because in a sense, you would have the wrong timer, not quite the timer you wanted, and you'd feel the wrongness of it hanging over you as it ticked.

I could make the dial clicky, limit it to 30 second increments, but then we'd lose the precision that made a dial interesting to begin with. Ultimately, a dial would always require you to read the screen as you confirmed your final number, you'd never be able to configure your timer absentmindedly, let alone without really looking at the screen at all.

So I came to appreciate the tactile precision of the number pad. And then I saw a number of optimizations I could try. First came the upward drag to launch, which brought us down to just two interactions per timer-creation. Second came dragging left to add two zeroes and launch, which brought it down to one interaction. At this point, I was excited about the design.

## Tribulations

At one point, morale was severely under threat. None of my friends believed in me. My cook friend from auckland told me that he would not and could not use a phone app timer in his kitchen due to aerosol grease, and due to the fact that he already had a bunch of physical timers. A designer friend from wellington, frustrated that I was allowing timer app to distract me from our admittedly much more important project of building a better web, threatened to ship me thirty physical "chook timers", which are a certain kind of egg-shaped timer that you can twist and release, which I would then be forced to appreciate the neatness and adequacy of. There was a real risk that if they had done this, my timer hunger would have been sated, I would have been plunged into a depressed torpor to never complete the app.

Fortunately, they didn't follow through.

There were other morale challenges. Flutter, the UI framework this app was built on, was in many ways incomplete. But I'd become familiar enough with flutter to know that I'd be able to complete it. Uiquely among UI frameworks, flutter is simple enough to be understood and flexible enough to be fixed.

## General Automatic Animation of Layout

 No UI framework has a robust approach to the automatic animation of layout changes. I had to develop the very first one.

At the center of the app is a "Wrap" container widget. A wrap takes many widgets, in our case, the timers, and arranges them in a flow, in the same way that a paragraph arranges its words, from left to right in lines and the lines go from top to bottom, or you can flip it so that the lines go up instead of down, or so that they flow from right to left, or it can all be rotated by 90 degrees, and the lines can be aligned with the start or the end, or evenly spread over the page, and they can be splayed or bunched up at the end. (In our case, all we did was flip the line direction to right to left, or not, depending on whether you're right handed). So, a Wrap widget is somewhat complex. Which means that when you add or remove a timer, sometimes the layout can change in somewhat surprising ways, you might not be able to visually understand what happened, especially when wraps are being nested.

But if you animate the layout change, it becomes immediately visually comprehensible. The visual system can easily track which objects when from where to where.

I began this journey by going in the wrong direction, by building a special "Wrap" container widget that animates its layout changes automatically when items are added, removed, or reordered. I later realized that I also wanted timers to be draggable, and to animate nicely when dragged, and an animated container couldn't help with animating anything that happened outside of it.

So I considered using animated_to, which animates all movement by checking for screenspace position changes on paint. After much reflection, I came to the conclusion that the solution to layout animation is going to look more like animated_to than my animated_containers, and so I threw away animated_containers, so it sometimes goes.

There was an embarrassing moment where I reimplemented my own spin on animated_to ("animover") with the addition of what we called "AnimoveFrames", which made it possible to scroll a tray of animated widgets without them animating prematurely and lagging behind the scroll. When I assembled a comparison test app, I was dismayed to learn that AnimatedTo actually already had such a thing ("AnimatedToBoundary"), and I hadn't known about it.

My embarrassment was swiftly exorcised from me shortly later when I realised that in fact AnimatedTo didn't have frames at the time I'd last evaluated it, so I wasn't entirely wrong to have done this. The exorcism was  when I noticed certain severe bugs in AnimatedTo that made transfers between frames look awful, which I found easier to solve in my own framework. I also came up with RanimatedContainer. While AnimatedTo-likes animate position changes, RanimatedContainer animates the remaining part of layout change, the size changes.

At that, a general solution had been found.

My animation framework can be had here: [github:animover](https://github.com/makoConstruct/animover)

## Persisted Signals are Good

Signals are the correct way to do dynamic reactivity. They're like streams, they have a current value and you can subscribe to them and respond to them whenever they change, but unlike streams, you can also subscribe to them lazily, or check the previous value without subscribing, which prevents a major performance issue that long braided chains of streams would sometimes run into.

If you take a signal and have it write its state to the database every time it changes, you have a persisted signal, and now you have an utterly minimal way of preserving app state between restarts.

This was the first time in my life when I'd been truly satisfied with my medium. Instead of endlessly trudging through Platform Bullshit and persnickety foot-shooting boilerplate, everything was ready, and made sense, I was able to just directly describe the features I wanted in succinct code. I was happy. I enjoyed the work every day. Except when things went wrong on the lower layers and I would be plunged back into the platform bullshit again. But one always makes it out again, eventually.

It isn't a perfect platform. I'm painfully aware of the lack of remote sync/multiplayer apps, and the difficulties our drift-signals hybrid will have with much larger datasets.

I will have to leave this sunny glade for harsher places, now.

It seems as if reactive databases are still an unsolved problem, no database today provides everything needed. People are still, like, taking postgres and glueing it to redis and managing their own hosting. There are managed solutions like spacetime, supabase, and zero sync, but each of their databases are an island, they currently lack the federatable sync processes of automerge or keyhive, nor do there seem to be any truly parallel decentralized ledgers. I do wonder whether perhaps, it may only take plugging those things together.

Hmm...
