// Runs in the page's own JavaScript world, in every frame, before page scripts where the browser allows.
//
// Scales everything the page can play by the tab's gain without the page noticing:
// - <audio>/<video>, including detached `new Audio()`: the volume the page sets is remembered and the
//   element plays at `pageVolume × min(gain, 1)`. Reading `volume` still returns the page's own value, so
//   the site's volume slider keeps working and nothing it saves is affected.
// - Above 100 %, eligible elements are routed through Web Audio: gain, then a limiter so peaks never clip
//   and quiet audio is not changed.
//   Only sources Web Audio can read (same origin, blob:/data:, CORS, live streams) and only once audio is
//   allowed to start, so boosting can never silence a video.
// - Web Audio (games, players, calls): connections to a context's destination go through one gain node
//   per context, which glides to new values instead of jumping.
// It also reports whether the page is making sound, for browsers that don't tell extensions (Safari).
(() => {
  const marker = Symbol.for("dev.mezcla.page-volume");
  if (globalThis[marker]) return;
  globalThis[marker] = true;

  const MAX_GAIN = 2.25; // 150 % on Mezcla's square-law curve.
  let gain = 1;

  const connect = AudioNode.prototype.connect;
  const disconnect = AudioNode.prototype.disconnect;
  // Limiter for boosted audio: compressor → undo its automatic makeup gain → soft clipper.
  // The compressor alone lets a loud, boosted track peak above 0 dBFS, and its makeup gain (fixed by the
  // spec at 0.6 × the reduction at 0 dBFS) would also lift quiet audio by 0.86 dB.
  const LIMITER = { threshold: -1.5, knee: 0, ratio: 20, attack: 0.002, release: 0.1 };
  const MAKEUP_DB = 0.6 * -(LIMITER.threshold - LIMITER.threshold / LIMITER.ratio);
  // Same curve as the native soft clipper: transparent below -1.5 dBFS, bending towards -0.3 dBFS.
  // Inputs beyond ±1 hold the curve's last value, about -0.46 dBFS.
  const SAFETY_CURVE = (() => {
    const threshold = 0.841395142, knee = 0.966050879 - threshold, points = 2049;
    const curve = new Float32Array(points);
    for (let i = 0; i < points; i++) {
      const x = (i / (points - 1)) * 2 - 1, magnitude = Math.abs(x);
      curve[i] = magnitude <= threshold ? x : Math.sign(x) * (threshold + knee * Math.tanh((magnitude - threshold) / knee));
    }
    return curve;
  })();
  const makeLimiter = (context) => {
    const input = new DynamicsCompressorNode(context, LIMITER);
    const makeup = new GainNode(context, { gain: 10 ** (-MAKEUP_DB / 20) });
    const output = new WaveShaperNode(context, { curve: SAFETY_CURVE });
    connect.call(input, makeup);
    connect.call(makeup, output);
    return { input, output };
  };

  // MARK: Media elements

  const volume = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, "volume");
  const pageVolume = new WeakMap();
  const elements = new Set(); // WeakRefs, so tracking never keeps an element alive.

  const render = (element) => {
    try {
      volume.set.call(element, pageVolume.get(element) * Math.min(gain, 1));
    } catch {
      // Element in a state that rejects volume changes; the next change will retry.
    }
  };

  const track = (element) => {
    if (pageVolume.has(element)) return;
    pageVolume.set(element, volume.get.call(element));
    elements.add(new WeakRef(element));
    for (const type of ["play", "pause", "ended", "emptied", "volumechange"]) {
      element.addEventListener(type, reportActivity, { passive: true });
    }
    if (gain !== 1) render(element);
    if (gain > 1) boost(element);
    reportActivity();
  };

  Object.defineProperty(HTMLMediaElement.prototype, "volume", {
    configurable: true,
    enumerable: volume.enumerable,
    get() {
      return pageVolume.has(this) ? pageVolume.get(this) : volume.get.call(this);
    },
    set(value) {
      const requested = Number(value);
      if (!Number.isFinite(requested) || requested < 0 || requested > 1) {
        volume.set.call(this, value); // Let the browser throw its usual error.
        return;
      }
      if (!pageVolume.has(this)) track(this);
      pageVolume.set(this, requested);
      render(this);
    },
  });

  const play = HTMLMediaElement.prototype.play;
  HTMLMediaElement.prototype.play = function (...args) {
    track(this);
    return play.apply(this, args);
  };

  // Autoplaying elements never call play(); catch them as they start.
  for (const type of ["play", "playing", "loadedmetadata"]) {
    addEventListener(type, (event) => {
      if (event.target instanceof HTMLMediaElement) track(event.target);
    }, { capture: true, passive: true });
  }

  // MARK: Boost above 100 %

  let boostGraph = null; // { context, input }
  const boosted = new WeakSet();

  const canBoost = (element) => {
    if (element.srcObject) return true; // Live streams (calls) are always readable.
    const source = element.currentSrc || element.src;
    if (!source) return false;
    try {
      const url = new URL(source, location.href);
      return url.protocol === "blob:" || url.protocol === "data:" || url.origin === location.origin || element.crossOrigin !== null;
    } catch {
      return false;
    }
  };

  /** One shared graph: elements → gain → limiter → speakers. Only built once audio may play. */
  const boostInput = async () => {
    if (boostGraph) return boostGraph.context.state === "running" ? boostGraph.input : null;
    if (navigator.userActivation && !navigator.userActivation.hasBeenActive) return null;
    const context = new AudioContext({ latencyHint: "playback" });
    try {
      await context.resume();
    } catch {}
    if (context.state !== "running") {
      context.close();
      return null;
    }
    const input = new GainNode(context, { gain: Math.max(gain, 1) }); // Below 100 % the element's own volume does the work.
    const limiter = makeLimiter(context);
    connect.call(input, limiter.input);
    connect.call(limiter.output, context.destination);
    boostGraph = { context, input };
    return input;
  };

  const boost = async (element) => {
    if (boosted.has(element) || !canBoost(element)) return;
    const input = await boostInput();
    if (!input || boosted.has(element)) return;
    try {
      connect.call(boostGraph.context.createMediaElementSource(element), input);
      boosted.add(element);
    } catch {
      // Already owned by another graph, or not readable: it simply stays at 100 %.
    }
  };

  // MARK: Web Audio

  const contextNodes = new WeakMap(); // context → { input, limiter }
  const contexts = new Set(); // WeakRefs

  const route = (destination) => {
    const context = destination.context;
    if (typeof OfflineAudioContext !== "undefined" && context instanceof OfflineAudioContext) return destination;
    let nodes = contextNodes.get(context);
    if (!nodes) {
      try {
        nodes = { input: new GainNode(context, { gain }), limiter: null };
        connect.call(nodes.input, destination);
        context.addEventListener("statechange", reportActivity);
      } catch {
        return destination; // Closed context: nothing will play anyway.
      }
      contextNodes.set(context, nodes);
      contexts.add(new WeakRef(context));
      if (gain > 1) addLimiter(context, nodes);
      reportActivity();
    }
    return nodes.input;
  };

  const addLimiter = (context, nodes) => {
    if (nodes.limiter || context.state === "closed") return;
    try {
      nodes.limiter = makeLimiter(context);
      disconnect.call(nodes.input);
      connect.call(nodes.input, nodes.limiter.input);
      connect.call(nodes.limiter.output, context.destination);
    } catch {}
  };

  AudioNode.prototype.connect = function (destination, ...rest) {
    if (destination instanceof AudioDestinationNode) {
      connect.call(this, route(destination), ...rest);
      return destination; // Callers chain on the node they passed.
    }
    return connect.call(this, destination, ...rest);
  };

  AudioNode.prototype.disconnect = function (destination, ...rest) {
    if (destination instanceof AudioDestinationNode) {
      return disconnect.call(this, route(destination), ...rest);
    }
    return disconnect.apply(this, arguments);
  };

  // MARK: Activity

  let audible = false;
  let activityTimer = 0;

  function reportActivity() {
    clearTimeout(activityTimer);
    activityTimer = setTimeout(() => {
      let now = false;
      for (const reference of elements) {
        const element = reference.deref();
        if (element && !element.paused && !element.ended && !element.muted && pageVolume.get(element) > 0) {
          now = true;
          break;
        }
      }
      if (!now) {
        for (const reference of contexts) {
          if (reference.deref()?.state === "running") {
            now = true;
            break;
          }
        }
      }
      if (now !== audible) {
        audible = now;
        document.dispatchEvent(new CustomEvent("__mezcla_activity", { detail: audible }));
      }
    }, 150);
  }

  // MARK: Gain updates from the extension

  const setGain = (value) => {
    const next = Math.min(Math.max(Number(value) || 0, 0), MAX_GAIN);
    if (next === gain) return;
    gain = next;
    for (const reference of elements) {
      const element = reference.deref();
      if (!element) {
        elements.delete(reference);
        continue;
      }
      render(element);
      if (gain > 1) boost(element);
    }
    if (boostGraph) {
      boostGraph.input.gain.setTargetAtTime(Math.max(gain, 1), boostGraph.context.currentTime, 0.015);
    }
    for (const reference of contexts) {
      const context = reference.deref();
      if (!context) {
        contexts.delete(reference);
        continue;
      }
      if (context.state === "closed") continue;
      const nodes = contextNodes.get(context);
      if (gain > 1) addLimiter(context, nodes);
      nodes.input.gain.setTargetAtTime(gain, context.currentTime, 0.015);
    }
  };

  document.addEventListener("__mezcla_gain", (event) => setGain(event.detail));
  document.dispatchEvent(new CustomEvent("__mezcla_ready"));
})();
