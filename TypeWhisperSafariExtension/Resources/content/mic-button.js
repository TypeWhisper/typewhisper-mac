// Shows a microphone button in the focused text field. Clicking it starts or
// stops a TypeWhisper dictation; TypeWhisper inserts the text into the field.

(() => {
  if (window.__typewhisperMicButton) return;
  window.__typewhisperMicButton = true;

  const TEXT_INPUT_TYPES = new Set(["", "text", "search", "email", "url", "tel"]);
  const BUTTON_SIZE = 24;
  const EDGE_INSET = 6;
  // Fields up to this height hold one line of text, so the button is centered.
  const MAX_SINGLE_LINE_HEIGHT = 48;

  let field = null;
  let recording = false;
  let busy = false;
  let errorTimer = null;

  const host = document.createElement("typewhisper-mic");
  host.style.cssText = "all: initial; position: fixed; z-index: 2147483647; display: none;";
  const shadow = host.attachShadow({ mode: "closed" });
  const SVG_NS = "http://www.w3.org/2000/svg";

  const style = document.createElement("style");
  style.textContent = `
    button {
      all: initial;
      box-sizing: border-box;
      width: ${BUTTON_SIZE}px;
      height: ${BUTTON_SIZE}px;
      border-radius: 50%;
      display: grid;
      place-items: center;
      cursor: pointer;
      background: #ffffff;
      color: #3c4043;
      box-shadow: 0 1px 3px rgba(0, 0, 0, 0.3);
      transition: background 120ms ease, color 120ms ease;
    }
    button:hover { background: #f1f3f4; }
    button:focus-visible { outline: 2px solid #1a73e8; outline-offset: 2px; }
    button[data-state="recording"] { background: #d93025; color: #ffffff; }
    button[data-state="busy"] { opacity: 0.6; cursor: progress; }
    button[data-state="error"] { background: #f9ab00; color: #202124; }
    svg { width: 14px; height: 14px; display: block; }
    @media (prefers-color-scheme: dark) {
      button { background: #3c4043; color: #e8eaed; }
      button:hover { background: #5f6368; }
    }
    @media (prefers-reduced-motion: reduce) { button { transition: none; } }`;

  const icon = document.createElementNS(SVG_NS, "svg");
  icon.setAttribute("viewBox", "0 0 24 24");
  icon.setAttribute("fill", "currentColor");
  icon.setAttribute("aria-hidden", "true");
  const iconPath = document.createElementNS(SVG_NS, "path");
  iconPath.setAttribute(
    "d",
    "M12 15a3 3 0 0 0 3-3V6a3 3 0 0 0-6 0v6a3 3 0 0 0 3 3Zm5-3a5 5 0 0 1-10 0H5a7 7 0 0 0 6 6.92V21h2v-2.08A7 7 0 0 0 19 12h-2Z",
  );
  icon.append(iconPath);

  const button = document.createElement("button");
  button.type = "button";
  button.append(icon);
  shadow.append(style, button);

  function isEditable(element) {
    if (!(element instanceof HTMLElement)) return false;
    if (element.matches("[disabled], [readonly]")) return false;
    if (element instanceof HTMLTextAreaElement) return true;
    if (element instanceof HTMLInputElement) {
      return TEXT_INPUT_TYPES.has(element.type.toLowerCase());
    }
    return element.isContentEditable;
  }

  function updateLabel() {
    const key = recording ? "buttonStopDictation" : "buttonStartDictation";
    const label = chrome.i18n.getMessage(key);
    button.setAttribute("aria-label", label);
    button.title = label;
  }

  function render(state) {
    button.dataset.state = state ?? (busy ? "busy" : recording ? "recording" : "idle");
    updateLabel();
  }

  function place() {
    if (!field || !field.isConnected) {
      hide();
      return;
    }
    const rect = field.getBoundingClientRect();
    if (rect.width < BUTTON_SIZE * 3 || rect.height < BUTTON_SIZE - 6) {
      host.style.display = "none";
      return;
    }
    // Single-line fields center the button, even when it is taller than the field.
    // Taller fields keep it in the top right corner, next to the first line.
    const singleLine = field instanceof HTMLInputElement || rect.height <= MAX_SINGLE_LINE_HEIGHT;
    const top = singleLine ? rect.top + (rect.height - BUTTON_SIZE) / 2 : rect.top + EDGE_INSET;
    host.style.left = `${Math.round(rect.right - BUTTON_SIZE - EDGE_INSET)}px`;
    host.style.top = `${Math.round(top)}px`;
    host.style.display = "block";
  }

  function show(element) {
    field = element;
    if (!host.isConnected) document.documentElement.appendChild(host);
    render();
    place();
  }

  function hide() {
    // A running dictation keeps the button visible so it can be stopped.
    if (recording) return;
    field = null;
    host.style.display = "none";
  }

  document.addEventListener(
    "focusin",
    (event) => {
      const target = event.composedPath()[0];
      if (isEditable(target)) show(target);
    },
    true,
  );

  document.addEventListener(
    "focusout",
    (event) => {
      if (event.composedPath()[0] === field) {
        // The new focus target is only known after the event.
        setTimeout(() => {
          if (!isEditable(document.activeElement)) hide();
        }, 0);
      }
    },
    true,
  );

  window.addEventListener("scroll", place, { capture: true, passive: true });
  window.addEventListener("resize", place, { passive: true });

  // Keeps the caret in the field: TypeWhisper inserts at the focused element.
  button.addEventListener("mousedown", (event) => event.preventDefault());

  button.addEventListener("click", async (event) => {
    event.preventDefault();
    event.stopPropagation();
    if (busy) return;
    field?.focus();
    busy = true;
    render();
    let response;
    try {
      response = await chrome.runtime.sendMessage({ type: "toggle-dictation" });
    } catch (error) {
      response = { ok: false, error: String(error?.message ?? error) };
    }
    busy = false;
    if (response?.ok) {
      recording = response.recording;
      render();
    } else {
      showError(response?.error);
    }
  });

  function showError(message) {
    render("error");
    button.title = message || chrome.i18n.getMessage("errorGeneric");
    clearTimeout(errorTimer);
    errorTimer = setTimeout(() => render(), 4000);
  }

  chrome.storage.local.get("recording").then(({ recording: value }) => {
    recording = Boolean(value);
    render();
  }).catch(() => {});

  chrome.storage.onChanged.addListener((changes, area) => {
    if (area === "local" && changes.recording) {
      recording = Boolean(changes.recording.newValue);
      render();
      if (!recording && !isEditable(document.activeElement)) hide();
    }
    if (area === "local" && changes.showMicButton && !changes.showMicButton.newValue) {
      field = null;
      host.remove();
    }
  });
})();
