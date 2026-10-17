'use strict';
// fm-browser-guard-load.cjs - the stable NODE_OPTIONS entry point for the agent
// browser guard.
//
// bin/fm-browser-guard-env.sh points NODE_OPTIONS at this file instead of at
// bin/fm-browser-guard-preload.cjs directly, and this loader try-requires the
// real preload beside it. Node aborts a process with MODULE_NOT_FOUND when a
// `--require` target is missing, so a home checkout that loses the preload
// after a pane was launched - a branch switch or revert in the home - would
// otherwise break every `node` in that pane. Loading it from here degrades that
// case to an unguarded Node process, the same failure mode as a home that never
// installed the guard, instead of killing unrelated work.
//
// The enforcement itself lives in fm-browser-guard-preload.cjs; nothing here
// writes to stdout or changes a process that loads the preload successfully.
// docs/browser-guard.md owns the contract.

try {
  require(require('node:path').join(__dirname, 'fm-browser-guard-preload.cjs'));
} catch (err) {
  /* the preload is missing or failed: leave this process unguarded, never fail it */
}
