// Service worker: reports tabs that make sound to Mezcla and applies the volumes Mezcla sends back.
//
// Mezcla ⇄ mezcla-bridge (native messaging host) ⇄ this worker ⇄ page-bridge.js ⇄ page-volume.js

const HOST = "dev.mezcla.bridge";
const GRACE_MS = 8000; // A tab that just went quiet stays listed, so short sounds can be adjusted.
const REPORT_DELAY_MS = 80;

/** @type {Map<number, {level: number, gain: number, muted: boolean}>} User-chosen volumes, by tab. */
const volumes = new Map();
/** @type {Map<number, number>} When each tab last stopped being audible. */
const quietSince = new Map();
/** @type {Map<string, string>} Favicon data URLs, by origin. */
const favicons = new Map();

let port = null;
let retryDelay = 1000;
let reportTimer = null;
let expiryTimer = null;

const ready = chrome.storage.session.get("volumes").then(({ volumes: saved }) => {
  for (const [id, volume] of Object.entries(saved ?? {})) volumes.set(Number(id), volume);
});

const persist = () => chrome.storage.session.set({ volumes: Object.fromEntries(volumes) });

// MARK: Connection to Mezcla

function connect() {
  try {
    port = chrome.runtime.connectNative(HOST);
  } catch {
    retry();
    return;
  }
  port.onMessage.addListener(receive);
  port.onDisconnect.addListener(() => {
    void chrome.runtime.lastError; // Read it so the browser does not log it as unchecked.
    port = null;
    retry();
  });
  retryDelay = 1000;
  scheduleReport();
}

function retry() {
  setTimeout(connect, retryDelay);
  retryDelay = Math.min(retryDelay * 2, 60000);
}

async function receive(message) {
  await ready;
  if (message?.type === "set" && Number.isInteger(message.tabId)) {
    // `level` is the slider position Mezcla shows; `gain` is what the page applies (square-law curve).
    const level = Math.min(Math.max(Number(message.level) || 0, 0), 1.5);
    const gain = Math.min(Math.max(Number(message.gain ?? level) || 0, 0), 2.25);
    const muted = Boolean(message.muted);
    const previous = volumes.get(message.tabId);
    if (level === 1 && !muted) volumes.delete(message.tabId);
    else volumes.set(message.tabId, { level, gain, muted });
    persist();

    applyGain(message.tabId, gain);
    if ((previous?.muted ?? false) !== muted) {
      // Native tab muting: shows the speaker icon in the tab strip and silences everything, plugins included.
      chrome.tabs.update(message.tabId, { muted }).catch(() => {});
    }
  } else if (message?.type === "refresh") {
    scheduleReport();
  }
}

function applyGain(tabId, gain) {
  chrome.tabs.sendMessage(tabId, { type: "mezcla:gain", gain }).catch(() => {});
}

// MARK: Reporting tabs

function scheduleReport() {
  clearTimeout(reportTimer);
  reportTimer = setTimeout(report, REPORT_DELAY_MS);
}

async function report() {
  await ready;
  if (!port) return;
  const now = Date.now();
  const tabs = await chrome.tabs.query({});
  const listed = tabs.filter((tab) =>
    tab.audible || volumes.has(tab.id) || now - (quietSince.get(tab.id) ?? -Infinity) < GRACE_MS
  );

  const entries = await Promise.all(listed.map(async (tab) => ({
    id: tab.id,
    title: tab.title || tab.url || "",
    url: tab.url ?? null,
    icon: await favicon(tab.url),
    audible: Boolean(tab.audible),
    muted: Boolean(tab.mutedInfo?.muted),
    level: volumes.get(tab.id)?.level ?? 1,
  })));

  try {
    port?.postMessage({ type: "tabs", tabs: entries });
  } catch {
    // Port closed between the check and the send; the reconnect will report again.
  }
  scheduleExpiry(now);
}

