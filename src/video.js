import fs from "node:fs/promises";
import path from "node:path";
import { spawn } from "node:child_process";
import ffmpegPath from "ffmpeg-static";
import ffprobeStatic from "ffprobe-static";

function runProcess(command, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      windowsHide: true
    });

    let stdout = "";
    let stderr = "";

    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });

    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });

    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) {
        resolve({ stdout, stderr });
        return;
      }

      reject(new Error(`Command failed (${code}): ${command}\n${stderr}`));
    });
  });
}

export async function probeVideo(inputPath) {
  const absolutePath = path.resolve(process.cwd(), inputPath);
  await fs.access(absolutePath);

  const { stdout } = await runProcess(ffprobeStatic.path, [
    "-v",
    "quiet",
    "-print_format",
    "json",
    "-show_format",
    "-show_streams",
    absolutePath
  ]);

  const parsed = JSON.parse(stdout);
  const videoStream = parsed.streams.find((stream) => stream.codec_type === "video");
  const audioStream = parsed.streams.find((stream) => stream.codec_type === "audio");

  return {
    file: absolutePath,
    durationSec: Number(parsed.format.duration || 0),
    sizeBytes: Number(parsed.format.size || 0),
    bitRate: Number(parsed.format.bit_rate || 0),
    video: videoStream
      ? {
          codec: videoStream.codec_name,
          width: videoStream.width,
          height: videoStream.height,
          fps: parseFrameRate(videoStream.avg_frame_rate)
        }
      : null,
    audio: audioStream
      ? {
          codec: audioStream.codec_name,
          sampleRate: Number(audioStream.sample_rate || 0),
          channels: Number(audioStream.channels || 0)
        }
      : null
  };
}

export async function extractMonoWav(inputPath, outputPath) {
  const absoluteInput = path.resolve(process.cwd(), inputPath);
  const absoluteOutput = path.resolve(process.cwd(), outputPath);
  await fs.mkdir(path.dirname(absoluteOutput), { recursive: true });

  await runProcess(ffmpegPath, [
    "-y",
    "-i",
    absoluteInput,
    "-vn",
    "-ac",
    "1",
    "-ar",
    "16000",
    absoluteOutput
  ]);

  return absoluteOutput;
}

export async function extractBackgroundPlate({
  inputPath,
  outputPath,
  pythonPath,
  sampleCount = 12
}) {
  const absoluteInput = path.resolve(process.cwd(), inputPath);
  const absoluteOutput = path.resolve(process.cwd(), outputPath);
  const samplesDir = path.join(path.dirname(absoluteOutput), `${path.parse(absoluteOutput).name}-samples`);
  await fs.access(absoluteInput);
  await fs.mkdir(path.dirname(absoluteOutput), { recursive: true });
  await fs.mkdir(samplesDir, { recursive: true });

  if (!pythonPath) {
    throw new Error("未配置本地 Python，无法提取背景板。");
  }

  const meta = await probeVideo(absoluteInput);
  const durationSec = Math.max(1, Number(meta.durationSec || 0));
  const count = Math.max(3, Math.min(24, Math.trunc(Number(sampleCount || 12))));
  const frames = [];

  for (let index = 0; index < count; index += 1) {
    const timeSec = durationSec * ((index + 1) / (count + 1));
    const framePath = path.join(samplesDir, `frame-${String(index + 1).padStart(2, "0")}.png`);
    await runProcess(ffmpegPath, [
      "-y",
      "-ss",
      timeSec.toFixed(3),
      "-i",
      absoluteInput,
      "-frames:v",
      "1",
      framePath
    ]);
    frames.push(framePath);
  }

  const scriptPath = path.resolve(process.cwd(), "scripts", "median-background.py");
  await runProcess(pythonPath, [
    "-X",
    "utf8",
    scriptPath,
    "--output",
    absoluteOutput,
    ...frames
  ]);

  return {
    backgroundPlatePath: absoluteOutput,
    sampleFrames: frames
  };
}

