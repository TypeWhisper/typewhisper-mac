# Manual test checklist: input and permissions

Start with a sandbox-signed build and fresh privacy permissions:
`scripts/appstore/build-dev.sh --run --reset-permissions`.

1. Setup wizard shows the optional Accessibility and Input Monitoring cards; setup completes without granting either.
2. Without permissions, dictate into TextEdit with a ⌥⌘ shortcut: the text lands on the clipboard and the "Press ⌘V" notice appears; "Open Settings" leads to the dashboard rows.
3. Grant Accessibility. Returning to TypeWhisper updates the permission rows; if macOS has not applied the change yet, the "Restart TypeWhisper" hint appears and the restarted app shows it as granted. Then dictation is pasted and the previous clipboard returns after about 0.4 s. Repeat in Terminal, a browser text field and Slack or VS Code.
4. Set the shortcut to Fn: the dashboard asks for Input Monitoring. After granting it, Fn works in other apps within about 2 s (otherwise retry after a restart). Note what the globe-key system action does.
5. Repeat for right Option, a double-tap shortcut, push-to-talk with release and mouse button 4.
6. A bare F-key shortcut works with Input Monitoring off and does not reach the frontmost app.
7. Esc during recording in another app cancels (with Input Monitoring) and also reaches that app. Without Input Monitoring, Esc only cancels while TypeWhisper is focused.
8. A workflow with Auto Enter "Always" presses Return after pasting.
9. Prompt palette with selected text in TextEdit: the selection is captured with ⌘C, the result replaces it and the clipboard is restored. Repeat with nothing selected and text on the clipboard.
10. Paste-last and the recent-transcriptions palette work with and without Accessibility.
11. Build with `TYPEWHISPER_APPSTORE_AUTOPASTE = NO`: no Accessibility card or row, nothing is posted, text is always copied.
12. Website workflows do not match; calendar meeting auto-start still works for Zoom and Teams.
13. Exported diagnostics contain `inputMonitoringGranted` and `autoPasteEnabled`.
