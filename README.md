# Ambeat 🎧

A minimal, beautiful, and sound-reactive macOS menu bar utility designed to generate ambient sounds, binaural beats, and lo-fi rhythms. Ambeat integrates a procedural sound generator with an interactive sand-pattern visualizer inspired by Chladni plates.

---

## Key Features

- **Interactive Procedural Mixer**:
  - **Binaural Beats**: Custom frequency generators to aid concentration and sleep.
  - **Pink Noise**: Natural background noise masking.
  - **Ambient Synth**: Generative melodies that evolve over time.
  - **Lo-Fi Bass & Drums**: Rhythm generators that follow a custom tempo.
- **Sound-Reactive Visualizer**:
  - **Chladni Sand Patterns**: Procedural particle simulation vibrating based on active music frequencies.
  - **Pixel Ripples**: Sound-reactive waves that flare and dim dynamically.
- **MacOS Integration**:
  - **Menu Bar Utility**: Runs as a lightweight accessory application without cluttering your Dock.
  - **Borderless Floating Window**: Sleek, dark glassmorphism design with key focus transitions and smooth animations.

---

## Installation

### Instant Install (Recommended)

1. Download the latest release `.dmg` from the GitHub releases page.
2. Open the `.dmg` file and drag **Ambeat.app** into your `/Applications` directory.
3. Open **Ambeat** from your Applications or Launchpad.

---

## How to Build from Source

### Prerequisites
- macOS 14.0 or newer
- Xcode 15+ or Swift 6.0+

### Build App & Packaging DMG

Run the automated packaging script from the root of the repository:
```bash
./build_dmg.sh
```

This script will:
1. Render the SVG app icon to standard Apple sizes.
2. Compile the application in `Release` configuration using SwiftPM.
3. Assemble the standalone `Ambeat.app` bundle.
4. Package the bundle into a compressed, styled `Ambeat.dmg` ready for installation.

---

## Technical Stack

- **UI Framework**: SwiftUI
- **Audio Engine**: Custom synthesizer built on `AVFoundation` and standard Swift loops (using low-level audio processing and synthesis loops for generative binaural beats, noise, synth melody voices, and custom drum step-sequencer).
- **Icon Rendering**: Vector graphics processed via Cocoa's `NSImage` drawing tools.

