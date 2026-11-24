// api.js
// Client for the TypeWhisper local HTTP API. The extension's host permissions
// for 127.0.0.1 let the service worker and popup call it without CORS headers.

const DEFAULT_PORT = 8978;

class APIError extends Error {
  /**
   * @param {"offline" | "unauthorized" | "unsupported" | "conflict" | "http"} kind
   * @param {string} message
   * @param {number} [status]
   */
  constructor(kind, message, status) {
    super(message);
    this.name = "APIError";
    this.kind = kind;
    this.status = status;
  }
}

/**
 * @param {{ port?: number, token?: string }} connection
 * @param {string} method
 * @param {string} path
 * @param {{ body?: unknown, timeoutMs?: number, fetchImpl?: typeof fetch }} [options]
 */
async function apiRequest(connection, method, path, options = {}) {
  const { body, timeoutMs = 5000, fetchImpl = fetch } = options;
  const port = connection.port || DEFAULT_PORT;
  const headers = {};
  if (connection.token) headers.Authorization = `Bearer ${connection.token}`;
  if (body !== undefined) headers["Content-Type"] = "application/json";

  let response;
  try {
    response = await fetchImpl(`http://127.0.0.1:${port}${path}`, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(timeoutMs),
    });
  } catch {
    throw new APIError("offline", "TypeWhisper is not reachable");
  }

  const text = await response.text();
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    json = null;
  }
  if (response.ok) return json;

  const message = json?.error?.message || `HTTP ${response.status}`;
  if (response.status === 401) throw new APIError("unauthorized", message, 401);
  if (response.status === 404) throw new APIError("unsupported", message, 404);
  if (response.status === 409) throw new APIError("conflict", message, 409);
  throw new APIError("http", message, response.status);
}

function getStatus(connection, options) {
  return apiRequest(connection, "GET", "/v1/status", options);
}

function getDictationStatus(connection, options) {
  return apiRequest(connection, "GET", "/v1/dictation/status", options);
}

function startDictation(connection, options) {
  // The app answers once the microphone records, which can take a few seconds
  // for Bluetooth headsets.
  return apiRequest(connection, "POST", "/v1/dictation/start", { timeoutMs: 20000, ...options });
}

function stopDictation(connection, options) {
  return apiRequest(connection, "POST", "/v1/dictation/stop", options);
}

function putBrowserContext(connection, report, options) {
  return apiRequest(connection, "PUT", "/v1/browser/context", { body: report, ...options });
}

// context.js
// Decides what the extension tells TypeWhisper about the active tab.

/** TypeWhisper drops a report after three minutes, so it is repeated well before. */
const REFRESH_INTERVAL_MS = 55_000;

/**
 * @param {string} clientId
 * @param {{ focused?: boolean } | null | undefined} window The last focused browser window.
 * @param {{ url?: string, title?: string, incognito?: boolean } | null | undefined} tab
 *   The active tab of that window.
 */
function buildReport(clientId, window, tab) {
  if (!window?.focused) {
    return { client_id: clientId, focused: false };
  }
  // Private windows report that no website is open instead of the real one.
  if (!tab || tab.incognito) {
    return { client_id: clientId, focused: true, url: null, title: null };
  }
  return {
    client_id: clientId,
    focused: true,
    url: tab.url || null,
    title: tab.title || null,
  };
}

/**
 * @param {{ report: object, sentAt: number } | null | undefined} previous The last report sent.
 * @param {object} next
 * @param {number} now
 */
function shouldSend(previous, next, now) {
  if (!previous) return true;
  if (!sameReport(previous.report, next)) return true;
  return next.focused === true && now - previous.sentAt >= REFRESH_INTERVAL_MS;
}

function sameReport(a, b) {
  return (
    a.client_id === b.client_id &&
    a.focused === b.focused &&
    (a.url ?? null) === (b.url ?? null) &&
    (a.title ?? null) === (b.title ?? null)
  );
}

