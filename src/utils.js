import fs from "node:fs/promises";
import path from "node:path";

export function parseArgs(argv) {
  const options = {};
  const positionals = [];

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (!token.startsWith("--")) {
      positionals.push(token);
      continue;
    }

    const [rawKey, inlineValue] = token.slice(2).split("=", 2);
    const key = rawKey.replace(/-([a-z])/g, (_, letter) => letter.toUpperCase());
    if (inlineValue !== undefined) {
      options[key] = inlineValue;
      continue;
    }

    const nextToken = argv[index + 1];
    if (!nextToken || nextToken.startsWith("--")) {
      options[key] = true;
      continue;
    }

    options[key] = nextToken;
    index += 1;
  }

  return { options, positionals };
}

export function slugify(input) {
  return String(input)
    .normalize("NFKD")
    .replace(/[^\w\u4e00-\u9fa5-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .replace(/-+/g, "-")
    .toLowerCase() || "job";
}

export async function ensureDir(targetPath) {
  await fs.mkdir(targetPath, { recursive: true });
  return targetPath;
}

export async function writeJson(filePath, data) {
  await ensureDir(path.dirname(filePath));
  await fs.writeFile(filePath, `${JSON.stringify(data, null, 2)}\n`, "utf8");
}

export async function readJson(filePath) {
  const raw = await fs.readFile(filePath, "utf8");
  return JSON.parse(raw);
}

export function getNestedValue(root, expression) {
  return expression.split(".").reduce((current, key) => {
    if (current === undefined || current === null) {
      return undefined;
    }
    return current[key];
  }, root);
}

export function formatDuration(seconds) {
  if (!Number.isFinite(seconds)) {
    return "0s";
  }

  if (seconds < 60) {
    return `${seconds.toFixed(1)}s`;
  }

  const minutes = Math.floor(seconds / 60);
  const remainder = seconds % 60;
  return `${minutes}m ${remainder.toFixed(1)}s`;
}
