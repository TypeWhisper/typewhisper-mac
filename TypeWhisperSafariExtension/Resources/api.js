// Client for the TypeWhisper local HTTP API. The extension's host permissions
// for 127.0.0.1 let the service worker and popup call it without CORS headers.

export const DEFAULT_PORT = 8978;

export class APIError extends Error {
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
export async function apiRequest(connection, method, path, options = {}) {
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

export function getStatus(connection, options) {
  return apiRequest(connection, "GET", "/v1/status", options);
}

export function getDictationStatus(connection, options) {
  return apiRequest(connection, "GET", "/v1/dictation/status", options);
}

export function startDictation(connection, options) {
  // The app answers once the microphone records, which can take a few seconds
  // for Bluetooth headsets.
  return apiRequest(connection, "POST", "/v1/dictation/start", { timeoutMs: 20000, ...options });
}

export function stopDictation(connection, options) {
  return apiRequest(connection, "POST", "/v1/dictation/stop", options);
}

export function putBrowserContext(connection, report, options) {
  return apiRequest(connection, "PUT", "/v1/browser/context", { body: report, ...options });
}