// mic-setting.js
// Turning on the microphone button needs access to all websites. Chrome closes
// the popup while it asks for that access, so nothing after the request runs
// in the popup. The wish is stored first; the service worker registers the
// button once Chrome reports the new permission.

const ALL_SITES = { origins: ["<all_urls>"] };

/**
 * Stores the wish and asks for access in the same task, so the request still
 * counts as a reaction to the click.
 * @param {typeof chrome} api
 * @returns {Promise<boolean>} Whether access was granted, if the popup is still open to hear it.
 */
function enableMicButton(api) {
  const saved = api.storage.local.set({ showMicButton: true });
  const requested = api.permissions.request(ALL_SITES);
  return Promise.all([saved, requested]).then(async ([, granted]) => {
    if (!granted) await api.storage.local.set({ showMicButton: false });
    return granted;
  });
}

/**
 * Settles a stored wish that never got access, for example because the
 * request was declined after the popup closed.
 * @param {typeof chrome} api
 * @returns {Promise<boolean>} Whether the button is on.
 */
async function reconcileMicButton(api) {
  const { showMicButton } = await api.storage.local.get("showMicButton");
  if (!showMicButton) return false;
  const granted = await api.permissions.contains(ALL_SITES);
  if (!granted) await api.storage.local.set({ showMicButton: false });
  return granted;
}

// settings.js
// Settings and connection state shared by the service worker and the popup.


const DEFAULT_SETTINGS = {
  port: DEFAULT_PORT,
  token: "",
  reportContext: true,
  showMicButton: false,
};

/**
 * The settings, with the API port and token from TypeWhisper when it hands them over.
 * `fromApp` tells the popup that nobody has to enter them.
 */
async function getSettings() {
  const stored = await chrome.storage.local.get(Object.keys(DEFAULT_SETTINGS));
  const settings = { ...DEFAULT_SETTINGS, ...stored, fromApp: false };
  const connection = await getAppConnection();
  return connection ? { ...settings, ...connection, fromApp: true } : settings;
}

/**
 * Whether this package runs inside TypeWhisper for Mac, which is the Safari package.
 * It stays true while TypeWhisper is not running, unlike a successful app connection.
 */
function hasAppMessaging(runtime = defaultRuntime()) {
  return typeof runtime?.sendNativeMessage === "function";
}

function defaultRuntime() {
  return globalThis.browser?.runtime ?? chrome.runtime;
}

/**
 * In Safari the extension ships inside TypeWhisper for Mac, whose extension handler returns
 * the port and token of the running API server. Chrome and Firefox packages do not request
 * native messaging, so their runtime has no `sendNativeMessage` and this returns null.
 * It also returns null while TypeWhisper is not running or its API server is off.
 */
async function getAppConnection(runtime = defaultRuntime()) {
  if (!hasAppMessaging(runtime)) return null;
  let reply;
  try {
    reply = await runtime.sendNativeMessage("com.typewhisper.mac", { type: "connection" });
  } catch {
    return null;
  }
  const port = reply?.port;
  const token = reply?.token;
  if (!Number.isInteger(port) || port <= 0 || port >= 65536 || typeof token !== "string") return null;
  return { port, token };
}

function saveSettings(changes) {
  return chrome.storage.local.set(changes);
}

/** A random id that lets TypeWhisper tell this browser's reports apart from others. */
async function getClientId() {
  const { clientId } = await chrome.storage.local.get("clientId");
  if (clientId) return clientId;
  const created = crypto.randomUUID();
  await chrome.storage.local.set({ clientId: created });
  return created;
}

/**
 * The outcome of the last API call, shown in the popup.
 * @param {{ state: "connected" | "offline" | "unauthorized" | "unsupported" | "error", message?: string }} status
 */
function setConnectionStatus(status) {
  return chrome.storage.session.set({ connectionStatus: { ...status, at: Date.now() } });
}

