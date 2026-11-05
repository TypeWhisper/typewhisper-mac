#!/usr/bin/env python3
"""Compare how two TypeWhisper builds launch on the same Mac.

Pull requests run this in CI: the Release builds of the pull request and of its base get
the same test profile and launch alternately on one runner, so the runner's speed cancels
out of the comparison.

    launch_benchmark.py run --base BASE.app --head PR.app --work DIR --output report.json \\
        --disposable-mac [--base-sha SHA --head-sha SHA --pull-request N]
    launch_benchmark.py check report.json --accepted true|false [--summary FILE]
    launch_benchmark.py render report.json
    launch_benchmark.py fixture backup.json
    launch_benchmark.py pr-number report.json
    launch_benchmark.py update-description report.json --body body.md --output payload.json

`run` deletes the preferences of the builds' bundle identifier and launches the apps with
their real identifier, so it refuses to run without `--disposable-mac` (a CI runner).

The base build imports the test profile through the local API: setup completed, update checks
and optional launch prompts off, and a test history, dictionary and snippets. Each build then
launches once on its own copy of it. Both builds launch from the same path, and every measured
launch starts from a copy of the build's profile and records

- the time from starting the process to the `Launch.firstIdle` signpost, when the main
  thread first waits after the service setup, the plugin scan and the model restore,
- after a settle period, the CPU time, the memory footprint and the peak footprint.

A metric regresses when the median of the paired differences (pull request minus base, one
pair per round) exceeds both its relative and its absolute limit and the pull request was worse
in at least 80% of the rounds, in the first pass and in a confirmation pass. The other commands
turn a report, which can come from an untrusted pull request, into the Markdown table for the
pull request description.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import os
import platform
import plistlib
import random
import re
import shutil
import signal
import statistics
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

SCHEMA = "typewhisper-launch-benchmark"
SCHEMA_VERSION = 1
ACCEPT_LABEL = "perf-regression-accepted"
SECTION_START = "<!-- launch-benchmark:start -->"
SECTION_END = "<!-- launch-benchmark:end -->"
SECTION_NOTE = "<!-- Written by CI for every push. Edits inside this block are replaced. -->"
VERDICTS = ("pass", "regression", "accepted", "error")

# Test profile imported before the measured launches.
FIXTURE = {"history": 3000, "dictionary": 300, "snippets": 30}

ROUNDS = 10
# A regression also needs the pull request to be worse in this share of the rounds.
CONSISTENT_SHARE = 0.8
SETTLE_SECONDS = 6.0
FIRST_IDLE_TIMEOUT = 120.0
API_TIMEOUT = 180.0
API_PORT = 8978


class Metric:
    def __init__(self, key, label, unit, decimals, limit_pct=None, limit_abs=None):
        self.key = key
        self.label = label
        self.unit = unit
        self.decimals = decimals
        self.limit_pct = limit_pct
        self.limit_abs = limit_abs

    @property
    def gated(self):
        return self.limit_pct is not None


# Limits from comparing identical builds on the xcode-27 runner: paired differences of one
# round spread by 120 to 450 ms for the time until ready, 100 to 250 ms for CPU time and 0.2 MB
# for the footprint, depending on how busy the shared host is.
METRICS = (
    Metric("first_idle_ms", "Time until ready", "ms", 0, 10.0, 100.0),
    Metric("cpu_ms", "CPU time", "ms", 0, 15.0, 100.0),
    Metric("footprint_mb", "Memory after launch", "MB", 1, 5.0, 2.0),
    Metric("peak_footprint_mb", "Peak memory", "MB", 1, 10.0, 4.0),
)
METRIC_BY_KEY = {metric.key: metric for metric in METRICS}
SIZE_METRIC = Metric("app_size_mb", "App size", "MB", 1)

# Launch phases from the app's signposts, shown for diagnosis only.
PHASES = (
    ("pre_main_ms", "Process start until the app's code runs"),
    ("Launch.serviceContainer", "Service setup"),
    ("Launch.didFinishLaunching", "applicationDidFinishLaunching"),
    ("Plugin.scan", "Plugin scan"),
    ("Launch.modelRestore", "Model restore"),
)
PHASE_KEYS = tuple(key for key, _ in PHASES)

# Per-launch diagnostics of the runner, shown with the phases. Virtual machines may count no
# instructions; the row is left out then.
COUNTERS = (
    ("instructions_g", "Instructions", " billion", 2),
    ("runnable_ms", "Time waiting for a processor", " ms", 0),
    ("idle_before_pct", "Idle processors before the launch", "%", 0),
)
COUNTER_KEYS = tuple(key for key, _, _, _ in COUNTERS)

# Launch arguments for every launch: no restored windows, English interface.
LAUNCH_ARGUMENTS = (
    "-ApplePersistenceIgnoreState", "YES",
    "-AppleLanguages", "(en)",
    "-AppleLocale", "en_US",
)


class BenchmarkError(RuntimeError):
    pass


# MARK: - Statistics and decisions


def evaluate(metric, base, head):
    """Medians, the median paired difference, the rounds in which the pull request was worse, and
    whether the change exceeds both limits in at least CONSISTENT_SHARE of the rounds. Noise on the
    shared runner moves single rounds by hundreds of milliseconds in both directions; a real
    regression makes nearly every round worse."""
    if not base or len(base) != len(head):
        raise ValueError(f"{metric.key}: base and head need the same, non-zero number of samples")
    base_median = statistics.median(base)
    head_median = statistics.median(head)
    deltas = [h - b for b, h in zip(base, head)]
    delta = statistics.median(deltas)
    pct = 100.0 * delta / base_median if base_median else 0.0
    worse = sum(1 for value in deltas if value > 0)
    consistent = worse >= math.ceil(CONSISTENT_SHARE * len(deltas))
    exceeded = bool(metric.gated and delta > metric.limit_abs and pct > metric.limit_pct and consistent)
    return {"base": base_median, "head": head_median, "delta": delta, "pct": pct, "worse": worse,
            "rounds": len(deltas), "exceeded": exceeded}


def exceeded_metrics(passes):
    """Metrics that exceeded their limits in every pass."""
    return [metric.key for metric in METRICS
            if passes and all(evaluate(metric, p["base"][metric.key], p["head"][metric.key])["exceeded"]
                              for p in passes)]


def metric_samples(launches):
    return {metric.key: [launch[metric.key] for launch in launches] for metric in METRICS}


# MARK: - Test profile


ENGLISH_WORDS = (
    "the meeting starts at ten and we review the budget for next quarter please send notes to "
    "team before lunch thanks for update I will call you tomorrow about project timeline our "
    "customers asked better export options can we move standup Friday afternoon draft looks good "
    "but second paragraph needs shorter sentences remind me to book flights for conference new "
    "release fixes crash when switching microphones during recording"
).split()
GERMAN_WORDS = (
    "das Meeting beginnt um zehn und wir besprechen das Budget für das nächste Quartal bitte "
    "schick die Notizen vor dem Mittagessen an das Team danke für das Update ich rufe dich morgen "
    "wegen des Zeitplans an unsere Kunden wünschen bessere Exportoptionen der Entwurf sieht gut aus"
).split()
APPS = (
    ("Mail", "com.apple.mail"),
    ("Slack", "com.tinyspeck.slackmacgap"),
    ("Notes", "com.apple.Notes"),
    ("Safari", "com.apple.Safari"),
    ("Messages", "com.apple.MobileSMS"),
    ("Xcode", "com.apple.dt.Xcode"),
    ("Google Chrome", "com.google.Chrome"),
    ("TextEdit", "com.apple.TextEdit"),
)
ENGINES = (
    ("parakeet", "parakeet-tdt-0.6b-v3"),
    ("whisper", "openai_whisper-large-v3-v20240930_turbo"),
    ("speechanalyzer", None),
)
SYLLABLES = ("ka", "ri", "to", "mel", "san", "dor", "vix", "lu", "pra", "zen", "qua", "bel", "tor", "nia", "ex", "on")


def iso8601(moment):
    return moment.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def build_fixture(now, counts=None, seed=1867):
    """A settings backup (schema version 1) with history, dictionary entries and snippets.

    The content is the same for every seed; timestamps lie in the 120 days before `now`, so
    history retention never drops them."""
    counts = counts or FIXTURE
    rng = random.Random(seed)
    history = []
    for _ in range(counts["history"]):
        language = "de" if rng.random() < 0.3 else "en"
        words = rng.choices(GERMAN_WORDS if language == "de" else ENGLISH_WORDS, k=rng.randint(6, 60))
        raw = " ".join(words)
        app_name, bundle_identifier = rng.choice(APPS)
        engine, model = rng.choice(ENGINES)
        history.append({
            "timestamp": iso8601(now - dt.timedelta(seconds=rng.randint(60, 120 * 86400))),
            "rawText": raw,
            "finalText": raw[0].upper() + raw[1:] + ".",
            "appName": app_name,
            "appBundleIdentifier": bundle_identifier,
            "durationSeconds": round(len(words) / 2.4, 1),
            "language": language,
            "engineUsed": engine,
            "modelUsed": model,
            "pipelineSteps": ["Dictionary"] if rng.random() < 0.4 else [],
        })

    names = set()
    while len(names) < counts["dictionary"]:
        names.add("".join(rng.choice(SYLLABLES) for _ in range(rng.randint(2, 4))).capitalize())
    dictionary = []
    for index, name in enumerate(sorted(names)):
        correction = index % 3 == 0
        dictionary.append({
            "type": "correction" if correction else "term",
            "original": f"{name[:2].lower()} {name[2:].lower()}" if correction else name,
            "replacement": name if correction else None,
            "caseSensitive": False,
            "isRegex": False,
            "isEnabled": True,
            "ctcMinSimilarity": None,
            "source": "manual",
        })

    snippets = [{
        "trigger": f";snippet{index:02d}",
        "replacement": f"Best regards, snippet {index} with a longer text to expand",
        "caseSensitive": False,
        "isEnabled": True,
    } for index in range(counts["snippets"])]

    return {
        "schemaVersion": 1,
        "exportedAt": iso8601(now),
        "appVersion": "launch-benchmark",
        "workflows": [],
        "dictionaryEntries": dictionary,
        "snippets": snippets,
        "promptActions": [],
        "profiles": [],
        "hotkeys": {},
        "plugins": [],
        "history": history,
        "preferences": {},
    }


def profile_defaults(app_constants_source):
    """Preferences of the test profile: setup done, no update checks, no optional prompts.

    The iOS companion promotion counts as seen when its campaign identifier is found in the
    build's AppConstants.swift; otherwise both builds may open Settings at launch."""
    values = {
        "setupWizardCompleted": True,
        "welcomeSheetShown": True,
        "lastSeenWhatsNewContentVersion": 1_000_000,
        "SUEnableAutomaticChecks": False,
        "SUHasLaunchedBefore": True,
        "SUSendProfileInfo": False,
    }
    match = re.search(r'promoCampaignIdentifier\s*=\s*"([^"\\]+)"', app_constants_source or "")
    if match:
        values["iOSCompanionPromoCampaign"] = match.group(1)
    return values


