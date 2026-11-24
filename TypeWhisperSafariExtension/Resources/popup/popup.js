import { APIError, getDictationStatus, getStatus } from "../api.js";
import { enableMicButton, reconcileMicButton } from "../mic-setting.js";
import { getSettings, saveSettings, setConnectionStatus } from "../settings.js";

const message = (key, substitutions) => chrome.i18n.getMessage(key, substitutions);

for (const element of document.querySelectorAll("[data-i18n]")) {
  element.textContent = message(element.dataset.i18n);
}

const statusElement = document.getElementById("status");
const tokenInput = document.getElementById("token");
const portInput = document.getElementById("port");
const reportContextInput = document.getElementById("reportContext");
const showMicButtonInput = document.getElementById("showMicButton");

function showStatus(state, text) {
  statusElement.dataset.state = state;
  statusElement.textContent = text;
}

async function checkConnection() {
  showStatus("checking", message("statusChecking"));
  const settings = await getSettings();
  let status;
  try {
    status = await getStatus(settings, { timeoutMs: 2000 });
    await getDictationStatus(settings, { timeoutMs: 2000 });
  } catch (error) {
    const kind = error instanceof APIError ? error.kind : "error";
    if (kind === "offline") {
      showStatus("offline", message("statusOffline"));
    } else if (kind === "unauthorized") {
      showStatus("unauthorized", message("statusUnauthorized"));
    } else {
      showStatus("error", error.message);
    }
    await setConnectionStatus({ state: kind === "offline" || kind === "unauthorized" ? kind : "error" });
    return;
  }

  if (status?.supports_browser_context !== true) {
    showStatus("unsupported", message("statusUnsupported"));
    await setConnectionStatus({ state: "unsupported" });
    return;
  }
  const model = status?.model ? message("statusModel", [status.model]) : "";
  showStatus("connected", `${message("statusConnected")}${model}`);
  await setConnectionStatus({ state: "connected" });
}

async function load() {
  const settings = await getSettings();
  tokenInput.value = settings.token;
  portInput.value = String(settings.port);
  // Safari gets the connection from TypeWhisper and lists shortcuts in its own settings.
  document.getElementById("connection").hidden = settings.fromApp;
  document.getElementById("editShortcut").hidden = settings.fromApp;
  reportContextInput.checked = settings.reportContext;
  showMicButtonInput.checked = await reconcileMicButton(chrome);

  const commands = await chrome.commands.getAll();
  const shortcut = commands.find((command) => command.name === "toggle-dictation")?.shortcut;
  document.getElementById("shortcut").textContent = shortcut
    ? message("labelShortcut", [shortcut])
    : message("labelNoShortcut");

  await checkConnection();
}

document.getElementById("connection").addEventListener("submit", async (event) => {
  event.preventDefault();
  const port = Number.parseInt(portInput.value, 10);
  await saveSettings({
    token: tokenInput.value.trim(),
    port: Number.isInteger(port) && port > 0 && port < 65536 ? port : 8978,
  });
  await checkConnection();
});

reportContextInput.addEventListener("change", () => {
  void saveSettings({ reportContext: reportContextInput.checked });
});

showMicButtonInput.addEventListener("change", async () => {
  if (!showMicButtonInput.checked) {
    await saveSettings({ showMicButton: false });
    return;
  }
  showMicButtonInput.checked = await enableMicButton(chrome);
});

document.getElementById("editShortcut").addEventListener("click", (event) => {
  event.preventDefault();
  // Firefox cannot open its add-on pages by URL but offers its own call.
  if (chrome.commands.openShortcutSettings) {
    void chrome.commands.openShortcutSettings();
  } else {
    void chrome.tabs.create({ url: "chrome://extensions/shortcuts" });
  }
});

void load();
