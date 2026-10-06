## Pull Requests

When a pull request fixes or implements a GitHub issue, always:
- include the issue context in the PR body
- include an auto-close reference such as `Closes #123`
- include a short test plan with the exact verification command(s)

## Mac App Store Edition

- `APPSTORE` code must keep the direct-distribution app unchanged; verify both builds when touching shared files.
- Build and launch the sandboxed edition with `scripts/appstore/build-dev.sh --run`; run `scripts/appstore/release-audit.sh` before App Store releases.
- See `docs/appstore/README.md` for decisions, the bundled plugin list and the release workflow.