# MARK: - macOS process probes


_MACOS = {}


def _macos():
    """ctypes handles for libproc and the mach timebase, loaded on first use."""
    if not _MACOS:
        import ctypes

        fields = [
            "user_time", "system_time", "pkg_idle_wkups", "interrupt_wkups", "pageins", "wired_size",
            "resident_size", "phys_footprint", "proc_start_abstime", "proc_exit_abstime",
            "child_user_time", "child_system_time", "child_pkg_idle_wkups", "child_interrupt_wkups",
            "child_pageins", "child_elapsed_abstime", "diskio_bytesread", "diskio_byteswritten",
            "cpu_time_qos_default", "cpu_time_qos_maintenance", "cpu_time_qos_background",
            "cpu_time_qos_utility", "cpu_time_qos_legacy", "cpu_time_qos_user_initiated",
            "cpu_time_qos_user_interactive", "billed_system_time", "serviced_system_time",
            "logical_writes", "lifetime_max_phys_footprint", "instructions", "cycles", "billed_energy",
            "serviced_energy", "interval_max_phys_footprint", "runnable_time",
        ]

        class RUsageV4(ctypes.Structure):
            _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in fields]

        class Timebase(ctypes.Structure):
            _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]

        system = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
        timebase = Timebase()
        system.mach_timebase_info(ctypes.byref(timebase))
        system.mach_host_self.restype = ctypes.c_uint32
        _MACOS.update(ctypes=ctypes, libproc=ctypes.CDLL("/usr/lib/libproc.dylib"), system=system,
                      host=system.mach_host_self(), fields=fields, RUsageV4=RUsageV4,
                      tick_ns=timebase.numer / timebase.denom)
    return _MACOS


