# Launch performance checks

Every pull request that changes the app compares how its Release build launches with the
build of its base branch. The `release-build` job of the Build DMG workflow measures both, and
the table appears in the pull request description.

## What CI measures

The job builds the base branch into the same derived data after the pull request build, so
only the targets the pull request changed compile again. Then
`scripts/performance/launch_benchmark.py` runs on the same runner:

1. Each build gets its own test profile: setup completed, update checks and optional launch
   prompts off, and 3,000 history entries, 300 dictionary entries and 30 snippets that the app
   imports through its local API. A second launch checks that the data persisted and runs
   one-time work such as statistics backfills.
2. The builds launch alternately, 8 rounds each. Every launch starts from a copy of the
   profile, without the local API, and records:
   - **Time until ready:** from starting the process to the `Launch.firstIdle` signpost, the
     first time the main thread waits after the service setup, the plugin scan and the model
     restore.
   - **CPU time**, **memory after launch** (physical footprint) and **peak memory**, read 6
     seconds later.
3. Each metric's change is the median of the paired differences, one pair per round, so a
   runner that gets slower during the job affects both builds alike.

The table also shows the app size and, folded, the launch phases from the app's signposts
(`Launch.serviceContainer`, `Plugin.scan` and others) to find where a change comes from.

The CI profile has no downloaded plugins or models, only the two plugins the app bundles, so
the load times of other plugins do not show up here. Measure changes to plugin loading with
plugins installed and add those numbers to the description.

## When CI fails

A metric fails when its change exceeds both limits:

| Metric | Fails above |
| --- | --- |
| Time until ready | +10% and +50 ms |
| CPU time | +10% and +50 ms |
| Memory after launch | +5% and +2 MB |
| Peak memory | +10% and +4 MB |

When the first 8 rounds show a regression, 8 more rounds confirm it; only a regression in
both passes fails the job. App size never fails it.

If the cost is intended, for example for a feature that has to load something at launch,
explain why in the description, add the `perf-regression-accepted` label and re-run the
`release-build` job. The job reads the label when it runs.

Pull requests that only change documentation, tests, scripts or CI files skip the benchmark,
unless they change the benchmark or `build.yml`.

## Pull request descriptions

The "PR description" check enforces the rules from `AGENTS.md`:

- the title starts with `(feature)`, `(bug)`, `(perf)` or `(chore)`,
- a pull request that changes something visible has screenshots or a clip, unless
  `- [x] No visible UI change` is ticked,
- a `(perf)` pull request has its own measurement table.

The launch table lives between `<!-- launch-benchmark:start -->` and
`<!-- launch-benchmark:end -->`. The Launch Benchmark Report workflow replaces it after every
run, and it counts for none of the checks above.

## Running it elsewhere

`run` deletes the preferences of the app's bundle identifier, imports a test profile and
launches the builds with their real identifier, so it refuses to run without
`--disposable-mac`. Never run it on a Mac where TypeWhisper is installed. `render`, `check`
and the tests (`scripts/test_launch_benchmark.py`) run anywhere.
