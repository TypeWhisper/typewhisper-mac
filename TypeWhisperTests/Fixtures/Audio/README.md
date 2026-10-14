`tone.opus` is a generated two-second, 440 Hz sine wave encoded as mono Ogg
Opus at 48 kHz and 24 kbps. It contains no recorded speech or third-party media.

Regenerate it with:

```sh
ffmpeg -hide_banner -loglevel error -f lavfi \
  -i sine=frequency=440:duration=2 -ar 48000 -ac 1 \
  -c:a libopus -b:a 24k -y TypeWhisperTests/Fixtures/Audio/tone.opus
```

FFmpeg is only needed to regenerate the fixture. Tests decode the committed
file through the app's AVFoundation pipeline without external tools.
