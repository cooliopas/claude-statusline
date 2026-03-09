#!/usr/bin/env node

const { execSync } = require("child_process");
const fs = require("fs");
const path = require("path");
const os = require("os");

// ── Colors ──────────────────────────────────────────────
const red = (t) => `\x1b[38;2;255;85;85m${t}\x1b[0m`;
const green = (t) => `\x1b[38;2;0;175;80m${t}\x1b[0m`;
const blue = (t) => `\x1b[38;2;0;153;255m${t}\x1b[0m`;
const cyan = (t) => `\x1b[38;2;86;182;194m${t}\x1b[0m`;
const dim = (t) => `\x1b[2m${t}\x1b[0m`;
const bold = (t) => `\x1b[1m${t}\x1b[0m`;

// ── Helpers ─────────────────────────────────────────────
function hasCommand(cmd) {
  try {
    execSync(`which ${cmd}`, { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

function log(msg) {
  console.log(`  ${msg}`);
}

// ── Args ────────────────────────────────────────────────
const args = process.argv.slice(2);
const isUninstall = args.includes("--uninstall");

const claudeDir = path.join(os.homedir(), ".claude");
const statuslineDest = path.join(claudeDir, "statusline.sh");
const settingsPath = path.join(claudeDir, "settings.json");
const statuslineSrc = path.join(__dirname, "statusline.sh");

// ── Uninstall ───────────────────────────────────────────
if (isUninstall) {
  console.log();
  log(bold("Uninstalling claude-statusline..."));
  console.log();

  // Remove statusline script
  if (fs.existsSync(statuslineDest)) {
    fs.unlinkSync(statuslineDest);
    log(`${green("✓")} Removed ${dim(statuslineDest)}`);
  }

  // Remove statusline config from settings
  if (fs.existsSync(settingsPath)) {
    try {
      const settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
      if (settings.statusLine) {
        delete settings.statusLine;
        fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + "\n");
        log(`${green("✓")} Removed statusLine from ${dim(settingsPath)}`);
      }
    } catch {
      log(`${red("✗")} Could not update settings.json`);
    }
  }

  // Restore backup if exists
  const backup = statuslineDest + ".backup";
  if (fs.existsSync(backup)) {
    fs.renameSync(backup, statuslineDest);
    log(`${green("✓")} Restored previous statusline from backup`);
  }

  console.log();
  log(`${green("Done!")} Restart Claude Code to apply changes.`);
  console.log();
  process.exit(0);
}

// ── Install ─────────────────────────────────────────────
console.log();
log(bold("Installing claude-statusline..."));
console.log();

// Check dependencies
const deps = ["jq", "curl", "git"];
let missing = [];
for (const dep of deps) {
  if (hasCommand(dep)) {
    log(`${green("✓")} ${dep}`);
  } else {
    log(`${red("✗")} ${dep} ${dim("(required)")}`);
    missing.push(dep);
  }
}
console.log();

if (missing.length > 0) {
  log(red(`Missing dependencies: ${missing.join(", ")}`));
  log(dim("Install with: brew install " + missing.join(" ")));
  console.log();
  process.exit(1);
}

// Create ~/.claude if needed
if (!fs.existsSync(claudeDir)) {
  fs.mkdirSync(claudeDir, { recursive: true });
  log(`${green("✓")} Created ${dim(claudeDir)}`);
}

// Backup existing statusline
if (fs.existsSync(statuslineDest)) {
  const backup = statuslineDest + ".backup";
  fs.copyFileSync(statuslineDest, backup);
  log(`${cyan("→")} Backed up existing statusline to ${dim(backup)}`);
}

// Copy statusline script
fs.copyFileSync(statuslineSrc, statuslineDest);
fs.chmodSync(statuslineDest, 0o755);
log(`${green("✓")} Installed statusline to ${dim(statuslineDest)}`);

// Update settings.json
let settings = {};
if (fs.existsSync(settingsPath)) {
  try {
    settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
  } catch {
    settings = {};
  }
}

settings.statusLine = {
  command: statuslineDest,
};

fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + "\n");
log(`${green("✓")} Updated ${dim(settingsPath)}`);

console.log();
log(green(bold("Done!")) + " Restart Claude Code to see your new statusline.");
console.log();
log(dim("Features:"));
log(dim("  Model name │ Context % │ Directory (branch) │ Session time"));
log(dim("  Rate limits (5h/7d) │ Version update indicator"));
console.log();
log(dim(`To uninstall: npx @coolio/claude-statusline --uninstall`));
console.log();
