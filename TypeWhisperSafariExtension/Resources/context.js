// Decides what the extension tells TypeWhisper about the active tab.

/** TypeWhisper drops a report after three minutes, so it is repeated well before. */
export const REFRESH_INTERVAL_MS = 55_000;

/**
 * @param {string} clientId
 * @param {{ focused?: boolean } | null | undefined} window The last focused browser window.
 * @param {{ url?: string, title?: string, incognito?: boolean } | null | undefined} tab
 *   The active tab of that window.
 */
export function buildReport(clientId, window, tab) {
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
export function shouldSend(previous, next, now) {
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
