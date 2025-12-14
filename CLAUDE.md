# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Personality

If the user is ever confused or ignorant about anything, a good friend would inform them of it. Be a good friend.

The user doesn't have complete confidence in you, try to substantiate your claims with quotes from sources where this might be necessary. The source code of the libraries in package cache is a useful source of information.

## Style

Don't comment excessively.

## Project Overview

Mako's Timer is an ergonomic Flutter timer app that optimizes the user experience through visual compactness, color-coding, and gesture-based interactions. The app uses a custom reactive persistence system called Mobj that combines Signals for reactivity with Drift (SQLite) for persistence.

## Build & Development Commands

```bash
# Initial setup
flutter create .
flutter pub get
flutter pub run build_runner build  # Generate database.g.dart

# Run the app
flutter run

# Rebuild generated files (after schema changes)
flutter pub run build_runner build --delete-conflicting-outputs

# Analyze code
flutter analyze
```

## Core Architecture

### Mobj System (Reactive Persistence)

The Mobj system ([lib/mobj.dart](lib/mobj.dart)) is a custom reactive key-value persistence layer that:
- Uses **Signals** (`signals` package) for reactivity instead of streams
- Automatically persists to **SQLite** via Drift whenever values change
- Provides type-safe serialization via `TypeHelp<T>` parsers
- Manages loading/caching with `MobjRegistry`
- Supports cross-isolate sharing when configured with `DriftNativeOptions(shareAcrossIsolates: true)`

**Root Mobjs**: Pre-defined UUIDs in [lib/main.dart](lib/main.dart) for app-wide state:
- `timerListID`: Pinned timers list
- `transientTimerListID`: Temporary timers list
- `nextHueID`: Next color hue for timer creation
- `dbVersionID`: Database schema version

**Usage Pattern**:
```dart
// Initialize root mobjs in initializeDatabase()
await Mobj.getOrCreate(id, type: SomeType(), initial: () => defaultValue);

// Access in widgets
final mobj = Mobj.getAlreadyLoaded<T>(id, type);
mobj.value = newValue;  // Automatically persists
```

### Database Layer

- **Schema**: Defined in [lib/database.dart](lib/database.dart) using Drift
- **Generated code**: [lib/database.g.dart](lib/database.g.dart) (don't edit manually)
- **Storage**: Single `KVs` table for Mobj persistence (id, value pairs as JSON)
- **Connection**: Uses `drift_flutter`'s `driftDatabase()` with background isolate support

### Timer Data Structure

Timer state is stored as `TimerData` objects (defined in [lib/type_help.dart](lib/type_help.dart)) containing:
- `digits`: List of integers representing timer duration
- `startTime`: When timer was started/paused
- `running`: Boolean status
- `hue`: Color hue (0-360) for visual identification

### UI Components

- **TimerScreen**: Main widget managing timer list and input pad
- **Timer**: Individual timer widget using Mobj for reactive state
- **Input pad**: Numeral entry with swipe-up gesture to start timer
- **Color system**: HSLuv-based pastel colors for visual distinction

### Background Audio

Currently in development. Reference implementation in `openhiit/` symlink shows:
- Uses `flutter_background_service` with foreground service type `mediaPlayback`
- Requires Android manifest service declaration with `android:foregroundServiceType="mediaPlayback"`
- Uses `AudioPlayer.global.setAudioContext()` for background audio mixing
- Note: `audioplayers` has known issues on Linux (issue #1749)

### File Organization

- [lib/main.dart](lib/main.dart): App entry point, timer UI, and business logic
- [lib/mobj.dart](lib/mobj.dart): Reactive persistence system
- [lib/database.dart](lib/database.dart): Drift schema definition
- [lib/type_help.dart](lib/type_help.dart): Type serialization helpers for Mobj
- [lib/boring.dart](lib/boring.dart): Utility code (audio, math, helpers)
- [lib/background_service_stuff.dart](lib/background_service_stuff.dart): Foreground task handlers

## Key Design Patterns

### Gesture-Based Timer Creation
- Start typing implicitly creates a new timer
- Swipe up on final numeral to start the timer (saves a tap)
- Visual feedback via `numeralDragIndicator` animation

### Timer Lifecycle
1. User enters digits → creates temporary timer in `transientTimerListMobj`
2. Timer started → moves to persistent `timerListMobj`
3. Color assigned via `nextRandomHue()` using golden ratio spacing for visual distinction

### State Management
- Widget-level: `provider` package for dependency injection (JukeBox, Thumbspan)
- App-level: Mobj system for persistent reactive state
- UI reactivity: Signals via `signals_flutter` package

## Known Issues & TODOs

- Background audio playback needs foreground service implementation
- "Bark once" option not yet implemented
- Chained timers feature planned but not implemented
- Looping timers planned but not implemented
- Audio assets not committed to repo (credit: Kenney.nl)
