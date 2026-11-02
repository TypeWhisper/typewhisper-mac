## Pull Requests

When a pull request fixes or implements a GitHub issue, always:
- include the issue context in the PR body
- include an auto-close reference such as `Closes #123`
- include a short test plan with the exact verification command(s)

For visible UI changes, always capture screenshots of the final interface in English:

- include the screenshots in the user handoff, with PNG files ready to attach to a pull request
- include the relevant screenshots in the pull request description when creating or updating the PR
- upload them with GitHub CLI 2.103 or later (`--attach` is not in older versions): `gh pr create --body-file body.md --attach ./shot.png` or `gh pr edit <number> --body-file body.md --attach ./shot.png` (`![alt](./shot.png)` in the body becomes a GitHub attachment URL); never commit screenshots to the repository

When a change shows in motion (a flow, an animation, live updates, text inserted into another app), also record a short silent clip of the final behaviour in English:

- record only the app's window, 5–20 seconds, as an MP4 under 10 MB
- attach it like a screenshot (GitHub CLI 2.103 or later), `gh pr edit <number> --body-file body.md --attach ./<name>.mp4` (a `![](./<name>.mp4)` reference becomes a video player), and include it in the user handoff; never commit clips to the repository
- static changes (texts, layout, settings) keep screenshots only

## Mac App Store Edition

- `APPSTORE` code must keep the direct-distribution app unchanged; verify both builds when touching shared files.
- Build and launch the sandboxed edition with `scripts/appstore/build-dev.sh --run`; run `scripts/appstore/release-audit.sh` before App Store releases.
- See `docs/appstore/README.md` for decisions, the bundled plugin list and the release workflow.