def rusage(pid):
    mac = _macos()
    info = mac["RUsageV4"]()
    if mac["libproc"].proc_pid_rusage(int(pid), 4, mac["ctypes"].byref(info)) != 0:
        raise BenchmarkError(f"proc_pid_rusage failed for process {pid}")
    values = {name: getattr(info, name) for name in mac["fields"]}
    return {
        "cpu_ms": (values["user_time"] + values["system_time"]) * mac["tick_ns"] / 1e6,
        "footprint_mb": values["phys_footprint"] / 2**20,
        "peak_footprint_mb": values["lifetime_max_phys_footprint"] / 2**20,
        # Diagnostics: virtual machines may report no instruction counts.
        "instructions_g": values["instructions"] / 1e9,
        "runnable_ms": values["runnable_time"] * mac["tick_ns"] / 1e6,
    }


def cpu_ticks():
    """User, system, idle and nice ticks of all processors (host_statistics HOST_CPU_LOAD_INFO)."""
    mac = _macos()
    ctypes = mac["ctypes"]
    ticks = (ctypes.c_uint32 * 4)()
    count = ctypes.c_uint32(4)
    if mac["system"].host_statistics(mac["host"], 3, ticks, ctypes.byref(count)) != 0:
        raise BenchmarkError("host_statistics failed")
    return list(ticks)


def wait_for_quiet_system(threshold=0.85, timeout=20.0, interval=0.5):
    """Waits until the processors are idle enough, so background work such as indexing or a
    previous launch's helpers do not compete with the next launch. Returns the idle share."""
    deadline = time.monotonic() + timeout
    idle = 1.0
    while time.monotonic() < deadline:
        before = cpu_ticks()
        time.sleep(interval)
        after = cpu_ticks()
        total = sum(after) - sum(before)
        idle = (after[2] - before[2]) / total if total > 0 else 1.0
        if idle >= threshold:
            break
    return idle


def tick_ms():
    return _macos()["tick_ns"] / 1e6


def bundle_size_mb(app):
    total = 0
    for root, _, files in os.walk(app):
        for name in files:
            path = os.path.join(root, name)
            if not os.path.islink(path):
                total += os.path.getsize(path)
    return total / 2**20


def parse_log_timestamp(value):
    """Seconds since the epoch for `log` timestamps such as 2026-11-04 22:41:10.087151+0100."""
    return dt.datetime.strptime(value, "%Y-%m-%d %H:%M:%S.%f%z").timestamp()


def phase_durations(events, started, tick):
    """Milliseconds of the PHASES intervals in one process's signposts (`tick`: ms per mach tick)."""
    result = {}
    begins = {}
    for event in events:
        key = (event["name"], event["id"])
        if event["name"] == "Launch" and event["type"] == "begin":
            result["pre_main_ms"] = round((event["wall"] - started) * 1000, 1)
        if event["type"] == "begin":
            begins[key] = event["mach"]
        elif event["type"] == "end" and key in begins and event["name"] in PHASE_KEYS:
            duration = (event["mach"] - begins.pop(key)) * tick
            result[event["name"]] = round(result.get(event["name"], 0) + duration, 1)
    return result


class SignpostStream:
    """Collects the app's signposts from `log stream` while the benchmark runs."""

    def __init__(self, subsystem):
        self.events = {}
        self.condition = threading.Condition()
        predicate = f'subsystem == "{subsystem}" AND eventType == signpostEvent'
        self.process = subprocess.Popen(
            ["/usr/bin/log", "stream", "--signpost", "--style", "ndjson", "--predicate", predicate],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1,
        )
        self.thread = threading.Thread(target=self._read, daemon=True)
        self.thread.start()
        time.sleep(2)  # `log stream` delivers events only after it has connected

    def _read(self):
        for line in self.process.stdout:
            if not line.startswith("{"):
                continue
            try:
                entry = json.loads(line)
                event = {
                    "name": entry["signpostName"],
                    "type": entry["signpostType"],
                    "id": entry.get("signpostID"),
                    "wall": parse_log_timestamp(entry["timestamp"]),
                    "mach": entry["machTimestamp"],
                }
                pid = int(entry["processID"])
            except (KeyError, TypeError, ValueError):
                continue
            with self.condition:
                self.events.setdefault(pid, []).append(event)
                self.condition.notify_all()

    def wait_for(self, pid, name, timeout, process=None):
        deadline = time.monotonic() + timeout
        with self.condition:
            while True:
                for event in self.events.get(pid, ()):
                    if event["name"] == name:
                        return event
                remaining = deadline - time.monotonic()
                if remaining <= 0 or (process is not None and process.poll() is not None):
                    return None
                self.condition.wait(min(remaining, 0.5))

    def phases(self, pid, started):
        with self.condition:
            events = list(self.events.get(pid, ()))
        return phase_durations(events, started, tick_ms())

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()