async function getConnectionStatus() {
  const { connectionStatus } = await chrome.storage.session.get("connectionStatus");
  return connectionStatus ?? null;
}

// background.js

const REFRESH_ALARM = "refresh-context";
const MENU_ID = "toggle-dictation";
const MIC_SCRIPT_ID = "mic-button";
const RECORDING_POLL_MS = 1000;
const RECORDING_POLL_LIMIT = 30 * 60;

// MARK: - Setup

chrome.runtime.onInstalled.addListener(() => {
  void setUp();
});

chrome.runtime.onStartup.addListener(() => {
  void setUp();
});

async function setUp() {
  // A dictation cannot outlive the browser session that started it.
  await chrome.storage.local.set({ recording: false });
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({
      id: MENU_ID,
      title: chrome.i18n.getMessage("menuStartDictation"),
      contexts: ["editable"],
    });
  });
  await chrome.alarms.create(REFRESH_ALARM, { periodInMinutes: 1 });
  await syncMicButton();
  queueContextReport();
}

// MARK: - Active tab reporting

let reportQueue = Promise.resolve();

/** Reports run one after another so TypeWhisper receives them in order. */
function queueContextReport() {
  reportQueue = reportQueue.then(reportContext, reportContext);
  return reportQueue;
}

async function reportContext() {
  const settings = await getSettings();
  const clientId = await getClientId();
  let report;
  if (settings.reportContext) {
    const window = await chrome.windows.getLastFocused().catch(() => null);
    let tab = null;
    if (window?.focused) {
      [tab] = await chrome.tabs.query({ active: true, windowId: window.id });
    }
    report = buildReport(clientId, window, tab);
  } else {
    // Clears what this browser reported before the setting was turned off.
    report = buildReport(clientId, null, null);
  }

  const { lastReport } = await chrome.storage.session.get("lastReport");
  const now = Date.now();
  if (!shouldSend(lastReport, report, now)) return;

  try {
    await putBrowserContext(settings, report);
    await chrome.storage.session.set({ lastReport: { report, sentAt: now } });
    await setConnectionStatus({ state: "connected" });
  } catch (error) {
    await recordError(error);
  }
}

chrome.windows.onFocusChanged.addListener(() => {
  queueContextReport();
});

chrome.tabs.onActivated.addListener(() => {
  queueContextReport();
});

chrome.tabs.onUpdated.addListener((_tabId, changeInfo, tab) => {
  if (tab.active && (changeInfo.url || changeInfo.title || changeInfo.status === "complete")) {
    queueContextReport();
  }
});

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === REFRESH_ALARM) queueContextReport();
});

// MARK: - Dictation

chrome.commands.onCommand.addListener((command) => {
  if (command === "toggle-dictation") void toggleDictation();
});

chrome.contextMenus.onClicked.addListener((info) => {
  if (info.menuItemId === MENU_ID) void toggleDictation();
});

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type === "toggle-dictation") {
    toggleDictation().then(sendResponse);
    return true;
  }
  if (message?.type === "report-context") {
    queueContextReport().then(() => sendResponse({ ok: true }));
    return true;
  }
  return false;
});

let toggleInFlight = null;

/**
 * Starts a dictation, or stops the running one. TypeWhisper inserts the text
 * into the focused field, as it does for its own hotkey.
 */
function toggleDictation() {
  toggleInFlight ??= performToggle().finally(() => {
    toggleInFlight = null;
  });
  return toggleInFlight;
}

async function performToggle() {
  const settings = await getSettings();
  // TypeWhisper picks the workflow for the website when the dictation starts.
  await queueContextReport();
  try {
    const status = await getDictationStatus(settings);
    if (status?.is_recording) {
      await stopDictation(settings);
      await setRecording(false);
      return { ok: true, recording: false };
    }
    await startDictation(settings);
    await setConnectionStatus({ state: "connected" });
    await setRecording(true);
    void watchRecording(settings);
    return { ok: true, recording: true };
  } catch (error) {
    await recordError(error);
    return { ok: false, error: errorMessage(error) };
  }
}

