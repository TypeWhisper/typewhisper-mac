# TypeWhisper Ear

`TypeWhisperEar.mlmodelc` picks the spoken language among the languages a user selected. The host
asks the plugin when an engine accepts a single language but the selection holds several; without
the plugin the engine gets the first selected language.

## Model

- whisper-tiny encoder (4 layers), mean and standard deviation of every layer over the frames that
  hold audio
- Whisper's own language log-probs from one decoder step after `<|startoftranscript|>`
- an MLP head (512 hidden units) over both, with a skip path that starts as Whisper's answer
- Core ML pipeline: an fp32 log-mel frontend (the STFT runs as a convolution) and an 8-bit
  palettized encoder, decoder step and head; 18 MB, about 14 ms per call on the Neural Engine of an
  M5 Pro, 5 ms on its GPU
- inputs: `audio` (1 x 480000, 16 kHz mono, zero padded to 30 s) and `valid_frames` (1 x 1, the
  number of 20 ms frames that hold audio); outputs: `own_logprobs` and `whisper_logprobs` over the
  117 languages in the `languages` metadata
- the plugin adds `fusion_beta` times Whisper's log-probs to its own only when Whisper knows every
  candidate (`whisper_languages` metadata)

## Training data

| Source | License | Used |
|---|---|---|
| FLEURS | CC BY 4.0 | 1,000 utterances per language, 3 crops each |
| VoxLingua107 train | CC BY 4.0 | 4 shards (about 2,000 clips) per language; clips Whisper hears as English dropped from other languages |
| VoxPopuli train | CC0 | 2,500 utterances per language |
| VoxPopuli en_accented, AMI | CC0, CC BY 4.0 | accented and meeting English |

Crops run from 0.8 to 12 s plus the whole utterance, with noise, reverb, random EQ and telephone band
augmentation. Eight VoxLingua107-only classes with mostly mislabeled audio (`ab`, `eo`, `gn`, `gv`,
`ia`, `la`, `sco`, `war`) are not in the label set.

## Results

Choosing between two languages (all pairs of 20 common languages), accuracy in %, speakers not seen
in training. whisper-tiny is Whisper's built-in language detection on the same clips.

| Set | 1 s | 2 s | 3 s | whole utterance | whisper-tiny 2 s | whisper-tiny whole |
|---|---:|---:|---:|---:|---:|---:|
| FLEURS test | 77.2 | 92.1 | 96.7 | 99.7 | 89.2 | 99.6 |
| VoxLingua107 dev (YouTube) | 84.7 | 94.5 | 97.5 | 99.3 | 91.4 | 98.9 |
| VoxPopuli test (EU Parliament) | 95.5 | 98.5 | 99.1 | 99.5 | 96.8 | 99.3 |
| Multilingual LibriSpeech test | 90.5 | 96.3 | 98.4 | 99.9 | 96.0 | 100.0 |
| Common Voice 17 English | 97.0 | 98.1 | 99.1 | 99.2 | 99.1 | 99.6 |

The weight of Whisper's log-probs (1.0) was picked while looking at these sets; it is plain equal
weighting, not a tuned value. Accented English is the weakest case: picking among all languages,
Common Voice English scores 92.3 % against whisper-tiny's 94.0 %.