def run(command, **kwargs):
    return subprocess.run(command, check=True, capture_output=True, text=True, **kwargs)


class AppBuild:
    def __init__(self, label, app, work, source):
        self.label = label
        self.app = Path(app).resolve()
        info = plistlib.loads((self.app / "Contents/Info.plist").read_bytes())
        self.bundle_id = info["CFBundleIdentifier"]
        # Both builds launch from the same path. With two copies of one bundle identifier in two
        # places, services such as LaunchServices answered the second copy more slowly, and the
        # identical app measured 100 to 250 ms slower in the service setup there.
        self.launch_app = Path(work) / "app" / self.app.name
        self.executable = self.launch_app / "Contents/MacOS" / info["CFBundleExecutable"]
        self.root = Path(work) / label
        self.home = self.root / "home"
        self.profile_home = self.root / "profile-home"
        self.profile_prefs = self.root / "profile.plist"
        self.logs = self.root / "logs"
        support_name = "TypeWhisper-Dev" if self.bundle_id.endswith(".dev") else "TypeWhisper"
        self.app_support = self.home / "Library/Application Support" / support_name
        # KeychainService prefixes its services with "<bundle identifier>.apikey.".
        self.api_token_service = f"{self.bundle_id}.apikey.local-api-token"
        self.defaults = profile_defaults(source)

    def write_preferences(self, values):
        path = self.root / "preferences.plist"
        path.write_bytes(plistlib.dumps(values))
        import_preferences(self.bundle_id, path)

    def delete_api_token(self):
        """The local API keeps its token in the login keychain. An item one unsigned build created
        makes macOS ask for permission when the other build reads it, which nobody answers in CI."""
        for _ in range(10):
            if subprocess.run(["security", "delete-generic-password", "-s", self.api_token_service],
                              capture_output=True).returncode != 0:
                return

    def install(self):
        """Clones this build to the shared launch path; every launch gets a fresh clone, whichever
        build ran before."""
        shutil.rmtree(self.launch_app, ignore_errors=True)
        self.launch_app.parent.mkdir(parents=True, exist_ok=True)
        run(["cp", "-cR", str(self.app), str(self.launch_app)])

    def start(self, log_name):
        self.install()
        log = open(self.logs / f"{log_name}.log", "w", encoding="utf-8")
        environment = dict(os.environ, CFFIXED_USER_HOME=str(self.home))
        started = time.time()
        process = subprocess.Popen([str(self.executable), *LAUNCH_ARGUMENTS], env=environment, stdout=log,
                                   stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, start_new_session=True)
        return Launch(self, process, started, log)


class Launch:
    def __init__(self, build, process, started, log):
        self.build = build
        self.process = process
        self.started = started
        self.log = log

    @property
    def pid(self):
        return self.process.pid

    def stop(self):
        if self.process.poll() is None:
            self.process.send_signal(signal.SIGTERM)
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=10)
        self.log.close()

    def log_tail(self, lines=30):
        self.log.flush()
        try:
            return "".join(Path(self.log.name).read_text(encoding="utf-8", errors="replace").splitlines(True)[-lines:])
        except OSError:
            return ""

    def failure(self, message):
        status = self.process.poll()
        if status is not None:
            message += f" (the app exited with status {status})"
        return BenchmarkError(f"{self.build.label}: {message}\n{self.log_tail()}")


class LocalAPI:
    def __init__(self, app_support):
        self.discovery = app_support / "api-discovery.json"

    def request(self, method, path, body=None, timeout=30):
        discovery = json.loads(self.discovery.read_text())
        headers = {"Content-Type": "application/json"}
        if discovery.get("token"):
            headers["Authorization"] = "Bearer " + discovery["token"]
        request = urllib.request.Request(f"http://127.0.0.1:{discovery['port']}{path}", data=body,
                                         method=method, headers=headers)
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read().decode()
        return json.loads(raw) if raw else {}

    def wait_until_ready(self, launch, timeout=API_TIMEOUT):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if launch.process.poll() is not None:
                break
            try:
                if self.discovery.exists():
                    self.request("GET", "/v1/status", timeout=5)
                    return
            except (OSError, ValueError, urllib.error.URLError):
                pass
            time.sleep(0.5)
        raise launch.failure("the local API did not answer")


def import_preferences(domain, path):
    """Replace the preferences of `domain`; `defaults import` alone would merge them."""
    subprocess.run(["defaults", "delete", domain], capture_output=True)
    run(["defaults", "import", domain, str(path)])


def export_preferences(domain):
    return plistlib.loads(subprocess.run(["defaults", "export", domain, "-"], check=True,
                                         capture_output=True).stdout)


def copy_tree(source, destination):
    shutil.rmtree(destination, ignore_errors=True)
    run(["ditto", str(source), str(destination)])


API_PREFERENCES = {"apiServerEnabled": True, "apiServerPort": API_PORT, "apiServerRequiresAuthentication": False}


def reset_build(build):
    shutil.rmtree(build.root, ignore_errors=True)
    build.home.mkdir(parents=True)
    build.logs.mkdir()
    build.delete_api_token()


