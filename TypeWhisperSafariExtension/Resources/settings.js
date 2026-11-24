// Settings and connection state shared by the service worker and the popup.

import { DEFAULT_PORT } from "./api.js";

export const DEFAULT_SETTINGS = {
  port: DEFAULT_PORT,
  token: "",
  reportContext: true,
  showMicButton: false,
};

/**
 * The settings, with the API port and token from TypeWhisper when it hands them over.
 * `fromApp` tells the popup that nobody has to enter them.
 */
export async function getSettings() {
  const stored = await chrome.storage.local.get(Object.keys(DEFAULT_SETTINGS));
  const settings = { ...DEFAULT_SETTINGS, ...stored, fromApp: false };
  const connection = await getAppConnection();
  return connection ? { ...settings, ...connection, fromApp: true } : settings;
}

/**
 * Whether this package runs inside TypeWhisper for Mac, which is the Safari package.
 * It stays true while TypeWhisper is not running, unlike a successful app connection.
 */
export function hasAppMessaging(runtime = defaultRuntime()) {
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
export async function getAppConnection(runtime = defaultRuntime()) {
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

export function saveSettings(changes) {
  return chrome.storage.local.set(changes);
}

/** A random id that lets TypeWhisper tell this browser's reports apart from others. */
export async function getClientId() {
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
export function setConnectionStatus(status) {
  return chrome.storage.session.set({ connectionStatus: { ...status, at: Date.now() } });
}

export async function getConnectionStatus() {
  const { connectionStatus } = await chrome.storage.session.get("connectionStatus");
  return connectionStatus ?? null;
}
