// Safari has no main-world content scripts, so page-volume.js is added to the page as a script element,
// as early as the document allows, and removed again once it has run.
(() => {
  const script = document.createElement("script");
  script.src = chrome.runtime.getURL("page-volume.js");
  script.onload = () => script.remove();
  (document.head || document.documentElement).append(script);
})();