def import_fixture(build, fixture):
    """Imports the test data through the local API of a fresh profile."""
    build.write_preferences({**build.defaults, **API_PREFERENCES})
    # The first launch of a new binary also pays for its first code-signing and malware scans.
    launch = build.start("profile-import")
    try:
        api = LocalAPI(build.app_support)
        api.wait_until_ready(launch)
        result = api.request("POST", "/v1/settings/import?mode=merge", json.dumps(fixture).encode(), timeout=900)
        expected = {"historyImported": len(fixture["history"]), "dictionaryImported": len(fixture["dictionaryEntries"]),
                    "snippetsImported": len(fixture["snippets"])}
        missing = {key: (result.get(key), count) for key, count in expected.items() if result.get(key) != count}
        if missing:
            raise launch.failure(f"the test profile import was incomplete: {missing}")
        time.sleep(3)
    finally:
        launch.stop()


def check_profile(build, stream, history, settle, log_name):
    """A launch on the profile that checks the history persisted. The first launch with data, or the
    first of a newer build, also runs one-time work such as migrations and statistics backfills."""
    launch = build.start(log_name)
    try:
        api = LocalAPI(build.app_support)
        api.wait_until_ready(launch)
        total = api.request("GET", "/v1/history?limit=1").get("total")
        if total != history:
            raise launch.failure(f"the profile has {total} history entries instead of {history}")
        if stream.wait_for(launch.pid, "Launch.firstIdle", FIRST_IDLE_TIMEOUT, launch.process) is None:
            raise launch.failure("no Launch.firstIdle signpost")
        time.sleep(settle)
    finally:
        launch.stop()
        build.delete_api_token()


def checkpoint_sqlite(folder):
    """Moves the write-ahead logs of the profile's stores into the stores. After the app was
    terminated they hold recent writes, and their size would differ between the two profiles."""
    for wal in Path(folder).rglob("*-wal"):
        store = wal.with_name(wal.name[:-len("-wal")])
        if store.is_file():
            subprocess.run(["/usr/bin/sqlite3", str(store), "PRAGMA wal_checkpoint(TRUNCATE);"],
                           capture_output=True, timeout=60)


def save_profile(build, home, prefs):
    """Keeps the profile at `home` and `prefs`. Measured launches run without the local API, as for
    most people."""
    preferences = export_preferences(build.bundle_id)
    preferences["apiServerEnabled"] = False
    prefs.write_bytes(plistlib.dumps(preferences))
    for name in ("api-discovery.json", "api-port"):
        (build.app_support / name).unlink(missing_ok=True)
    checkpoint_sqlite(build.home)
    copy_tree(build.home, home)


def prepare_profiles(base, head, stream, fixture, settle, work):
    """The base imports the test data. Then each build launches once on its own copy of that
    profile, so both profiles hold the same records, have seen the same number of launches and
    differ only by what the build changes on launch, such as a migration."""
    history = len(fixture["history"])
    shared_home, shared_prefs = Path(work) / "shared-profile", Path(work) / "shared-profile.plist"
    reset_build(base)
    reset_build(head)
    import_fixture(base, fixture)
    check_profile(base, stream, history, settle, "profile-first-launch")
    save_profile(base, shared_home, shared_prefs)
    preferences = plistlib.loads(shared_prefs.read_bytes())
    for build in (head, base):
        copy_tree(shared_home, build.home)
        build.write_preferences({**preferences, **build.defaults, **API_PREFERENCES})
        check_profile(build, stream, history, settle, "profile-check")
        save_profile(build, build.profile_home, build.profile_prefs)


def restore_profile(build):
    copy_tree(build.profile_home, build.home)
    import_preferences(build.bundle_id, build.profile_prefs)


def measure_launch(build, stream, settle, log_name):
    restore_profile(build)
    idle = wait_for_quiet_system()
    launch = build.start(log_name)
    try:
        event = stream.wait_for(launch.pid, "Launch.firstIdle", FIRST_IDLE_TIMEOUT, launch.process)
        if event is None:
            raise launch.failure("no Launch.firstIdle signpost")
        time.sleep(max(0.0, event["wall"] + settle - time.time()))
        if launch.process.poll() is not None:
            raise launch.failure("the app quit during the settle period")
        usage = rusage(launch.pid)
        sample = {
            "first_idle_ms": round((event["wall"] - launch.started) * 1000, 1),
            "cpu_ms": round(usage["cpu_ms"], 1),
            "footprint_mb": round(usage["footprint_mb"], 2),
            "peak_footprint_mb": round(usage["peak_footprint_mb"], 2),
            "phases": stream.phases(launch.pid, launch.started),
            "counters": {"instructions_g": round(usage["instructions_g"], 4), "runnable_ms": round(usage["runnable_ms"], 1),
                         "idle_before_pct": round(100 * idle, 1)},
        }
    finally:
        launch.stop()
    time.sleep(1)
    return sample


def measure_with_retry(build, stream, settle, log_name):
    try:
        return measure_launch(build, stream, settle, log_name)
    except BenchmarkError as error:
        print(f"Launch {log_name} of {build.label} failed, retrying once: {error}", flush=True)
        time.sleep(5)
        return measure_launch(build, stream, settle, f"{log_name}-retry")


def run_pass(builds, stream, rounds, settle, index):
    launches = {build.label: [] for build in builds}
    for round_index in range(rounds):
        order = builds if round_index % 2 == 0 else list(reversed(builds))
        for build in order:
            sample = measure_with_retry(build, stream, settle, f"pass{index}-round{round_index + 1}")
            launches[build.label].append(sample)
            print(f"pass {index} round {round_index + 1} {build.label}: "
                  + ", ".join(f"{metric.key}={sample[metric.key]}" for metric in METRICS), flush=True)
    return launches


