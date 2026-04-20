import { z } from "zod";

const segmentSchema = z.object({
  index: z.number().int().positive(),
  durationSec: z.number().positive(),
  segmentType: z.enum(["main_talking_head", "broll", "multitalk", "lipsync_fix"]),
  voiceover: z.string().min(1),
  visualPrompt: z.string().min(1),
  runcomfyWorkflow: z.string().min(1),
  notes: z.string().default("")
});

export const rewritePlanSchema = z.object({
  title: z.string().min(1),
  hook: z.string().min(1),
  summary: z.string().min(1),
  script: z.string().min(1),
  segments: z.array(segmentSchema).min(1)
});

export function validateRewritePlan(plan) {
  return rewritePlanSchema.parse(plan);
}

export function createFallbackRewritePlan({ transcriptText, transcriptSegments, videoMeta, styleHint }) {
  const initialLines = buildFallbackLines({ transcriptText, transcriptSegments, videoMeta });
  const targetSegments = Math.max(1, initialLines.length);
  const segments = [];

  for (let index = 0; index < targetSegments; index += 1) {
    const slice = initialLines.slice(index, index + 1);
    if (slice.length === 0) {
      break;
    }

    const voiceover = buildFallbackVoiceover(slice, index);
    segments.push({
      index: index + 1,
      durationSec: estimateSegmentDuration(voiceover),
      segmentType: "main_talking_head",
      voiceover,
      visualPrompt: `新的女性讲解形象，中文口播，竖屏短视频，语气利落，围绕这段旁白讲话：${voiceover}`,
      runcomfyWorkflow: "wan_animate",
      notes: "Fallback 规划默认走 wan_animate，必要时先清洗驱动视频里的字幕区"
    });
  }

  const script = segments.map((segment) => segment.voiceover).join("\n");
  return validateRewritePlan({
    title: "光伏讲解重写版",
    hook: "先讲用户为什么要看，再讲收益和风险。",
    summary: `Fallback 方案，适合先跑通流程。风格要求：${styleHint}`,
    script,
    segments
  });
}

function compactTranscript(input) {
  return String(input || "")
    .replace(/\s+/g, " ")
    .trim();
}

function buildFallbackVoiceover(lines, index) {
  const joined = lines.join("，");
  if (index === 0) {
    return joined;
  }

  return joined;
}

function estimateSegmentDuration(text) {
  const charsPerSecond = 4.2;
  const duration = Math.ceil(text.length / charsPerSecond);
  return Math.max(6, Math.min(15, duration));
}

function expandLinesToTarget(lines, targetSegments) {
  const result = [...lines];
  const fallbackTopics = [
    "先讲适合装光伏的屋顶条件",
    "再讲装机成本和并网流程",
    "补一段回本周期和收益测算",
    "穿插风险点，避免只讲收益",
    "讲清逆变器、组件和施工质量",
    "补充工商业和户用场景差异",
    "强调售后和运维响应",
    "最后给出咨询或测算动作"
  ];

  let topicIndex = 0;
  while (result.length < targetSegments) {
    result.push(fallbackTopics[topicIndex % fallbackTopics.length]);
    topicIndex += 1;
  }

  return result;
}

function buildFallbackLines({ transcriptText, transcriptSegments, videoMeta }) {
  const grouped = groupTranscriptSegments(transcriptSegments, videoMeta?.durationSec || 0);
  if (grouped.length > 0) {
    return grouped;
  }

  const cleaned = compactTranscript(transcriptText);
  const sentences = cleaned
    .split(/[。！？!?]/)
    .map((item) => item.trim())
    .filter(Boolean);

  if (sentences.length > 0) {
    const targetSegments = Math.max(1, Math.min(12, Math.ceil((videoMeta?.durationSec || 120) / 12)));
    return expandLinesToTarget(sentences, targetSegments).slice(0, targetSegments);
  }

  return ["光伏行业讲解视频，先给出价值判断，再讲成本和收益，最后给出行动指引"];
}

function groupTranscriptSegments(transcriptSegments, totalDurationSec) {
  const segments = Array.isArray(transcriptSegments)
    ? transcriptSegments
        .map((segment) => ({
          text: compactTranscript(segment?.text),
          start: Number(segment?.start || 0),
          end: Number(segment?.end || 0)
        }))
        .filter((segment) => segment.text)
    : [];

  if (segments.length === 0) {
    return [];
  }

  const targetGroupDurationSec = Math.max(4, Math.min(12, (totalDurationSec || 0) / Math.min(segments.length, 8) || 8));
  const grouped = [];
  let currentTexts = [];
  let currentDurationSec = 0;

  for (const segment of segments) {
    const durationSec = Math.max(0.5, segment.end - segment.start || 0.5);
    currentTexts.push(segment.text);
    currentDurationSec += durationSec;

    if (currentDurationSec >= targetGroupDurationSec || grouped.length >= 10) {
      grouped.push(joinTranscriptTexts(currentTexts));
      currentTexts = [];
      currentDurationSec = 0;
    }
  }

  if (currentTexts.length > 0) {
    grouped.push(joinTranscriptTexts(currentTexts));
  }

  return grouped.slice(0, 12);
}

function joinTranscriptTexts(items) {
  return items
    .join("，")
    .replace(/，{2,}/g, "，")
    .replace(/^[，。！？!?]+|[，。！？!?]+$/g, "")
    .trim();
}
