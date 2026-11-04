## Pull Requests

Start every pull request title with its category in parentheses, followed by the usual sentence-style title:

- `(feature)` new or changed functionality that users notice
- `(bug)` fixes for wrong behaviour
- `(perf)` measured speed, CPU, memory or energy improvements without a behaviour change
- `(chore)` everything else: build, CI, release notes, documentation, dependencies, refactoring

Example: `(perf) Skip indicator screen refreshes on clicks and app switches while no indicator is visible`. With squash merges the prefix also becomes part of the commit message on `main`.

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

## Checks on Pull Requests

- The `PR description` check enforces the title prefix, screenshots or a clip for visible changes (or the template's `- [x] No visible UI change`) and a measurement table in `(perf)` descriptions. Editing the description runs it again.
- The `release-build` job compares the launch time, CPU time and memory of the pull request's Release build with its base and writes the table into the description, between the `launch-benchmark` markers. Do not edit that block; CI replaces it after every push.
- A launch regression fails CI. Find and fix the cause first; the folded launch phases show where the time goes. If the cost is intended, explain why in the description, add the `perf-regression-accepted` label and re-run the `release-build` job. Details: `docs/launch-performance.md`.

## Mac App Store Edition

- `APPSTORE` code must keep the direct-distribution app unchanged; verify both builds when touching shared files.
- Build and launch the sandboxed edition with `scripts/appstore/build-dev.sh --run`; run `scripts/appstore/release-audit.sh` before App Store releases.
- See `docs/appstore/README.md` for decisions, the bundled plugin list and the release workflow.