def git_show(ref, path):
    if not ref:
        return None
    result = subprocess.run(["git", "show", f"{ref}:{path}"], capture_output=True, text=True)
    return result.stdout if result.returncode == 0 else None


def benchmark(args):
    base = AppBuild("base", args.base, args.work, git_show(args.base_source_ref, "TypeWhisper/App/AppConstants.swift"))
    head = AppBuild("head", args.head, args.work, git_show(args.head_source_ref, "TypeWhisper/App/AppConstants.swift"))
    if base.bundle_id != head.bundle_id:
        raise BenchmarkError(f"the builds have different bundle identifiers: {base.bundle_id}, {head.bundle_id}")
    running = subprocess.run(["pgrep", "-x", base.executable.name], capture_output=True, text=True).stdout.split()
    if running:
        raise BenchmarkError(f"{base.executable.name} is already running (process {', '.join(running)})")

    fixture = build_fixture(dt.datetime.now(dt.timezone.utc).replace(microsecond=0))
    stream = SignpostStream(base.bundle_id)
    try:
        print("Preparing the test profiles", flush=True)
        prepare_profiles(base, head, stream, fixture, args.settle, args.work)
        passes = []
        for index in (1, 2):
            if index == 2 and not (exceeded_metrics(passes) and args.confirm):
                break
            print(f"Pass {index}: {args.rounds} rounds", flush=True)
            launches = run_pass((base, head), stream, args.rounds, args.settle, index)
            passes.append({"base": metric_samples(launches["base"]), "head": metric_samples(launches["head"]),
                           **{key: {label: [launch[key] for launch in launches[label]] for label in ("base", "head")}
                              for key in ("phases", "counters")}})
    finally:
        stream.close()
        subprocess.run(["defaults", "delete", base.bundle_id], capture_output=True)

    return {
        "passes": passes,
        "regressions": exceeded_metrics(passes),
        "app_size_mb": {"base": round(bundle_size_mb(base.app), 2), "head": round(bundle_size_mb(head.app), 2)},
    }


def new_report(args):
    return {
        "schema": SCHEMA,
        "schema_version": SCHEMA_VERSION,
        "base": {"sha": args.base_sha},
        "head": {"sha": args.head_sha},
        "pull_request": args.pull_request,
        "fixture": dict(FIXTURE),
        "rounds": args.rounds,
        "settle_seconds": args.settle,
        "runner": {"macos": platform.mac_ver()[0] or None, "cpus": os.cpu_count()},
        "limits": {metric.key: {"pct": metric.limit_pct, "abs": metric.limit_abs} for metric in METRICS},
        "verdict": "error",
        "regressions": [],
        "passes": [],
        "app_size_mb": None,
        "error": None,
    }


def command_run(args):
    if not args.disposable_mac:
        print("run deletes the preferences of the builds' bundle identifier and imports a test profile.\n"
              "Run it only on a disposable Mac such as a CI runner, with --disposable-mac.", file=sys.stderr)
        return 2
    report = new_report(args)
    try:
        report.update(benchmark(args))
        report["verdict"] = "regression" if report["regressions"] else "pass"
    except Exception as error:  # every failure still writes a report for the pull request
        detail = error.stderr if isinstance(error, subprocess.CalledProcessError) else ""
        if isinstance(detail, bytes):
            detail = detail.decode(errors="replace")
        report["error"] = f"{type(error).__name__}: {error}\n{detail or ''}".strip()[-4000:]
        print(f"The launch benchmark failed: {report['error']}", file=sys.stderr)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=1) + "\n")
    print(render(report))
    return 0 if report["verdict"] != "error" else 1


# MARK: - Reports


HEX_SHA = re.compile(r"^[0-9a-f]{7,40}$")
MAX_SAMPLES = 200


def _is_number(value, high=1e9):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and 0 <= value <= high


def validate(report):
    """Raises ValueError unless `report` has the structure `run` writes. Reports can come from
    pull requests, so everything rendered from them is checked here."""
    def require(condition, message):
        if not condition:
            raise ValueError(message)

    require(isinstance(report, dict), "the report is not an object")
    require(report.get("schema") == SCHEMA and report.get("schema_version") == SCHEMA_VERSION,
            "unsupported report schema")
    for side in ("base", "head"):
        sha = (report.get(side) or {}).get("sha")
        require(sha is None or (isinstance(sha, str) and HEX_SHA.match(sha)), f"invalid {side} commit")
    number = report.get("pull_request")
    require(number is None or (isinstance(number, int) and not isinstance(number, bool) and 0 < number < 10**7),
            "invalid pull request number")
    require(report.get("verdict") in VERDICTS, "invalid verdict")
    require(isinstance(report.get("rounds"), int) and 0 < report["rounds"] <= 100, "invalid round count")
    require(_is_number(report.get("settle_seconds"), 600), "invalid settle time")
    fixture = report.get("fixture")
    require(isinstance(fixture, dict) and all(isinstance(fixture.get(key), int) and 0 <= fixture[key] <= 10**6
                                              for key in FIXTURE), "invalid fixture")
    limits = report.get("limits")
    require(isinstance(limits, dict), "invalid limits")
    for metric in METRICS:
        limit = limits.get(metric.key)
        require(isinstance(limit, dict) and _is_number(limit.get("pct"), 1000) and _is_number(limit.get("abs")),
                f"invalid limits for {metric.key}")
    regressions = report.get("regressions")
    require(isinstance(regressions, list) and all(key in METRIC_BY_KEY for key in regressions),
            "invalid regressions")
    passes = report.get("passes")
    require(isinstance(passes, list) and len(passes) <= 2, "invalid passes")
    require(passes or report["verdict"] == "error", "a finished report needs measurements")
    for measured in passes:
        require(isinstance(measured, dict), "invalid pass")
        lengths = set()
        for side in ("base", "head"):
            samples = measured.get(side)
            require(isinstance(samples, dict), "invalid samples")
            for metric in METRICS:
                values = samples.get(metric.key)
                require(isinstance(values, list) and 0 < len(values) <= MAX_SAMPLES
                        and all(_is_number(value) for value in values), f"invalid samples for {metric.key}")
                lengths.add(len(values))
        require(len(lengths) == 1, "every metric needs one sample per launch of both builds")
        phases = measured.get("phases")
        require(isinstance(phases, dict), "invalid phases")
        for side in ("base", "head"):
            launches = phases.get(side)
            require(isinstance(launches, list) and len(launches) <= MAX_SAMPLES, "invalid phases")
            for launch in launches:
                require(isinstance(launch, dict) and all(key in PHASE_KEYS and _is_number(value)
                                                         for key, value in launch.items()), "invalid phase values")
        counters = measured.get("counters", {"base": [], "head": []})
        require(isinstance(counters, dict), "invalid counters")
        for side in ("base", "head"):
            launches = counters.get(side)
            require(isinstance(launches, list) and len(launches) <= MAX_SAMPLES, "invalid counters")
            for launch in launches:
                require(isinstance(launch, dict) and all(key in COUNTER_KEYS and _is_number(value)
                                                         for key, value in launch.items()), "invalid counter values")
    sizes = report.get("app_size_mb")
    require(sizes is None or (isinstance(sizes, dict) and all(_is_number(sizes.get(side), 1e6)
                                                              for side in ("base", "head"))), "invalid app sizes")
    error = report.get("error")
    require(error is None or isinstance(error, str), "invalid error")


