# dictum icon

## Concept

A clandestine radio operator in stark silhouette. The figure sits in profile, headphones on and coat collar turned up, speaking into a vintage broadcast microphone. Behind the head a single pale spotlight cuts a disc out of a black room, so the face, the open mouth, and the microphone are the only things you see clearly. Everything is black, white, and grey.

## Explorations

`explorations.html` compares three compositions at 1024, 128, 32 and 16 px on light and dark backgrounds, with 32 and 16 px magnified.

| File | Composition |
| -- | -- |
| `explorations/a-operator-at-desk.svg` | Full seated operator at a desk on a light tile, desk microphone in front, transmitter box with meter, dials and whip antenna. |
| `explorations/b-profile-ribbon-mic.svg` | Close head-and-shoulders profile in headphones against a spotlight disc on a black tile, vintage ribbon microphone on a yoke. |
| `explorations/c-lamp-cone.svg` | Black room with a hanging lamp; the operator, microphone and radio sit inside the lamp's cone of light. |

## Why B won

- **Small sizes.** A and C split the tile into many small objects. At 32 px A becomes a dark lump beside a grey box, and C becomes a light triangle with noise at its base. B has two large shapes, a head and a microphone, set against one light disc. Both still show at 32 px, and at 16 px they stay two separate dark forms.
- **Character.** The spotlight disc does the "underground" work without extra props. The black room, a single light, and the turned-up collar read as secret and nocturnal at large sizes. At small sizes they disappear without leaving clutter.
- **Distinct from TypeWhisper.** A black tile with a pale disc and a human profile shares nothing with a white tile and blue sound-wave bars.

## Refinements over the exploration

- Mouth open mid-word, nose and lips sharpened.
- Headphone band drawn as a strip from the ear cup over the crown, outlined in the disc color.
- Turned-up coat collar, shown only by the notches of light behind the nape and under the chin.
- Microphone tilted toward the mouth, with pivot knobs on the yoke and a solid waist band between the grille slits, moved out so a clear gap of light separates it from the lips.

## Files

| File | Purpose |
| -- | -- |
| `dictum-icon.svg` | Master, 1024 × 1024, macOS icon grid (824 × 824 continuous-corner tile, 100 px margin, drop shadow inside the margin). Renders 64 px and up. |
| `dictum-icon-small.svg` | 16 and 32 px variant. A larger disc, no headphones, collar or grille. The microphone is a solid pill on a stem, upright and aligned to the 16 px pixel grid, with at least one pixel of light between face and microphone at 16 px. |
| `menubar-glyph.svg` | Menu bar template glyph, 18 × 18 pt. Head and shoulders in profile facing a microphone on a desk stand, black on transparent, microphone edges pixel-aligned at 1x. |
| `explorations/*.svg` | The three exploration masters. |
| `explorations.html` | Exploration comparison page. |
| `preview.html` | Chosen icon at 1024, 512, 128, 32, 16 on light and dark, and the glyph in light and dark menu bars. |
| `render.sh` | Renders every PNG and rebuilds both HTML pages. |

## Palette

| Role | Hex |
| -- | -- |
| Tile top | `#2A2A2A` |
| Tile bottom | `#101010` |
| Spotlight center | `#F5F5F3` |
| Spotlight mid (75%) | `#E4E4E1` |
| Spotlight edge | `#C6C6C2` |
| Silhouette | `#0A0A0A` |
| Cut lines (headphones, grille) | `#E4E4E1` |
| Tile rim | `#FFFFFF` at 18% top, 3% middle, 6% bottom |
| Small variant tile | `#161616` |
| Small variant disc | `#EAEAE7` |
| Menu bar glyph | `#000000` with alpha (template image) |

## Rendering

From the repository root:

```sh
docs/design/icon/render.sh
```

The script renders each SVG straight to its target pixel size with Google Chrome in headless mode (`--headless=new --default-background-color=00000000 --force-device-scale-factor=1 --window-size=N,N`), checks every output with `sips -g pixelWidth -g pixelHeight`, and fails on a size mismatch. Set `CHROME` to use a different Chrome binary. It writes:

- `TypeWhisper/Resources/Assets.xcassets/AppIcon.appiconset/icon_*.png` (16 and 32 px from the small variant, 64 to 1024 px from the master).
- `TypeWhisper/Resources/Assets.xcassets/MenuBarGlyph.imageset/menubar-glyph.png` (18 px) and `menubar-glyph@2x.png` (36 px).
- `docs/design/icon/preview.html` and `docs/design/icon/explorations.html` with the PNGs embedded.