export async function prepareDrivingVideo({
  inputPath,
  outputPath,
  cropBottomPx = 0,
  blurBottomPx = 0,
  blurBoxes = []
}) {
  const absoluteInput = path.resolve(process.cwd(), inputPath);
  const absoluteOutput = path.resolve(process.cwd(), outputPath);
  await fs.access(absoluteInput);
  await fs.mkdir(path.dirname(absoluteOutput), { recursive: true });

  if (cropBottomPx > 0 && blurBottomPx > 0) {
    throw new Error("cropBottomPx 和 blurBottomPx 不能同时启用。");
  }

  if (cropBottomPx <= 0 && blurBottomPx <= 0 && blurBoxes.length === 0) {
    throw new Error("prepareDrivingVideo 需要至少一种处理：cropBottomPx、blurBottomPx 或 blurBoxes。");
  }

  const args = [
    "-y",
    "-i",
    absoluteInput
  ];

  const filterGraph = buildDrivingVideoFilterGraph({
    cropBottomPx,
    blurBottomPx,
    blurBoxes
  });

  if (filterGraph) {
    args.push(
      "-filter_complex",
      filterGraph,
      "-map",
      "[outv]",
      "-map",
      "0:a?"
    );
  }

  args.push(
    "-c:v",
    "libx264",
    "-preset",
    "veryfast",
    "-crf",
    "18",
    "-c:a",
    "copy",
    "-movflags",
    "+faststart",
    absoluteOutput
  );

  await runProcess(ffmpegPath, args);
  return absoluteOutput;
}

export async function prepareSpeakerImage({
  inputPath,
  outputPath,
  sheetMode = "none"
}) {
  const absoluteInput = path.resolve(process.cwd(), inputPath);
  const absoluteOutput = path.resolve(process.cwd(), outputPath);
  await fs.access(absoluteInput);
  await fs.mkdir(path.dirname(absoluteOutput), { recursive: true });

  let videoFilter = "";
  if (sheetMode === "triptych_center") {
    videoFilter = "crop=iw/3:ih:iw/3:0";
  } else if (sheetMode === "triptych_left") {
    videoFilter = "crop=iw/3:ih:0:0";
  } else if (sheetMode === "triptych_right") {
    videoFilter = "crop=iw/3:ih:2*iw/3:0";
  } else if (sheetMode !== "none") {
    throw new Error(`未知 speaker sheet mode: ${sheetMode}`);
  }

  const args = ["-y", "-i", absoluteInput];
  if (videoFilter) {
    args.push("-vf", videoFilter);
  }
  args.push("-frames:v", "1", absoluteOutput);

  await runProcess(ffmpegPath, args);
  return absoluteOutput;
}

function buildDrivingVideoFilterGraph({ cropBottomPx, blurBottomPx, blurBoxes }) {
  const sanitizedBoxes = Array.isArray(blurBoxes)
    ? blurBoxes
        .map((box) => ({
          x: Math.max(0, Math.trunc(Number(box.x || 0))),
          y: Math.max(0, Math.trunc(Number(box.y || 0))),
          width: Math.max(1, Math.trunc(Number(box.width || 0))),
          height: Math.max(1, Math.trunc(Number(box.height || 0)))
        }))
        .filter((box) => box.width > 0 && box.height > 0)
    : [];

  const filterParts = [];
  let currentLabel = "0:v";

  if (cropBottomPx > 0) {
    const croppedLabel = "prep0";
    filterParts.push(`[${currentLabel}]crop=in_w:in_h-${Math.trunc(cropBottomPx)}:0:0[${croppedLabel}]`);
    currentLabel = croppedLabel;
  }

  if (blurBottomPx > 0) {
    sanitizedBoxes.push({
      x: 0,
      y: -1,
      width: -1,
      height: Math.trunc(blurBottomPx)
    });
  }

  sanitizedBoxes.forEach((box, index) => {
    const baseLabel = `base${index}`;
    const workLabel = `work${index}`;
    const blurLabel = `blur${index}`;
    const nextLabel = `prep${index + 1}`;
    const cropY = box.y >= 0 ? box.y : `in_h-${box.height}`;
    const cropW = box.width > 0 ? box.width : "in_w";
    const cropX = box.x >= 0 ? box.x : 0;

    filterParts.push(`[${currentLabel}]split=2[${baseLabel}][${workLabel}]`);
    filterParts.push(
      `[${workLabel}]crop=w=${cropW}:h=${box.height}:x=${cropX}:y=${cropY},boxblur=20:2[${blurLabel}]`
    );
    filterParts.push(`[${baseLabel}][${blurLabel}]overlay=${cropX}:${cropY}[${nextLabel}]`);
    currentLabel = nextLabel;
  });

  if (filterParts.length === 0) {
    return "";
  }

  filterParts.push(`[${currentLabel}]copy[outv]`);
  return `${filterParts.join(";")}`;
}

function parseFrameRate(rawValue) {
  if (!rawValue || rawValue === "0/0") {
    return 0;
  }

  const [numerator, denominator] = rawValue.split("/").map(Number);
  if (!numerator || !denominator) {
    return 0;
  }

  return Number((numerator / denominator).toFixed(3));
}
