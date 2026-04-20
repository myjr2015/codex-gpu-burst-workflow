import "dotenv/config";
import fs from "node:fs/promises";
import path from "node:path";

export function loadAppConfig() {
  const workflowConfigPath = path.resolve(
    process.cwd(),
    process.env.RUNCOMFY_WORKFLOW_CONFIG || "./config/workflows.local.json"
  );

  return {
    runComfyApiKey: process.env.RUNCOMFY_API_KEY || "",
    runComfyBaseUrl: process.env.RUNCOMFY_BASE_URL || "https://api.runcomfy.net/prod/v1",
    workflowConfigPath,
    transcribeProvider:
      process.env.TRANSCRIBE_PROVIDER || (process.env.OPENAI_API_KEY ? "openai" : "faster-whisper"),
    fasterWhisperPython:
      process.env.FASTER_WHISPER_PYTHON || path.resolve(process.cwd(), ".venv-faster-whisper", "Scripts", "python.exe"),
    fasterWhisperModel: process.env.FASTER_WHISPER_MODEL || "small",
    fasterWhisperDevice: process.env.FASTER_WHISPER_DEVICE || "auto",
    fasterWhisperComputeType: process.env.FASTER_WHISPER_COMPUTE_TYPE || "int8",
    fasterWhisperBeamSize: Number(process.env.FASTER_WHISPER_BEAM_SIZE || 5),
    openAiApiKey: process.env.OPENAI_API_KEY || "",
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
      s3AccessKeyId: process.env.ASSET_S3_ACCESS_KEY_ID || "",
      s3SecretAccessKey: process.env.ASSET_S3_SECRET_ACCESS_KEY || "",
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
