// Turning on the microphone button needs access to all websites. Chrome closes
// the popup while it asks for that access, so nothing after the request runs
// in the popup. The wish is stored first; the service worker registers the
// button once Chrome reports the new permission.

export const ALL_SITES = { origins: ["<all_urls>"] };

/**
 * Stores the wish and asks for access in the same task, so the request still
 * counts as a reaction to the click.
 * @param {typeof chrome} api
 * @returns {Promise<boolean>} Whether access was granted, if the popup is still open to hear it.
 */
export function enableMicButton(api) {
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
export async function reconcileMicButton(api) {
  const { showMicButton } = await api.storage.local.get("showMicButton");
  if (!showMicButton) return false;
  const granted = await api.permissions.contains(ALL_SITES);
  if (!granted) await api.storage.local.set({ showMicButton: false });
  return granted;
}
