#!/bin/bash
# Builds and runs the gesture tests (Tools/GestureTests). Takes ~25 s: the frames play in real time.
set -e
cd "$(dirname "$0")/.."
S=Sources/TouchBridge
OUT=$(mktemp -d)
swiftc -O -o "$OUT/gesture-tests" Tools/GestureTests/*.swift \
  $S/GestureEngine.swift $S/EventSynth.swift $S/Config.swift $S/ScreenMapper.swift $S/ContactDebouncer.swift \
  $S/SystemGestures.swift $S/TouchFeedback.swift $S/VideoTaps.swift $S/AXUtil.swift $S/OnScreenKeyboard.swift \
  $S/KeyboardTyping.swift $S/Dictation.swift \
  -framework AppKit -framework CoreGraphics -framework QuartzCore -framework CoreAudio -framework Carbon
"$OUT/gesture-tests"
