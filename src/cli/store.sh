#!/usr/bin/env bash

store_node() {
  node - "$@" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const command = process.argv[2];
const args = process.argv.slice(3);
const configFile = process.env.TAVILY_CONFIG_FILE_PATH;
const keysFile = process.env.TAVILY_KEYS_FILE_PATH;
const legacyActiveFile = process.env.TAVILY_LEGACY_ACTIVE_FILE_PATH;

const LOCK_TIMEOUT_MS = Number(process.env.TAVILY_LOCK_TIMEOUT_MS || 5000);
const LOCK_STALE_MS = Number(process.env.TAVILY_LOCK_STALE_MS || 30000);

function readJson(file) {
  if (!fs.existsSync(file)) return null;
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function jsonText(value) {
  return JSON.stringify(value, null, 2) + "\n";
}

function sleepSync(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

// Writes go to a temp file first and are then renamed into place. rename(2) is
// atomic on the same filesystem, so a concurrent reader sees either the old
// file or the new one, never a half-written one.
function writeFileAtomic(file, data, mode) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.tmp.${process.pid}`;
  try {
    fs.writeFileSync(tmp, data, { mode });
    fs.renameSync(tmp, file);
  } catch (error) {
    try { fs.unlinkSync(tmp); } catch {}
    // A read-only file whose content already matches is not an error.
    const current = fs.existsSync(file) ? fs.readFileSync(file, "utf8") : null;
    if ((error.code === "EPERM" || error.code === "EACCES") && current === data) return;
    throw error;
  }
}

// mkdir is atomic across processes, which is all we need to serialise the
// read-modify-write cycle when several agents start (and auto-rotate) at once.
function withLock(fn) {
  const lockDir = `${configFile}.lock`;
  const deadline = Date.now() + LOCK_TIMEOUT_MS;
  let acquired = false;

  while (Date.now() < deadline) {
    try {
      fs.mkdirSync(path.dirname(lockDir), { recursive: true });
      fs.mkdirSync(lockDir);
      acquired = true;
      break;
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
      let stale = false;
      try {
        stale = Date.now() - fs.statSync(lockDir).mtimeMs > LOCK_STALE_MS;
      } catch {
        continue; // lock vanished between mkdir and stat; retry immediately
      }
      if (stale) {
        try { fs.rmdirSync(lockDir); } catch {}
        continue;
      }
      sleepSync(50);
    }
  }

  if (!acquired) {
    throw new Error(
      `Timed out waiting for the config lock at ${lockDir}. ` +
      `If no other tavily-manager process is running, remove that directory.`
    );
  }

  try {
    return fn();
  } finally {
    try { fs.rmdirSync(lockDir); } catch {}
  }
}

// Single-quoted form is the only bash quoting that expands nothing at all.
// Double quotes still expand $(...) and ${...}, which turns an API key value
// into executable code the moment keys.env is sourced.
function envQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

function envUnquote(raw) {
  const trimmed = raw.trim();
  if (trimmed.length >= 2 && trimmed.startsWith("'") && trimmed.endsWith("'")) {
    return trimmed.slice(1, -1).replace(/'\\''/g, "'");
  }
  if (trimmed.length >= 2 && trimmed.startsWith('"') && trimmed.endsWith('"')) {
    return trimmed.slice(1, -1).replace(/\\"/g, '"').replace(/\\\\/g, "\\");
  }
  return trimmed;
}

function parseEnvLine(line) {
  const m = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
  if (!m) return null;
  return { name: m[1], value: envUnquote(m[2]) };
}

function readEnvEntries() {
  if (!fs.existsSync(keysFile)) return [];
  const entries = [];
  for (const line of fs.readFileSync(keysFile, "utf8").split(/\r?\n/)) {
    if (!line.trim()) continue;
    const parsed = parseEnvLine(line);
    if (parsed) entries.push(parsed);
  }
  return entries;
}

function writeEnvEntries(entries) {
  const body = entries.map((e) => `${e.name}=${envQuote(e.value)}`).join("\n");
  writeFileAtomic(keysFile, body ? `${body}\n` : "", 0o600);
}

// Existing installs have double-quoted values written by older versions.
// Rewrite them into the safe form once, keeping a backup in case the parse
// of an unusual line was wrong.
function normalizeKeysFile() {
  if (!fs.existsSync(keysFile)) return;
  const original = fs.readFileSync(keysFile, "utf8");
  const lines = original.split(/\r?\n/);
  const canonical = [];
  let dirty = false;

  for (const line of lines) {
    if (!line.trim()) continue;
    const parsed = parseEnvLine(line);
    if (!parsed) {
      canonical.push(line); // preserve comments and anything we do not understand
      continue;
    }
    const rewritten = `${parsed.name}=${envQuote(parsed.value)}`;
    if (rewritten !== line) dirty = true;
    canonical.push(rewritten);
  }

  if (!dirty) return;
  fs.writeFileSync(`${keysFile}.bak`, original, { mode: 0o600 });
  writeFileAtomic(keysFile, canonical.join("\n") + "\n", 0o600);
}

function normalizeConfig(config) {
  if (!config) config = {};
  if (!config.keys) config.keys = {};
  if (!config.version) config.version = 1;
  if (!config.activeKey && Object.keys(config.keys).length > 0) {
    config.activeKey = Object.keys(config.keys).sort(slotSort)[0];
  }
  for (const [slot, key] of Object.entries(config.keys)) {
    if (!key.envVar) key.envVar = envVarForSlot(slot);
  }
  return config;
}

function ensureConfig() {
  fs.mkdirSync(path.dirname(configFile), { recursive: true });
  fs.mkdirSync(path.dirname(keysFile), { recursive: true });
  if (!fs.existsSync(keysFile)) fs.writeFileSync(keysFile, "", { mode: 0o600 });
  normalizeKeysFile();

  let config = readJson(configFile);
  if (!config) {
    config = { version: 1, activeKey: null, keys: {} };
  }

  if (legacyActiveFile && fs.existsSync(legacyActiveFile)) {
    const legacy = fs.readFileSync(legacyActiveFile, "utf8").trim();
    if (legacy && !config.activeKey) {
      config.activeKey = legacy;
    }
    fs.unlinkSync(legacyActiveFile);
  }

  return normalizeConfig(config);
}

function writeConfig(config) {
  writeFileAtomic(configFile, jsonText(config), 0o600);
}

function slotSort(a, b) {
  return Number(a) - Number(b);
}

function resolveRef(config, ref) {
  if (!ref) throw new Error("Missing key reference");
  if (/^\d+$/.test(ref)) {
    if (!config.keys[ref]) throw new Error(`Key #${ref} not found`);
    return ref;
  }
  for (const [slot, key] of Object.entries(config.keys)) {
    if (key.label === ref) return slot;
  }
  throw new Error(`Alias '${ref}' not found`);
}

function nextSlot(config) {
  let slot = 1;
  while (config.keys[String(slot)]) slot += 1;
  return String(slot);
}

function envVarForSlot(slot) {
  return `TAVILY_API_KEY_${slot}`;
}

function validateAlias(alias, config, currentSlot = null) {
  if (alias === "" || alias == null) return null;
  if (!/^[A-Za-z][A-Za-z0-9_-]*$/.test(alias)) {
    throw new Error("Alias must start with a letter and contain only letters, numbers, dashes, or underscores.");
  }
  for (const [slot, key] of Object.entries(config.keys)) {
    if (slot !== currentSlot && key.label === alias) {
      throw new Error(`Alias '${alias}' is already used by #${slot}.`);
    }
  }
  return alias;
}

function upsertEnv(keyVar, value) {
  const entries = readEnvEntries();
  const existing = entries.find((e) => e.name === keyVar);
  if (existing) existing.value = value;
  else entries.push({ name: keyVar, value });
  writeEnvEntries(entries);
}

function removeEnv(keyVar) {
  writeEnvEntries(readEnvEntries().filter((e) => e.name !== keyVar));
}

function envValueFor(keyVar) {
  const entry = readEnvEntries().find((e) => e.name === keyVar);
  return entry ? entry.value : "";
}

function run() {
  const config = ensureConfig();

  if (command === "active") {
    console.log(config.activeKey || "");
  } else if (command === "resolve") {
    console.log(resolveRef(config, args[0]));
  } else if (command === "list") {
    for (const slot of Object.keys(config.keys).sort(slotSort)) {
      const key = config.keys[slot];
      console.log(`${slot}|${key.label || ""}|${key.envVar || envVarForSlot(slot)}`);
    }
  } else if (command === "meta") {
    const slot = resolveRef(config, args[0]);
    const key = config.keys[slot];
    console.log(`${slot}|${key.label || ""}|${key.envVar || envVarForSlot(slot)}`);
  } else if (command === "get") {
    // Emit a raw secret so callers never have to `source` keys.env.
    const slot = resolveRef(config, args[0] || config.activeKey);
    const key = config.keys[slot];
    process.stdout.write(envValueFor(key.envVar || envVarForSlot(slot)));
  } else if (command === "add") {
    const value = args[0];
    const aliasIndex = args.indexOf("--alias");
    const alias = aliasIndex >= 0 ? args[aliasIndex + 1] : null;
    if (!value || (aliasIndex >= 0 && !alias)) throw new Error("Usage: tavily-manager add <api-key> [--alias <label>]");
    if (readEnvEntries().some((e) => e.value === value)) throw new Error("This API key is already stored.");
    const slot = nextSlot(config);
    const label = validateAlias(alias, config);
    const envVar = envVarForSlot(slot);
    config.keys[slot] = { label, envVar, createdAt: new Date().toISOString() };
    if (!config.activeKey) config.activeKey = slot;
    upsertEnv(envVar, value);
    writeConfig(config);
    console.log(`${slot}|${label || ""}|${envVar}`);
  } else if (command === "rename") {
    const slot = resolveRef(config, args[0]);
    const label = validateAlias(args[1], config, slot);
    if (!label) throw new Error("Usage: tavily-manager key rename <slot|alias> <alias>");
    config.keys[slot].label = label;
    writeConfig(config);
    console.log(`${slot}|${label}|${config.keys[slot].envVar}`);
  } else if (command === "remove") {
    const slot = resolveRef(config, args[0]);
    const key = config.keys[slot];
    delete config.keys[slot];
    if (config.activeKey === slot) config.activeKey = Object.keys(config.keys).sort(slotSort)[0] || null;
    removeEnv(key.envVar || envVarForSlot(slot));
    writeConfig(config);
    console.log(`${slot}|${key.label || ""}|${config.activeKey || ""}`);
  } else if (command === "switch") {
    const slot = resolveRef(config, args[0]);
    config.activeKey = slot;
    writeConfig(config);
    const key = config.keys[slot];
    console.log(`${slot}|${key.label || ""}|${key.envVar || envVarForSlot(slot)}`);
  } else {
    throw new Error(`Unknown store command: ${command}`);
  }
}

try {
  withLock(run);
} catch (error) {
  console.error(error.message);
  process.exit(1);
}
NODE
}

store() {
  TAVILY_CONFIG_FILE_PATH="$config_file" \
  TAVILY_KEYS_FILE_PATH="$keys_file" \
  TAVILY_LEGACY_ACTIVE_FILE_PATH="$legacy_active_file" \
  store_node "$@"
}

load_store() {
  store active >/dev/null
  # keys.env is written in single-quoted form, so sourcing expands nothing.
  # shellcheck disable=SC1090
  source "$keys_file"
}
