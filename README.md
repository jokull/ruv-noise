<p align="center">
  <img src="screenshot.png" alt="RÚV Noise" width="600">
</p>

<h1 align="center">RÚV Noise</h1>
<p align="center">Icelandic public radio through a warm tube amp in your menubar</p>

---

A tiny macOS menubar app that streams RÁS 1 and RÁS 2 with a lo-fi analog processing chain. Great for background noise while you work.

## The Sound

The audio runs through a real-time DSP pipeline designed to sound like a warm vintage tube radio:

- **Band shaping** — HP 200 Hz / LP 5.5 kHz with mid-range presence boost at 2.2 kHz
- **Tube saturation** — Two cascaded asymmetric triode stages with even harmonic exciter
- **Tape coloring** — Pre/de-emphasis around the saturation for natural HF compression
- **Soft compression** — RMS-based soft-knee compressor (slow attack, tube-like squish)
- **Analog noise** — Pink noise floor + sparse vinyl crackle
- **Mono collapse** — Stereo → mono, like a single-speaker radio

## Build

```
open RuvNoise.xcodeproj
# ⌘R to run, or:
xcodebuild -scheme RuvNoise -configuration Release
```

Requires macOS 14+ and Xcode 15+.

## Streams

| Station | URL |
|---------|-----|
| RÁS 1  | `https://ruv-radio-live.akamaized.net/streymi/ras1/ras1.m3u8` |
| RÁS 2  | `https://ruv-radio-live.akamaized.net/streymi/ras2/ras2.m3u8` |

## Tech

- Swift + SwiftUI `MenuBarExtra` (no dock icon)
- AVFoundation for HLS streaming
- `MTAudioProcessingTap` + vDSP/Accelerate for real-time DSP
- Native macOS — no Electron, no dependencies