def _format_value(value, metric):
    return f"{value:,.{metric.decimals}f} {metric.unit}"


def _format_change(delta, pct, metric):
    sign = "+" if delta >= 0 else "-"
    return f"{sign}{abs(delta):,.{metric.decimals}f} {metric.unit} ({'+' if pct >= 0 else '-'}{abs(pct):.1f}%)"


def _combined(passes, side, key):
    return [value for measured in passes for value in measured[side][key]]


def render(report):
    """The Markdown section for the pull request description and the job summary."""
    validate(report)
    base_sha = (report["base"].get("sha") or "")[:7]
    head_sha = (report["head"].get("sha") or "")[:7]
    base_name = f"main `{base_sha}`" if base_sha else "main"
    head_name = f"this pull request `{head_sha}`" if head_sha else "this pull request"
    fixture = report["fixture"]
    lines = ["### Launch performance", ""]

    if report["verdict"] == "error" and not report["passes"]:
        lines.append(f"The launch benchmark of {head_name} against {base_name} failed before it measured "
                     "anything. The log of the `release-build` job has the details.")
        return "\n".join(lines)

    passes = report["passes"]
    launches = sum(len(measured["base"]["first_idle_ms"]) for measured in passes)
    lines.append(
        f"Measured in CI on one runner: {base_name} and {head_name}, {launches} alternating launches each "
        f"with a test profile of {fixture['history']:,} history entries, {fixture['dictionary']:,} dictionary "
        f"entries and {fixture['snippets']:,} snippets. Time until ready runs from the process start to the "
        f"app's first idle main thread; CPU time and memory are read {report['settle_seconds']:g} s later. "
        "The change is the median of the differences within each round. A metric fails when that change "
        f"exceeds both limits and this pull request was worse in at least {CONSISTENT_SHARE:.0%} of the "
        "rounds, in the first pass and in a confirmation pass.")
    lines += ["", "| Metric | main | This PR | Change | Worse in | Fails above |",
              "| --- | ---: | ---: | ---: | ---: | ---: |"]
    for metric in METRICS:
        result = evaluate(metric, _combined(passes, "base", metric.key), _combined(passes, "head", metric.key))
        limit = report["limits"][metric.key]
        marker = " **(regression)**" if metric.key in report["regressions"] else ""
        lines.append(f"| {metric.label} | {_format_value(result['base'], metric)} | "
                     f"{_format_value(result['head'], metric)} | {_format_change(result['delta'], result['pct'], metric)}"
                     f"{marker} | {result['worse']} of {result['rounds']} rounds | "
                     f"+{limit['pct']:g}% and +{limit['abs']:g} {metric.unit} |")
    sizes = report.get("app_size_mb")
    if sizes:
        delta = sizes["head"] - sizes["base"]
        pct = 100.0 * delta / sizes["base"] if sizes["base"] else 0.0
        lines.append(f"| {SIZE_METRIC.label} | {_format_value(sizes['base'], SIZE_METRIC)} | "
                     f"{_format_value(sizes['head'], SIZE_METRIC)} | {_format_change(delta, pct, SIZE_METRIC)} | | |")

    detail_rows = []
    for group, rows in (("phases", [(key, label, " ms", 0) for key, label in PHASES]), ("counters", COUNTERS)):
        for key, label, unit, decimals in rows:
            base = [launch[key] for measured in passes for launch in measured.get(group, {}).get("base", ()) if key in launch]
            head = [launch[key] for measured in passes for launch in measured.get(group, {}).get("head", ()) if key in launch]
            if not base or not head or (key == "instructions_g" and not (all(base) and all(head))):
                continue
            base_median, head_median = statistics.median(base), statistics.median(head)
            sign = "+" if head_median >= base_median else "-"
            detail_rows.append(f"| {label} | {base_median:,.{decimals}f}{unit} | {head_median:,.{decimals}f}{unit} | "
                               f"{sign}{abs(head_median - base_median):,.{decimals}f}{unit} |")
    if detail_rows:
        lines += ["", "<details><summary>Launch phases and runner conditions (medians)</summary>", "",
                  "| | main | This PR | Change |", "| --- | ---: | ---: | ---: |", *detail_rows, "", "</details>"]

    lines.append("")
    names = [METRIC_BY_KEY[key].label.lower() for key in report["regressions"]]
    regressed = names[0] if len(names) == 1 else ", ".join(names[:-1]) + " and " + names[-1] if names else ""
    confirmed = " in both passes" if len(passes) > 1 else ""
    if report["verdict"] == "pass":
        lines.append("**Result:** no launch regression.")
    elif report["verdict"] == "accepted":
        lines.append(f"**Result:** regression in {regressed}{confirmed}, accepted with the `{ACCEPT_LABEL}` label.")
    elif report["verdict"] == "regression":
        lines.append(f"**Result:** regression in {regressed}{confirmed}. Fix it, or explain in the description why "
                     f"the cost is needed, add the `{ACCEPT_LABEL}` label and re-run the `release-build` job.")
    else:
        lines.append("**Result:** the launch benchmark failed after these launches. The log of the "
                     "`release-build` job has the details.")
    return "\n".join(lines)


