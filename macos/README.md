# zitto for macOS

The native Mac app: the same window as on Windows (songs on the left, the parts of the open one
on the right) written in Swift, with SwiftUI and AppKit, AVAudioEngine for the sound and CoreMIDI
for the controllers. The separation is done by the same Python worker as on Windows
(`zitto/worker.py`), which the app starts in the background; on Apple silicon it runs on the GPU.

Needs macOS 13 or later. Apple silicon is much faster than Intel for the separation.

## Install

1. The tools, from [Homebrew](https://brew.sh):

       xcode-select --install
       brew install python@3.12 ffmpeg

2. What separates the songs, once (about 3 GB with PyTorch; the models are downloaded later,
   the first time each is needed):

       macos/scripts/setup-worker.sh

3. The app:

       macos/scripts/build-app.sh
       open macos/build/zitto.app

   Drag `zitto.app` to Applications if you like. The first time, macOS may ask to confirm that
   you want to open it, since it is signed only for this Mac.

## Use

As on Windows (see the [README](../README.md)), with the keys of a Mac:

| To | Do |
| --- | --- |
| add songs | **Files...**, ⌘O, drag them on the window, or "Open With" zitto in the Finder |
| play/pause, rewind, loop on/off, clear loop | Space, Home (fn ←), L, Esc |
| mute a part | its number on the keyboard, or click its name; M and S beside it |
| save what you hear | ⌘S |
| search | ⌘F; Enter opens the first song found, Esc shows everything again |
| zoom, move | wheel or two fingers up and down, pinch; two fingers sideways or Shift+wheel |

MIDI: on a Mac several programs can use the same device at the same time.

## Where things are

| What | Where | To change it |
| --- | --- | --- |
| songs | `~/Library/Application Support/zitto/library` | `ZITTO_LIBRARY` |
| models | `~/Library/Application Support/zitto/models` | `ZITTO_MODELS_DIR` |
| settings | `~/Library/Application Support/zitto/settings.json` | |
| Python of the worker | `~/Library/Application Support/zitto/venv` | `ZITTO_PYTHON`, or `"python"` in the settings |
| saved songs | `~/Music/zitto`, the first time | |

The library has the same format as on Windows: a folder copied from there opens here.
`ZITTO_MODELS=stated` and the plugins work as described in the main README; plugins are installed
in the Python of the worker:

    ~/Library/Application\ Support/zitto/venv/bin/python3 -m pip install -e /path/to/my-plugin

## Command line

The command line of zitto works the same, from the Python of the worker:

    ~/Library/Application\ Support/zitto/venv/bin/zitto song.mp3 -r drums bass
    ~/Library/Application\ Support/zitto/venv/bin/zitto song.mp3 --player    opens the app

## Code

    macos/
      Package.swift
      Sources/ZittoCore/   plain Swift, no AppKit: library on disk, mixer, parts, MIDI messages,
                           waveform peaks, the messages of the worker
      Sources/Zitto/       the app: window, player, waveform, audio, MIDI, the worker process
      Tests/               swift test

ZittoCore follows the Python modules closely (`mixer.py` → `Mixer.swift`, `library.py` →
`Library.swift`, ...), and its tests are those of `tests/test_player.py` and
`tests/test_library.py`. Build and test with:

    cd macos && swift build && swift test

Or open `macos/Package.swift` in Xcode.
