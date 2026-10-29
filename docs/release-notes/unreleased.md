# Unreleased

- Dictation: Dictating into the kitty terminal no longer ends with "No text field detected" when kitty shows the text a moment late. kitty passes typed text on to the shell, which echoes it back, so a field that has not changed yet does not mean the text went nowhere. TypeWhisper now counts the dictation as inserted there, as it already does for web inputs.