def load_report(path):
    report = json.loads(Path(path).read_text(encoding="utf-8"))
    validate(report)
    return report


def command_check(args):
    report = load_report(args.report)
    accepted = args.accepted == "true"
    if report["verdict"] == "regression" and accepted:
        report["verdict"] = "accepted"
    args.report.write_text(json.dumps(report, indent=1) + "\n")
    markdown = render(report)
    if report["verdict"] == "error" and report.get("error"):
        markdown += "\n\n<details><summary>Error</summary>\n\n```text\n" + report["error"].replace("```", "'''") + "\n```\n\n</details>"
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as summary:
            summary.write(markdown + "\n")
    print(markdown)
    if report["verdict"] == "regression":
        labels = ", ".join(METRIC_BY_KEY[key].label for key in report["regressions"])
        print(f"::error title=Launch regression::{labels} got worse than the limits allow. Fix it, or add the "
              f"{ACCEPT_LABEL} label with a reason in the description and re-run the job.")
        return 1
    if report["verdict"] == "error":
        print("::error title=Launch benchmark failed::The launch benchmark did not finish; see the log above.")
        return 1
    return 0


def command_render(args):
    print(render(load_report(args.report)))
    return 0


def command_fixture(args):
    args.output.write_text(json.dumps(build_fixture(dt.datetime.now(dt.timezone.utc).replace(microsecond=0)),
                                      indent=1) + "\n")
    return 0


def command_pr_number(args):
    number = load_report(args.report).get("pull_request")
    if number is None:
        print("The report names no pull request", file=sys.stderr)
        return 1
    print(number)
    return 0


def merge_section(body, section):
    """`body` with the CI section replaced, or appended when it has none yet."""
    block = f"{SECTION_START}\n{SECTION_NOTE}\n{section}\n{SECTION_END}"
    pattern = re.compile(re.escape(SECTION_START) + r".*?" + re.escape(SECTION_END), re.S)
    if pattern.search(body):
        return pattern.sub(lambda _: block, body, count=1)
    body = body.rstrip()
    return f"{body}\n\n{block}\n" if body else f"{block}\n"


def command_update_description(args):
    body = args.body.read_text(encoding="utf-8")
    merged = merge_section(body, render(load_report(args.report)))
    if merged.strip() == body.strip():
        print("unchanged")
        return 0
    args.output.write_text(json.dumps({"body": merged}) + "\n", encoding="utf-8")
    print("changed")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)

    command = commands.add_parser("run", help="measure two builds")
    command.add_argument("--base", required=True, type=Path)
    command.add_argument("--head", required=True, type=Path)
    command.add_argument("--work", required=True, type=Path)
    command.add_argument("--output", required=True, type=Path)
    command.add_argument("--base-sha")
    command.add_argument("--head-sha")
    command.add_argument("--base-source-ref", help="git ref whose sources the base was built from")
    command.add_argument("--head-source-ref", help="git ref whose sources the head was built from")
    command.add_argument("--pull-request", type=int)
    command.add_argument("--rounds", type=int, default=ROUNDS)
    command.add_argument("--settle", type=float, default=SETTLE_SECONDS)
    command.add_argument("--no-confirm", dest="confirm", action="store_false",
                         help="skip the confirmation pass after a regression")
    command.add_argument("--disposable-mac", action="store_true",
                         help="confirm that this Mac's preferences for the app may be deleted")
    command.set_defaults(handler=command_run)

    command = commands.add_parser("check", help="apply the label and fail on a regression")
    command.add_argument("report", type=Path)
    command.add_argument("--accepted", choices=("true", "false"), required=True)
    command.add_argument("--summary", type=Path)
    command.set_defaults(handler=command_check)

    command = commands.add_parser("render", help="print the Markdown section")
    command.add_argument("report", type=Path)
    command.set_defaults(handler=command_render)

    command = commands.add_parser("fixture", help="write the test profile backup")
    command.add_argument("output", type=Path)
    command.set_defaults(handler=command_fixture)

    command = commands.add_parser("pr-number", help="print the pull request number of a report")
    command.add_argument("report", type=Path)
    command.set_defaults(handler=command_pr_number)

    command = commands.add_parser("update-description", help="write the description update as a JSON payload")
    command.add_argument("report", type=Path)
    command.add_argument("--body", required=True, type=Path)
    command.add_argument("--output", required=True, type=Path)
    command.set_defaults(handler=command_update_description)

    args = parser.parse_args(argv)
    if args.command == "run":
        for sha in (args.base_sha, args.head_sha):
            if sha is not None and not HEX_SHA.match(sha):
                parser.error(f"not a commit SHA: {sha}")
    return args.handler(args)


if __name__ == "__main__":
    sys.exit(main())
