import "dotenv/config";
import { readFileSync } from "node:fs";
import fs from "node:fs/promises";
import path from "node:path";

function loadLocalApiBackup(filePath = path.resolve(process.cwd(), "api.txt")) {
  try {
    const lines = readFileSync(filePath, "utf8")
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean);
    const entries = new Map();
    for (let i = 0; i + 1 < lines.length; i += 2) {
      entries.set(lines[i], lines[i + 1]);
    }
    return entries;
  } catch (error) {
    if (error.code === "ENOENT") {
      return new Map();
    }
    throw error;
  }
}

function getApiBackupValue(entries, ...names) {
  for (const name of names) {
    const value = entries.get(name);
    if (value) {
      return value;
    }
  }
  return "";
}

export function loadAppConfig() {
  const apiBackup = loadLocalApiBackup();
  const workflowConfigPath = path.resolve(
    process.cwd(),
    process.env.RUNCOMFY_WORKFLOW_CONFIG || "./config/workflows.local.json"
  );
  const runComfyApiKey =
    process.env.RUNCOMFY_API_KEY || getApiBackupValue(apiBackup, "RunComfy");
  const openAiApiKey =
    process.env.OPENAI_API_KEY || getApiBackupValue(apiBackup, "OpenAI");
  const s3AccessKeyId =
    process.env.ASSET_S3_ACCESS_KEY_ID ||
    process.env.R2_ACCESS_KEY_ID ||
    getApiBackupValue(apiBackup, "Cloudflare R2 AccessKeyId");
  const s3SecretAccessKey =
    process.env.ASSET_S3_SECRET_ACCESS_KEY ||
    process.env.R2_SECRET_ACCESS_KEY ||
    getApiBackupValue(apiBackup, "Cloudflare R2 SecretAccessKey");

  return {
    runComfyApiKey,
    runComfyBaseUrl: process.env.RUNCOMFY_BASE_URL || "https://api.runcomfy.net/prod/v1",
    workflowConfigPath,
    transcribeProvider:
      process.env.TRANSCRIBE_PROVIDER || (openAiApiKey ? "openai" : "faster-whisper"),
    fasterWhisperPython:
      process.env.FASTER_WHISPER_PYTHON || path.resolve(process.cwd(), ".venv-faster-whisper", "Scripts", "python.exe"),
    fasterWhisperModel: process.env.FASTER_WHISPER_MODEL || "small",
    fasterWhisperDevice: process.env.FASTER_WHISPER_DEVICE || "auto",
    fasterWhisperComputeType: process.env.FASTER_WHISPER_COMPUTE_TYPE || "int8",
    fasterWhisperBeamSize: Number(process.env.FASTER_WHISPER_BEAM_SIZE || 5),
    openAiApiKey,
    openAiBaseUrl: process.env.OPENAI_BASE_URL || "",
    openAiTranscribeModel: process.env.OPENAI_TRANSCRIBE_MODEL || "whisper-1",
    openAiRewriteModel: process.env.OPENAI_REWRITE_MODEL || "gpt-4.1-mini",
    defaultRewriteStyle:
      process.env.REWRITE_STYLE ||
      "中文短视频口播，逻辑更紧，避免原句复刻，保留行业信息密度",
    assetStorage: {
      s3Endpoint: process.env.ASSET_S3_ENDPOINT || "",
      s3Region: process.env.ASSET_S3_REGION || "auto",
      s3Bucket: process.env.ASSET_S3_BUCKET || "",
      s3AccessKeyId,
      s3SecretAccessKey,
      s3PublicBaseUrl: process.env.ASSET_S3_PUBLIC_BASE_URL || "",
      s3SignedUrlExpiresSec: Number(process.env.ASSET_S3_SIGNED_URL_EXPIRES_SEC || 0),
      s3ForcePathStyle: `${process.env.ASSET_S3_FORCE_PATH_STYLE || ""}`.toLowerCase() === "true",
      s3Prefix: process.env.ASSET_S3_PREFIX || "runcomfy-inputs"
    }
  };
}

export async function loadWorkflowRegistry(config) {
  try {
    const raw = await fs.readFile(config.workflowConfigPath, "utf8");
    return JSON.parse(raw);
  } catch (error) {
    if (error.code === "ENOENT") {
      return {};
    }
    throw error;
  }
}
