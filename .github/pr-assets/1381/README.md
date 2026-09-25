# PR #1381: indicator themes and waveform

Real overlay captures of the dev app built from this branch on 2026-09-25, macOS 26, dark system appearance, in front of a synthetic gradient image opened in Preview. The app icon in the pill is Preview's. Audio came from `say` routed through the BlackHole loopback device, so the transcript text is the spoken test sentence, and the app was killed before anything was inserted. Whisper adds a hallucinated lead-in on the first partial in some runs.

| Theme | Idle | Speaking | Transcript |
| --- | --- | --- | --- |
| Classic | ![Classic idle](classic-idle.png) | ![Classic speaking](classic-speaking.png) | ![Classic transcript](classic-transcript.png) |
| Glass | ![Glass idle](glass-idle.png) | ![Glass speaking](glass-speaking.png) | ![Glass transcript](glass-transcript.png) |
| Light | ![Light idle](light-idle.png) | ![Light speaking](light-speaking.png) | ![Light transcript](light-transcript.png) |

Notch style with the transcript expanded, same audio path. The notch cap stays black in every theme, the body below takes the theme:

| Classic | Glass | Light |
| --- | --- | --- |
| ![Notch classic](notch-classic-transcript.png) | ![Notch glass](notch-glass-transcript.png) | ![Notch light](notch-light-transcript.png) |

Settings window in `--store-screenshots --screenshot-state indicator-settings` fixture mode (English, dark appearance, 1150 pt wide), cropped to the Indicator section:

| Classic | Glass | Light |
| --- | --- | --- |
| ![Settings with Classic selected](settings-classic.png) | ![Settings with Glass selected](settings-glass.png) | ![Settings with Light selected](settings-light.png) |

Capture: `screencapture -x -R 356,520,800,462` for the pill and the window bounds from System Events for the settings window, then cropped with ffmpeg. Pixels were not retouched.
