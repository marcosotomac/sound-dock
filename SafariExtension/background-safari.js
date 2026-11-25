// Safari background page: reports tabs that make sound to Mezcla and applies the volumes it sends back.
//
// Safari talks to native code differently from Chromium: reports go out with sendNativeMessage (to the
// Mezcla app extension, which hands them to Mezcla), and Mezcla pushes commands through the port that
// connectNative opens. Safari doesn't say which tabs are audible, so pages report it themselves.

const APP = "dev.mezcla.Mezcla";
const GRACE_MS = 8000;
const HEARTBEAT_MS = 15000; // Mezcla forgets Safari's tabs if it stops hearing from it.
const REPORT_DELAY_MS = 80;

/** @type {Map<number, {level: number, gain: number, muted: boolean}>} */
const volumes = new Map();
/** @type {Map<number, Map<number, boolean>>} Audible state per frame, by tab. */
const frames = new Map();
/** @type {Map<number, number>} */
const quietSince = new Map();
/** @type {Map<number, string>} Icon URL each tab's page declared. */
const pageIcons = new Map();
/** @type {Map<string, string|null>} Favicon data URLs, by icon URL. */
const favicons = new Map();

let reportTimer = null;

// MARK: Commands from Mezcla

function listen() {
  let port;
  try {
    port = browser.runtime.connectNative(APP);
  } catch {
    setTimeout(listen, 5000);
    return;
  }
  port.onMessage.addListener((raw) => receive(raw?.userInfo ?? raw));
  port.onDisconnect.addListener(() => setTimeout(listen, 5000));
}

function receive(message) {
  if (message?.type !== "set" || !Number.isInteger(message.tabId)) return;
  const level = Math.min(Math.max(Number(message.level) || 0, 0), 1.5);
  const gain = Math.min(Math.max(Number(message.gain ?? level) || 0, 0), 2.25);
  const muted = Boolean(message.muted);
  if (level === 1 && !muted) volumes.delete(message.tabId);
  else volumes.set(message.tabId, { level, gain, muted });
  applyGain(message.tabId);
  scheduleReport();
}

/** Safari has no tab muting API, so muting is a gain of zero inside the page. */
function applyGain(tabId) {
  const volume = volumes.get(tabId);
  const gain = volume ? (volume.muted ? 0 : volume.gain) : 1;
  browser.tabs.sendMessage(tabId, { type: "mezcla:gain", gain }).catch(() => {});
}

// MARK: Reports to Mezcla

function isAudible(tabId) {
  return [...(frames.get(tabId)?.values() ?? [])].some(Boolean);
}

function scheduleReport() {
  clearTimeout(reportTimer);
  reportTimer = setTimeout(report, REPORT_DELAY_MS);
}

async function report() {
  const now = Date.now();
  const tabs = await browser.tabs.query({});
  const listed = tabs.filter((tab) =>
    isAudible(tab.id) || volumes.has(tab.id) || now - (quietSince.get(tab.id) ?? -Infinity) < GRACE_MS
  );
  const icons = await Promise.all(listed.map((tab) => favicon(tab)));
  const message = {
    type: "tabs",
    tabs: listed.map((tab, index) => ({
      id: tab.id,
      title: tab.title || tab.url || "",
      url: tab.url ?? null,
      icon: icons[index],
      audible: isAudible(tab.id),
      muted: volumes.get(tab.id)?.muted ?? false,
      level: volumes.get(tab.id)?.level ?? 1,
    })),
  };
  browser.runtime.sendNativeMessage(APP, message).catch(() => {});
}

/** The site's real icon: what the page declares, else the site's favicon.ico, as a data URL. */
async function favicon(tab) {
  if (!tab.url || !/^https?:/.test(tab.url)) return null;
  const source = tab.favIconUrl || pageIcons.get(tab.id) || new URL("/favicon.ico", tab.url).href;
  if (favicons.has(source)) return favicons.get(source);
  let dataURL = null;
  try {
    const response = await fetch(source);
    const type = response.headers.get("content-type") ?? "";
    if (response.ok && type.startsWith("image/")) {
      const bytes = new Uint8Array(await response.arrayBuffer());
      if (bytes.length < 256 * 1024) {
        let binary = "";
        for (let index = 0; index < bytes.length; index += 0x8000) {
          binary += String.fromCharCode(...bytes.subarray(index, index + 0x8000));
        }
        dataURL = `data:${type.split(";")[0]};base64,${btoa(binary)}`;
      }
    }
  } catch {
    // Offline or blocked: the row shows a globe.
  }
  favicons.set(source, dataURL);
  return dataURL;
}

// MARK: Page and tab events

browser.runtime.onMessage.addListener((message, sender, sendResponse) => {
  const tabId = sender.tab?.id;
  if (tabId === undefined) return false;
  if (message?.type === "mezcla:hello") {
    const volume = volumes.get(tabId);
    sendResponse({ gain: volume ? (volume.muted ? 0 : volume.gain) : 1 });
    return false;
  }
  if (message?.type === "mezcla:activity") {
    if (message.icon && (sender.frameId ?? 0) === 0) pageIcons.set(tabId, message.icon);
    const wasAudible = isAudible(tabId);
    if (!frames.has(tabId)) frames.set(tabId, new Map());
    frames.get(tabId).set(sender.frameId ?? 0, Boolean(message.audible));
    const audible = isAudible(tabId);
    if (wasAudible && !audible) {
      quietSince.set(tabId, Date.now());
      setTimeout(scheduleReport, GRACE_MS + 50);
    } else if (audible) {
      quietSince.delete(tabId);
    }
    if (audible !== wasAudible) scheduleReport();
  }
  return false;
});

browser.tabs.onUpdated.addListener((tabId, change) => {
  if (change.status === "loading") {
    frames.delete(tabId); // New page: its frames will report again.
    pageIcons.delete(tabId);
  }
  if ("title" in change || "url" in change) scheduleReport();
});

browser.tabs.onRemoved.addListener((tabId) => {
  volumes.delete(tabId);
  pageIcons.delete(tabId);
  frames.delete(tabId);
  quietSince.delete(tabId);
  scheduleReport();
});

listen();
setInterval(report, HEARTBEAT_MS);
report();