/** Re-reports when the next quiet tab's grace period ends, so it leaves the list on time. */
function scheduleExpiry(now) {
  clearTimeout(expiryTimer);
  const pending = [...quietSince.values()].map((since) => since + GRACE_MS - now).filter((delay) => delay > 0);
  if (pending.length > 0) expiryTimer = setTimeout(scheduleReport, Math.min(...pending) + 50);
}

async function favicon(pageUrl) {
  if (!pageUrl || !/^https?:/.test(pageUrl)) return null;
  const origin = new URL(pageUrl).origin;
  if (favicons.has(origin)) return favicons.get(origin);
  try {
    const url = new URL(chrome.runtime.getURL("/_favicon/"));
    url.searchParams.set("pageUrl", pageUrl);
    url.searchParams.set("size", "32");
    const bytes = new Uint8Array(await (await fetch(url)).arrayBuffer());
    let binary = "";
    for (let index = 0; index < bytes.length; index += 0x8000) {
      binary += String.fromCharCode(...bytes.subarray(index, index + 0x8000));
    }
    const dataURL = `data:image/png;base64,${btoa(binary)}`;
    favicons.set(origin, dataURL);
    return dataURL;
  } catch {
    return null;
  }
}

// MARK: Tab events

chrome.tabs.onUpdated.addListener((tabId, change) => {
  if ("audible" in change) {
    if (change.audible) quietSince.delete(tabId);
    else quietSince.set(tabId, Date.now());
  }
  if ("audible" in change || "title" in change || "favIconUrl" in change || "mutedInfo" in change || "url" in change) {
    if ("mutedInfo" in change) syncMute(tabId, change.mutedInfo.muted);
    scheduleReport();
  }
});

/** Keeps Mezcla's mute in step when the user mutes a tab from the tab strip. */
function syncMute(tabId, muted) {
  const volume = volumes.get(tabId) ?? { level: 1, gain: 1, muted: false };
  if (volume.muted === muted) return;
  volume.muted = muted;
  if (volume.level === 1 && !muted) volumes.delete(tabId);
  else volumes.set(tabId, volume);
  persist();
}

chrome.tabs.onRemoved.addListener((tabId) => {
  volumes.delete(tabId);
  quietSince.delete(tabId);
  persist();
  scheduleReport();
});

chrome.tabs.onReplaced.addListener((addedTabId, removedTabId) => {
  const volume = volumes.get(removedTabId);
  volumes.delete(removedTabId);
  if (volume) {
    volumes.set(addedTabId, volume);
    applyGain(addedTabId, volume.gain ?? volume.level);
  }
  persist();
  scheduleReport();
});

// A reloaded page or a newly loaded frame asks for its tab's gain.
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.type !== "mezcla:hello" || sender.tab?.id === undefined) return false;
  ready.then(() => {
    const volume = volumes.get(sender.tab.id);
    sendResponse({ gain: volume ? volume.gain ?? volume.level : 1 });
  });
  return true; // Responds asynchronously.
});

// Content scripts only reach pages loaded after the extension starts. Tabs that were already open when it
// was installed, updated or the browser restarted get them now, so they can be controlled without a reload.
async function injectIntoOpenTabs() {
  const tabs = await chrome.tabs.query({ url: ["http://*/*", "https://*/*"] });
  await Promise.all(tabs.map(async (tab) => {
    const target = { tabId: tab.id, allFrames: true };
    try {
      await chrome.scripting.executeScript({ target, files: ["page-volume.js"], world: "MAIN", injectImmediately: true });
      await chrome.scripting.executeScript({ target, files: ["page-bridge.js"], injectImmediately: true });
    } catch {
      // Protected pages (web store, browser settings) refuse scripts; nothing plays there anyway.
    }
  }));
}

chrome.runtime.onInstalled.addListener(injectIntoOpenTabs);
chrome.runtime.onStartup.addListener(injectIntoOpenTabs);

connect();
