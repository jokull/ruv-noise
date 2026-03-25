# RÚV Noise

A tiny macOS menubar app that streams Icelandic national radio with a lo-fi FM twist.

## What it does

Click the RÚV logo in your menubar → pick RÁS 1 or RÁS 2 → listen to Icelandic public radio that sounds like it's coming through a cheap FM receiver on your nightstand. Great for background noise.

## Menubar

- **Idle:** RÚV logo
- **Playing:** RÚV logo with a small speaker badge
- **Dropdown:** RÁS 1 · RÁS 2 · Mute

## The FM effect

The audio is processed in real-time to simulate a tinny FM radio:

- Band-pass filter narrowing to ~300 Hz – 4 kHz (telephone/AM-ish range)
- Gentle saturation for that analog warmth
- Subtle stereo-to-mono collapse
- Light noise floor (barely perceptible pink noise)

Not too much, not too little — you should forget it's fake after 30 seconds.

## Streams

| Station | URL |
|---------|-----|
| RÁS 1  | `https://ruv-radio-live.akamaized.net/streymi/ras1/ras1.m3u8` |
| RÁS 2  | `https://ruv-radio-live.akamaized.net/streymi/ras2/ras2.m3u8` |

Fallback API: `https://geo.spilari.ruv.is/channel/{ras1,ras2}` returns JSON with current stream URL.

## Tech

- Swift + SwiftUI menubar app (no dock icon)
- AVFoundation for HLS streaming
- AVAudioEngine for real-time audio processing
- Native macOS — no Electron, no dependencies

## Build

```
open RuvNoise.xcodeproj
# or
xcodebuild -scheme RuvNoise -configuration Release
```

Requires macOS 14+ and Xcode 15+.
