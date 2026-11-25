// Runs in the extension's isolated world, in every frame. Carries the tab's gain from the extension
// to page-volume.js, which lives in the page's world and cannot talk to the extension directly.
(() => {
  if (globalThis.__mezclaPageBridge) return; // Injected both declaratively and into tabs open at install.
  globalThis.__mezclaPageBridge = true;
  let gain = 1;
  const deliver = () => document.dispatchEvent(new CustomEvent("__mezcla_gain", { detail: gain }));

  chrome.runtime.onMessage.addListener((message) => {
    if (message?.type === "mezcla:gain") {
      gain = message.gain;
      deliver();
    }
  });

  // page-volume.js announces itself; answer with the current gain whichever script ran first.
  document.addEventListener("__mezcla_ready", deliver);

  // Whether this frame is making sound, for browsers that don't report audible tabs (Safari).
  document.addEventListener("__mezcla_activity", (event) => {
    const icon = document.querySelector('link[rel~="icon"], link[rel="apple-touch-icon"]')?.href ?? null;
    chrome.runtime.sendMessage({ type: "mezcla:activity", audible: Boolean(event.detail), icon }).catch(() => {});
  });

  chrome.runtime.sendMessage({ type: "mezcla:hello" }).then((response) => {
    if (typeof response?.gain === "number") {
      gain = response.gain;
      deliver();
    }
  }).catch(() => {
    // Extension reloaded or not ready; it will push the gain when it changes.
  });
})();
