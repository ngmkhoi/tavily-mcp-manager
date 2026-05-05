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

function readJson(file) {
  if (!fs.existsSync(file)) return null;
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function jsonText(value) {
  return JSON.stringify(value, null, 2) + "\n";
}

function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const next = jsonText(value);
  try {
    fs.writeFileSync(file, next, { mode: 0o600 });
  } catch (error) {
    const current = fs.existsSync(file) ? fs.readFileSync(file, "utf8") : null;
    if (error.code === "EPERM" && current === next) return;
    throw error;
  }
}

function readEnvKeys(file) {
  if (!fs.existsSync(file)) return {};
  const lines = fs.readFileSync(file, "utf8").split(/\r?\n/);
  const result = {};
  for (const line of lines) {
    const m = line.match(/^\s*(\w+)=/);
    if (m) result[m[1]] = true;
  }
  return result;
}

function normalizeConfig(config) {
  if (!config) config = {};
  if (!config.keys) config.keys = {};
  if (!config.version) config.version = 1;
  if (!config.activeKey && Object.keys(config.keys).length > 0) {
    config.activeKey = Object.keys(config.keys).sort(slotSort)[0];
  }
  const envKeys = readEnvKeys(keysFile);
  for (const [slot, key] of Object.entries(config.keys)) {
    if (!key.envVar) key.envVar = envVarForSlot(slot);
  }
  return config;
}

function ensureConfig() {
  fs.mkdirSync(path.dirname(configFile), { recursive: true });
  fs.mkdirSync(path.dirname(keysFile), { recursive: true });
  if (!fs.existsSync(keysFile)) fs.writeFileSync(keysFile, "", { mode: 0o600 });

  let config = readJson(configFile);
  if (!config) {
    config = { version: 1, activeKey: null, keys: {} };
  }

  if (fs.existsSync(legacyActiveFile)) {
    const legacy = fs.readFileSync(legacyActiveFile, "utf8").trim();
    if (legacy && !config.activeKey) {
      config.activeKey = legacy;
    }
    fs.unlinkSync(legacyActiveFile);
  }

  return normalizeConfig(config);
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

function quoteEnv(value) {
  return `"${String(value).replace(/\\/g, "\\\\").replace(/"/g, "\\\"")}"`;
}

function upsertEnv(keyVar, value) {
  const original = fs.existsSync(keysFile) ? fs.readFileSync(keysFile, "utf8") : "";
  const lines = original.split(/\r?\n/).filter((line, index, arr) => index < arr.length - 1 || line !== "");
  const nextLine = `${keyVar}=${quoteEnv(value)}`;
  let replaced = false;
  const next = lines.map((line) => {
    if (line.match(new RegExp(`^\\s*${keyVar}=`))) {
      replaced = true;
      return nextLine;
    }
    return line;
  });
  if (!replaced) next.push(nextLine);
  fs.writeFileSync(keysFile, `${next.join("\n")}\n`, { mode: 0o600 });
}

function readEnvValues() {
  if (!fs.existsSync(keysFile)) return [];
  const lines = fs.readFileSync(keysFile, "utf8").split(/\r?\n/);
  const values = [];
  for (const line of lines) {
    const m = line.match(/^\s*\w+=("(.*)"|(.*))$/);
    if (m) values.push(m[2] !== undefined ? m[2].replace(/\\"/g, '"').replace(/\\\\/g, "\\") : m[3]);
  }
  return values;
}

function removeEnv(keyVar) {
  if (!fs.existsSync(keysFile)) return;
  const lines = fs.readFileSync(keysFile, "utf8").split(/\r?\n/);
  const next = lines.filter((line) => !line.match(new RegExp(`^\\s*${keyVar}=`)));
  fs.writeFileSync(keysFile, next.join("\n").replace(/\n*$/, "\n"), { mode: 0o600 });
}

try {
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
  } else if (command === "add") {
    const value = args[0];
    const aliasIndex = args.indexOf("--alias");
    const alias = aliasIndex >= 0 ? args[aliasIndex + 1] : null;
    if (!value || (aliasIndex >= 0 && !alias)) throw new Error("Usage: tavily-manager add <api-key> [--alias <label>]");
    const existing = readEnvValues();
    if (existing.includes(value)) throw new Error("This API key is already stored.");
    const slot = nextSlot(config);
    const label = validateAlias(alias, config);
    const envVar = envVarForSlot(slot);
    config.keys[slot] = { label, envVar, createdAt: new Date().toISOString() };
    if (!config.activeKey) config.activeKey = slot;
    upsertEnv(envVar, value);
    writeJson(configFile, config);
    console.log(`${slot}|${label || ""}|${envVar}`);
  } else if (command === "rename") {
    const slot = resolveRef(config, args[0]);
    const label = validateAlias(args[1], config, slot);
    if (!label) throw new Error("Usage: tavily-manager key rename <slot|alias> <alias>");
    config.keys[slot].label = label;
    writeJson(configFile, config);
    console.log(`${slot}|${label}|${config.keys[slot].envVar}`);
  } else if (command === "remove") {
    const slot = resolveRef(config, args[0]);
    const key = config.keys[slot];
    delete config.keys[slot];
    if (config.activeKey === slot) config.activeKey = Object.keys(config.keys).sort(slotSort)[0] || null;
    removeEnv(key.envVar || envVarForSlot(slot));
    writeJson(configFile, config);
    console.log(`${slot}|${key.label || ""}|${config.activeKey || ""}`);
  } else if (command === "switch") {
    const slot = resolveRef(config, args[0]);
    config.activeKey = slot;
    writeJson(configFile, config);
    const key = config.keys[slot];
    console.log(`${slot}|${key.label || ""}|${key.envVar || envVarForSlot(slot)}`);
  } else {
    throw new Error(`Unknown store command: ${command}`);
  }
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
  # shellcheck disable=SC1090
  source "$keys_file"
}
