import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import OpenAI from "openai";
import { createFallbackRewritePlan, validateRewritePlan } from "./planner.js";

function createClient(config) {
  if (!config.openAiApiKey) {
    return null;
  }

  return new OpenAI({
    apiKey: config.openAiApiKey,
    baseURL: config.openAiBaseUrl || undefined
  });
}

export async function transcribeAudio({ config, audioPath, language = "zh" }) {
  switch ((config.transcribeProvider || "").toLowerCase()) {
    case "faster-whisper":
      return transcribeAudioWithFasterWhisper({ config, audioPath, language });
    case "openai":
      return transcribeAudioWithOpenAi({ config, audioPath, language });
    default:
      throw new Error(`不支持的转写 provider: ${config.transcribeProvider}`);
  }
}

async function transcribeAudioWithOpenAi({ config, audioPath, language }) {
  const client = createClient(config);
  if (!client) {
    throw new Error("OPENAI_API_KEY 未配置，无法调用 OpenAI 转写接口。");
  }
  const transcription = await client.audio.transcriptions.create({
    file: fs.createReadStream(audioPath),
    model: config.openAiTranscribeModel,
    language,
    response_format: "verbose_json",
    timestamp_granularities: ["segment"]
  });

  return {
    text: transcription.text || "",
    segments: transcription.segments || []
  };
}

async function transcribeAudioWithFasterWhisper({ config, audioPath, language }) {
  const pythonPath = config.fasterWhisperPython;
  if (!pythonPath || !fs.existsSync(pythonPath)) {
    throw new Error(`FASTER_WHISPER_PYTHON 不可用: ${pythonPath}`);
  }

  const scriptPath = path.resolve(process.cwd(), "scripts", "faster-whisper-transcribe.py");
  if (!fs.existsSync(scriptPath)) {
    throw new Error(`找不到脚本: ${scriptPath}`);
  }

  const args = [
    "-X",
    "utf8",
    scriptPath,
    "--audio-path",
    audioPath,
    "--language",
    language,
    "--model",
    config.fasterWhisperModel,
    "--device",
    config.fasterWhisperDevice,
    "--compute-type",
    config.fasterWhisperComputeType,
    "--beam-size",
    String(config.fasterWhisperBeamSize)
  ];

  const output = await runProcess(pythonPath, args);
  const transcription = JSON.parse(output);
  return {
    text: transcription.text || "",
    segments: transcription.segments || []
  };
}

function runProcess(command, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: process.cwd(),
      env: {
        ...process.env,
        PYTHONIOENCODING: "utf-8",
        PYTHONUTF8: "1"
      },
      stdio: ["ignore", "pipe", "pipe"]
    });
    const stdout = [];
    const stderr = [];

    child.stdout.on("data", (chunk) => stdout.push(chunk));
    child.stderr.on("data", (chunk) => stderr.push(chunk));
    child.on("error", reject);
    child.on("close", (code) => {
      const stdoutText = Buffer.concat(stdout).toString("utf8").trim();
      const stderrText = Buffer.concat(stderr).toString("utf8").trim();
      if (code !== 0) {
        reject(new Error(stderrText || stdoutText || `进程退出码 ${code}`));
        return;
      }
      resolve(stdoutText);
    });
  });
}

export async function rewriteTranscript({
  config,
  transcriptText,
  transcriptSegments,
  videoMeta,
  styleHint,
  minuteTarget = 2
}) {
  const client = createClient(config);
  if (!client) {
    return createFallbackRewritePlan({
      transcriptText,
      transcriptSegments,
      videoMeta,
      styleHint
    });
  }

  const messages = [
    {
      role: "system",
      content:
        "你是短视频编导。请把输入转写改写成新的中文讲解视频脚本，不要复刻原句。输出严格 JSON，不要 Markdown。字段必须包含：title, hook, summary, script, segments。segments 是数组，每项必须包含 index, durationSec, segmentType, voiceover, visualPrompt, runcomfyWorkflow, notes。segmentType 只能是 main_talking_head / broll / multitalk / lipsync_fix。runcomfyWorkflow 只能优先使用 wan_animate、seedance_broll、multitalk、latentsync。总时长控制在目标分钟数附近。"
    },
    {
      role: "user",
      content: JSON.stringify(
        {
          targetMinutes: minuteTarget,
          styleHint: styleHint || config.defaultRewriteStyle,
          videoMeta,
          transcriptText
        },
        null,
        2
      )
    }
  ];

  const completion = await client.chat.completions.create({
    model: config.openAiRewriteModel,
    temperature: 0.8,
    response_format: { type: "json_object" },
    messages
  });

  const content = completion.choices?.[0]?.message?.content;
  if (!content) {
    throw new Error("LLM 没返回可解析内容。");
  }

  return validateRewritePlan(JSON.parse(content));
}
