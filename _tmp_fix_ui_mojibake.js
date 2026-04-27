const fs = require("fs");
const path = require("path");

const root = process.argv[2];
if (!root) {
  console.error("Usage: node _tmp_fix_ui_mojibake.js <translate-root>");
  process.exit(1);
}

function readJson(filePath) {
  const raw = fs.readFileSync(filePath, "utf8").replace(/^\uFEFF/, "");
  return JSON.parse(raw);
}

const enPath = path.join(root, "EN", "UI.json");
const en = readJson(enPath);
const enKeys = Object.keys(en);

function placeholders(s) {
  return ((s || "").match(/%[ds]/g) || []).join("|");
}

const cp1252ToUnicode = {
  0x80: 0x20ac,
  0x82: 0x201a,
  0x83: 0x0192,
  0x84: 0x201e,
  0x85: 0x2026,
  0x86: 0x2020,
  0x87: 0x2021,
  0x88: 0x02c6,
  0x89: 0x2030,
  0x8a: 0x0160,
  0x8b: 0x2039,
  0x8c: 0x0152,
  0x8e: 0x017d,
  0x91: 0x2018,
  0x92: 0x2019,
  0x93: 0x201c,
  0x94: 0x201d,
  0x95: 0x2022,
  0x96: 0x2013,
  0x97: 0x2014,
  0x98: 0x02dc,
  0x99: 0x2122,
  0x9a: 0x0161,
  0x9b: 0x203a,
  0x9c: 0x0153,
  0x9e: 0x017e,
  0x9f: 0x0178,
};

const unicodeToCp1252 = new Map(
  Object.entries(cp1252ToUnicode).map(([b, u]) => [u, Number(b)])
);

function encodeCp1252(str) {
  const out = [];
  for (const ch of str) {
    const cp = ch.codePointAt(0);
    if (cp <= 0xff) {
      out.push(cp);
      continue;
    }

    const b = unicodeToCp1252.get(cp);
    if (b !== undefined) {
      out.push(b);
      continue;
    }

    return null;
  }

  return Buffer.from(out);
}

function suspiciousCount(s) {
  return (s.match(/[ÃÂâ€]/g) || []).length;
}

function repairMojibake(s) {
  if (typeof s !== "string" || !/[ÃÂâ€]/.test(s)) {
    return s;
  }

  let current = s;
  for (let i = 0; i < 3; i += 1) {
    const bytes = encodeCp1252(current);
    if (!bytes) {
      break;
    }

    const decoded = bytes.toString("utf8");
    if (!decoded || decoded.includes("\uFFFD") || decoded === current) {
      break;
    }

    if (suspiciousCount(decoded) < suspiciousCount(current)) {
      current = decoded;
    } else {
      break;
    }
  }

  return current;
}

const dirs = fs
  .readdirSync(root, { withFileTypes: true })
  .filter((d) => d.isDirectory())
  .map((d) => d.name)
  .filter((d) => d !== "EN" && d !== "PTBR");

const modified = [];
const errors = [];

for (const lang of dirs) {
  const file = path.join(root, lang, "UI.json");
  if (!fs.existsSync(file)) {
    continue;
  }

  const obj = readJson(file);
  const missing = enKeys.filter((k) => !(k in obj));
  if (missing.length) {
    errors.push(`${lang}: missing keys ${missing.join(", ")}`);
    continue;
  }

  const out = {};
  for (const key of enKeys) {
    let value = obj[key];
    if (typeof value !== "string") {
      errors.push(`${lang}: key ${key} is not string`);
      value = String(value ?? "");
    }

    const repaired = repairMojibake(value);
    if (placeholders(repaired) !== placeholders(en[key])) {
      errors.push(
        `${lang}: placeholder mismatch at ${key} -> '${placeholders(
          repaired
        )}' expected '${placeholders(en[key])}'`
      );
    }

    out[key] = repaired;
  }

  const extra = Object.keys(obj).filter((k) => !enKeys.includes(k));
  if (extra.length) {
    errors.push(`${lang}: extra keys ${extra.join(", ")}`);
  }

  const before = fs.readFileSync(file, "utf8");
  const after = `${JSON.stringify(out, null, 4)}\n`;
  if (before !== after) {
    fs.writeFileSync(file, after, "utf8");
    modified.push(file);
  }
}

if (errors.length) {
  console.error("VALIDATION_ERRORS_START");
  for (const e of errors) {
    console.error(e);
  }
  console.error("VALIDATION_ERRORS_END");
  process.exit(2);
}

console.log("MODIFIED_FILES_START");
for (const f of modified) {
  console.log(f);
}
console.log("MODIFIED_FILES_END");
