# Third-party notices

The SDR TV app binary statically links the libraries below. They are **not** covered by this
project's PolyForm Noncommercial 1.0.0 license. Each remains under its own license, reproduced in `licenses/`, and
the same files are included inside the app bundle at `Contents/Resources/Licenses`.

## FFmpeg

- Source: https://ffmpeg.org (version 7.1.1)
- License: GNU Lesser General Public License, version 2.1 or later.
  See [licenses/FFmpeg-COPYING.LGPLv2.1.txt](licenses/FFmpeg-COPYING.LGPLv2.1.txt)
- Built without any GPL or non-free components, by [third_party/build_ffmpeg.sh](third_party/build_ffmpeg.sh):
  only libavcodec, libavfilter, libswscale, libswresample and libavutil, with the MPEG-2, H.264,
  HEVC, AC-3, E-AC-3, AAC and MPEG audio decoders and the bwdif deinterlacer.

FFmpeg is linked statically. As the LGPL requires, you may modify FFmpeg and relink the app against
your modified version: the complete source of SDR TV and its build scripts are in this repository.
`third_party/build_ffmpeg.sh` builds FFmpeg into `third_party/ffmpeg-install`, and `macos/build.sh`
links whatever libraries it finds there. You may also reverse-engineer the app for the purpose of
debugging such modifications.

## libhackrf

- Source: https://github.com/greatscottgadgets/hackrf (host/libhackrf, version 2026.01.3)
- Copyright (c) 2012-2022 Great Scott Gadgets, (c) 2012 Jared Boone, (c) 2013 Benjamin Vernoux
- License: BSD 3-Clause. See [licenses/libhackrf-LICENSE.txt](licenses/libhackrf-LICENSE.txt)

## libusb

- Source: https://github.com/libusb/libusb (version 1.0.30)
- License: GNU Lesser General Public License, version 2.1 or later.
  See [licenses/libusb-COPYING.txt](licenses/libusb-COPYING.txt)

libusb is linked statically. As the LGPL requires, you may modify libusb and relink the app against
your modified version: `third_party/build_radio_libs.sh` builds libusb (and libhackrf) into
`third_party/radio-install`, and `macos/build.sh` links the `libusb-1.0.a` it finds there (or else
Homebrew's). You may also reverse-engineer the app for the purpose of debugging such modifications.

## Program guide data

The guide comes first from each station's own broadcast (ATSC PSIP tables). For channels a station
leaves empty, SDR TV can fill in listings from these services. Their data is not part of this
project and stays under each provider's terms:

- **EPGTalk** (https://epgtalk.com): free XMLTV listings, used by default.
- **TVmaze** (https://www.tvmaze.com): network schedules, licensed
  [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). Listings from TVmaze are labeled
  as such in the guide.
- **Schedules Direct** (https://www.schedulesdirect.org): optional, for people with their own
  subscription. Their terms allow individual use with open-source software.
- **XMLTV files** the user chooses to import.

## Codec patents

Some of the audio and video formats used in broadcast television may be covered by patents in some
countries. This project distributes source code and a decoder for personal use; check the rules
that apply where you are.
