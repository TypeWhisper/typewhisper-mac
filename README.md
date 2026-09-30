Visual keyboard previews for TypeWhisper/typewhisper-mac#1412.

Captured from the signed local Dev app built from commit 8053e93599db555e43cc7df922b7aff45a371fc4. Each screenshot pairs the app language with an actual active macOS input source:

- German UI: German input source (com.apple.keylayout.German).
- English UI: U.S. input source (com.apple.keylayout.US).
- Japanese UI: Japanese - Kana / Hiragana (com.apple.inputmethod.Kotoeri.KanaTyping.Japanese), underlying com.apple.keylayout.KANA.
- Simplified Chinese UI: Pinyin - Simplified (com.apple.inputmethod.SCIM.ITABC), with the ABC option instead of the German-layout option; underlying com.apple.keylayout.PinyinKeyboard. This uses Latin QWERTY letters and Chinese punctuation.

All captures use the same physical ISO keyboard (hardware type 92). Physical JIS hardware was not tested. Live input-source switching was checked in the open visual keyboard, including preservation of the selected key/modifiers. The temporary input sources and automatically added dictation languages were removed after testing, restoring German input and the original German/English dictation languages.

The initial screenshots at 91d0a39 changed only the app language and kept the German input source. These updated captures replace that limited locale-only evidence with actual input-source previews.
