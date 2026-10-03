// Trigger: JavaScript for Automation. Run with:  osascript -l JavaScript handoff-jxa.js
// Drives the same "TerrierGPT Handoff" shortcut as shortcut.sh, through Shortcuts Events,
// so it returns the value directly without going through latest.json.
function run(argv) {
  const name = argv[0] || "TerrierGPT Handoff";
  const shortcut = Application("Shortcuts Events").shortcuts.byName(name);
  return shortcut.run();
}
