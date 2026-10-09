# SDR TV

Watch free over-the-air digital TV (ATSC 1.0, the US, Canada, Mexico and South Korea broadcast
standard) on a Mac with a HackRF One software-defined radio. SDR TV demodulates the 8VSB signal
itself, decodes the video, audio, captions and program guide, and plays it full screen like a TV,
with on-screen menus that get out of the way.

## Features

- **Finds your stations** with a one-minute scan, and sorts them by reception: Excellent, Good (needs
  extra gain or the RF amplifier) and Poor. Poor channels are hidden from the channel list and guide
  until reception improves or you choose to show them.
- **Changes channel fast.** Subchannels of the same station switch in a few milliseconds. Other
  stations show their last-seen picture, dimmed, until the live picture arrives, which is as soon as
  the station sends a keyframe.
- **MPEG-2, H.264 and HEVC video; AC-3, E-AC-3, AAC and MPEG audio.** Interlaced video is
  deinterlaced to 60 pictures a second, as a TV shows it.
- **Clearer standard definition:** 480-line channels are doubled in resolution with Apple's
  real-time super-resolution (macOS 26) before they are scaled to your screen.
- **Closed captions**, CEA-708 and CEA-608, in the broadcaster's colors, fonts and placement, or in
  your own style. Multiple audio languages and audio description.
- **Program guide** from each station's broadcast, with descriptions, ratings and caption and audio
  information. Channels a station leaves empty can be filled from EPGTalk, TVmaze, an XMLTV file of
  your choice, or your own Schedules Direct subscription.
- **Recording**, now or scheduled from the guide. Recordings are the broadcast stream exactly as
  received (MPEG transport stream, `.ts`); play them with VLC or IINA.
- **Holds up in poor reception:** an adaptive equalizer for multipath, automatic gain, automatic
  recovery when a channel will not come up, and freezing on the last good picture instead of
  showing blocks when the signal drops out.

## Requirements

- A Mac with Apple Silicon, running macOS 14 Sonoma or later (macOS 26 for the standard-definition
  enhancement).
- A [HackRF One](https://greatscottgadgets.com/hackrf/one/), connected by USB.
- An antenna for the TV bands. A telescoping whip on the HackRF's SMA connector works for strong
  stations; a proper TV antenna does much better. US TV is horizontally polarized, so turning a
  whip horizontal often helps a lot.
- Stations broadcasting ATSC 1.0. ATSC 3.0 (NextGen TV) is not supported.

## Install

1. Download `SDR-TV-<version>-macOS-arm64.zip` from the Releases page and unzip it.
2. Move **SDR TV** to your Applications folder.
3. The app is not notarized, so the first time, **right-click it and choose Open**, then confirm.
   Or clear the quarantine flag: `xattr -dr com.apple.quarantine "/Applications/SDR TV.app"`
4. Connect the HackRF and open SDR TV. The first launch scans for channels (about a minute).

## Use

| Key | Action |
|---|---|
| Up / Down arrow | Channel up / down (skips channels marked weak) |
| Left / Right arrow | Volume |
| Digits, then Return | Go to a channel (8.1, 81, or 8) |
| L | Previous channel |
| G | Guide (arrows to move, Return to watch, R to record, U to update, Esc to close) |
| I or Return | Channel information |
| C | Next caption setting |
| A | Next audio track |
| M | Mute |
| R | Start or stop recording now |
| Shift-Command-R | Record the program that is on, to its end |
| F | Full screen |
| U | Update the guide from every station (the picture pauses for a minute or two) |
| S | Scan for channels |

Settings (Command-comma):

- **Tuner:** picture enhancement, gain and the RF amplifier.
- **Channels:** show or hide channels, see each one's reception, and set which network it carries
  (used to match online listings).
- **Guide:** online listing sources.
- **Captions & Audio:** caption language and style, audio language and audio description.
- **Recording:** scheduled and finished recordings.

Scheduled recordings need SDR TV to be running; it keeps the Mac awake while recording. With one
tuner it receives one station at a time, though several programs on the same station can be
recorded together.

## Program guide sources

Each station's own broadcast guide always comes first. Where a station sends nothing, SDR TV can
fill in, in this order:

1. [EPGTalk](https://epgtalk.com) listings for your market (on by default), and the national
   schedules of multicast networks such as Grit or Antenna TV.
2. XMLTV files or URLs you import, or [Schedules Direct](https://www.schedulesdirect.org) if you
   subscribe (optional; their terms allow individual use with open-source software).
3. The same network's schedule from a station in your time zone (labeled; local programs differ).
4. [TVmaze](https://www.tvmaze.com) network schedules (data licensed CC BY-SA 4.0).

The guide shows where each listing came from.

## Build from source

Requirements: Xcode command line tools and [Homebrew](https://brew.sh) (for cmake). Without
`build_radio_libs.sh`, `build.sh` falls back to Homebrew's libusb and libhackrf (`brew install hackrf`),
which only run on the macOS they were built for.

```bash
third_party/build_ffmpeg.sh          # a minimal LGPL FFmpeg, built into third_party/ffmpeg-install
third_party/build_radio_libs.sh      # libusb and libhackrf for macOS 14+ (needs cmake: brew install cmake)
macos/build.sh                       # builds macos/build/SDR TV.app and a zip
macos/build.sh --install             # runs the tests, then installs to /Applications
```

`tests/run.sh` runs the regression checks: the receiver against recorded signals, the media layer,
captions, the channel list rules and the player. Checks that need a recording in `captures/` are
skipped when it is not there.

## How it works

- `dsp/atsc_rx.c`: the 8VSB receiver. Pilot acquisition, symbol timing recovery, an adaptive
  decision-feedback equalizer, trellis (Viterbi) decoding, deinterleaving, Reed-Solomon error
  correction and derandomizing, on three threads.
- `dsp/atsc_media.c`: MPEG transport stream demultiplexing, the ATSC program and guide tables
  (PSIP), and decoding with FFmpeg.
- `dsp/atsc_captions.c`: CEA-608 and CEA-708 caption decoders.
- `macos/Sources`: the SwiftUI app, playback with AVFoundation, and the online guide sources.
- `prototype/`: the Python reference implementation the receiver was developed against.

## Limitations

- One HackRF receives one station (RF channel) at a time.
- ATSC 3.0 and encrypted services are not supported.
- The app is ad-hoc signed, not notarized.

## License

Copyright (c) 2026 Martin Bogomolni

SDR TV is licensed under the
[Creative Commons Attribution-NonCommercial 4.0 International License](https://creativecommons.org/licenses/by-nc/4.0/).
See [LICENSE](LICENSE).

The app includes FFmpeg (LGPL 2.1), libhackrf (BSD 3-Clause) and libusb (LGPL 2.1), each under its
own license. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