/** Follows a dictation that may also be stopped by TypeWhisper's own hotkey or overlay. */
async function watchRecording(settings) {
  for (let attempt = 0; attempt < RECORDING_POLL_LIMIT; attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, RECORDING_POLL_MS));
    try {
      const status = await getDictationStatus(settings);
      if (!status?.is_recording) break;
    } catch {
      break;
    }
  }
  await setRecording(false);
}

async function setRecording(recording) {
  // Content scripts draw the microphone button from this value. It lives in local storage
  // because Firefox does not share session storage with content scripts, and that also keeps
  // the reported tab address in session storage away from web pages' content scripts.
  await chrome.storage.local.set({ recording });
  await chrome.action.setBadgeBackgroundColor({ color: "#d93025" });
  await chrome.action.setBadgeText({ text: recording ? "REC" : "" });
  chrome.contextMenus.update(MENU_ID, {
    title: chrome.i18n.getMessage(recording ? "menuStopDictation" : "menuStartDictation"),
  });
}

// MARK: - Errors

async function recordError(error) {
  const state = error instanceof APIError
    ? { offline: "offline", unauthorized: "unauthorized", unsupported: "unsupported" }[error.kind] ?? "error"
    : "error";
  await setConnectionStatus({ state, message: errorMessage(error) });
}

function errorMessage(error) {
  if (error instanceof APIError) {
    switch (error.kind) {
      case "offline":
        return chrome.i18n.getMessage("errorOffline");
      case "unauthorized":
        return chrome.i18n.getMessage("errorUnauthorized");
      case "unsupported":
        return chrome.i18n.getMessage("errorUnsupported");
      default:
        return error.message;
    }
  }
  return String(error?.message ?? error);
}

// MARK: - Microphone button

async function syncMicButton() {
  const { showMicButton } = await getSettings();
  const granted = await chrome.permissions.contains(ALL_SITES);
  const registered = await chrome.scripting.getRegisteredContentScripts({ ids: [MIC_SCRIPT_ID] });
  if (showMicButton && granted) {
    if (registered.length === 0) {
      await chrome.scripting.registerContentScripts([
        {
          id: MIC_SCRIPT_ID,
          matches: ["<all_urls>"],
          js: ["content/mic-button.js"],
          allFrames: true,
          runAt: "document_idle",
        },
      ]);
      await injectIntoOpenTabs();
    }
  } else if (registered.length > 0) {
    await chrome.scripting.unregisterContentScripts({ ids: [MIC_SCRIPT_ID] });
  }
}

/** Registered scripts only reach pages loaded afterwards. */
async function injectIntoOpenTabs() {
  const tabs = await chrome.tabs.query({ url: ["http://*/*", "https://*/*"] });
  await Promise.all(
    tabs.map((tab) =>
      chrome.scripting
        .executeScript({ target: { tabId: tab.id, allFrames: true }, files: ["content/mic-button.js"] })
        .catch(() => {}),
    ),
  );
}

chrome.storage.onChanged.addListener((changes, area) => {
  if (area !== "local") return;
  if (changes.showMicButton) void syncMicButton();
  if (changes.reportContext || changes.port || changes.token) {
    // Settings changes must reach TypeWhisper right away, not after the next refresh.
    chrome.storage.session.remove("lastReport").then(queueContextReport);
  }
});

// The popup closes while Chrome asks for access, so the button is registered here.
chrome.permissions.onAdded.addListener(() => void syncMicButton());
chrome.permissions.onRemoved.addListener(() => void syncMicButton());

// The end-to-end test drives the worker through these functions.
globalThis.typewhisper = { toggleDictation, queueContextReport, isToggling: () => toggleInFlight !== null };
