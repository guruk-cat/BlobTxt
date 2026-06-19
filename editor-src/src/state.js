// Shared foundation imported by the feature modules: the Swift sender and the
// cross-cutting mutable flags. Kept dependency-free so any module can import it
// without risking an import cycle back through main.js.

// Swift bridge communication
export function post(msg) {
  const h = window.webkit?.messageHandlers?.editorBridge
  if (h) h.postMessage(msg)
}

/*
  Cross-cutting mutable state, read and written from main.js's config and bridge
  paths. These live behind one object rather than as bare exported `let`s because
  ES module imports are read-only live bindings: an importer cannot reassign them,
  but it can mutate a property here.
*/
export const state = {
  // Suppresses the documentChanged post during programmatic content replacement.
  // view.dispatch() is synchronous, so this flag is set and cleared within the
  // same call stack before any user-triggered update can fire.
  suppressDocChanged: false,

  // Font state is mirrored so that partial updateConfig calls (e.g., only
  // fontSize changes) can correctly rebuild the combined font theme.
  fontSize: 16,
  fontFamily: 'Menlo',

  // Autoscroll mode does not need a CM compartment — it only gates the JS logic
  // in doCenteredScroll.
  autoScrollMode: 'regular',
}
