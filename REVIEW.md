# Review guidelines

Apply these guidelines to the changed code and its callers. Follow `AGENTS.md`
for the pull request description and test-plan requirements.

## Priorities and evidence

- Prioritize demonstrable correctness, data-loss, security, compatibility, and
  performance regressions. Explain the reachable trigger, consequence, and
  affected code for each finding.
- Check surrounding implementation and existing safeguards before proposing a
  fix. Distinguish confirmed defects from questions requiring hardware or
  provider evidence. Avoid speculative rewrites, style-only findings, and
  requests to broaden the pull request without a concrete benefit.
- Treat passing CI as supporting evidence. Check whether the relevant behavior
  was exercised and whether important tests were skipped.

## Audio and dictation lifecycle

For recording, input preparation, Bluetooth, and media-control changes:

- Inspect work that was already queued when a session stopped, was cancelled,
  or invalidated. Confirm stale work cannot restore resources or mutate a newer
  session; consider generation checks and cancellation at execution time.
- Verify cleanup against side effects actually performed for the active
  session, including when preferences change before that session ends.
- Follow asynchronous completion, not just invocation order. Include delayed
  media-control responses, device changes, and callbacks arriving after stop.
- Preserve recorded audio needed for recovery until the user discards it or
  the documented retention policy expires it.

## Swift concurrency and model lifecycle

- Check actor isolation, UI updates on the main actor, task cancellation, and
  callback ownership across service and session boundaries.
- Inspect shared state and resource ownership around suspension points;
  identify an actual interleaving before reporting a race.
- Check model restore and unload paths for stale completion or unintended
  downloads. Passive restoration should not silently initiate a model download.

## Plugins, dependencies, and release tooling

- Compare versions across the Xcode project, both package lockfiles, the SDK
  package manifest, and any related release-tool lock. Resolve conflicts with
  exact transitive dependency requirements rather than trusting a version bump.
- Do not exclude lockfiles merely because they are generated. Check that strict
  resolution uses the committed pins and that tests exercise the dependency
  version shipped by the app or plugin.
- For plugin API changes, verify the declared minimum host and SDK compatibility
  against the symbols actually used. Successful compilation against the newest
  SDK does not prove compatibility with the oldest supported host.
- Check release asset checksums, signing/notarization requirements, and registry
  metadata when the corresponding release behavior changes.

## Regression tests

- Prefer controlled state transitions, explicit synchronization, and injectable
  dependencies over short wall-clock sleeps in asynchronous tests.
- Cover already queued work, late callbacks, cancellation, and exhausted retry
  budgets when relevant to the change. Ensure the assertion detects the failure
  being fixed rather than merely reflecting the mock's implementation.
- Distinguish unit-test, real-model, provider, and hardware evidence. Do not
  describe skipped or mocked paths as end-to-end verification.
- Use locale-independent assertions unless localization is the behavior under
  test, in which case specify the locale explicitly.
