import fs from "node:fs";
import path from "node:path";
import { GetObjectCommand, S3Client } from "@aws-sdk/client-s3";
import { Upload } from "@aws-sdk/lib-storage";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { slugify } from "./utils.js";

export async function uploadAssets({ config, assets, prefix = "" }) {
  if (!Array.isArray(assets) || assets.length === 0) {
    throw new Error("没有可上传的素材。");
  }

  assertStorageConfig(config.assetStorage);
  const client = createS3Client(config.assetStorage);
  const now = new Date();
  const keyPrefix = buildPrefix(config.assetStorage.s3Prefix, prefix, now);
  const results = [];

  for (let index = 0; index < assets.length; index += 1) {
    const asset = assets[index];
    const resolvedPath = path.resolve(process.cwd(), asset.localPath);
    const stats = await fs.promises.stat(resolvedPath);
    if (!stats.isFile()) {
      throw new Error(`不是文件: ${resolvedPath}`);
    }

    const key = buildObjectKey({
      localPath: resolvedPath,
      role: asset.role,
      index,
      keyPrefix
    });
    const contentType = detectContentType(resolvedPath);
    const upload = new Upload({
      client,
      params: {
        Bucket: config.assetStorage.s3Bucket,
        Key: key,
        Body: fs.createReadStream(resolvedPath),
        ContentType: contentType
      }
    });

    await upload.done();

    results.push({
      role: asset.role,
      localPath: resolvedPath,
      sizeBytes: stats.size,
      contentType,
      bucket: config.assetStorage.s3Bucket,
      key,
      url: await buildAccessUrl({
        client,
        storage: config.assetStorage,
        bucket: config.assetStorage.s3Bucket,
        key
      })
    });
  }

  return {
    uploadedAt: now.toISOString(),
    items: results,
    sourceVideoUrl: results.find((item) => item.role === "sourceVideoUrl")?.url || "",
    speakerImageUrl: results.find((item) => item.role === "speakerImageUrl")?.url || "",
    sourceAudioUrl: results.find((item) => item.role === "sourceAudioUrl")?.url || ""
  };
}

function createS3Client(storage) {
  const clientConfig = {
    region: storage.s3Region,
    forcePathStyle: storage.s3ForcePathStyle,
    credentials: {
      accessKeyId: storage.s3AccessKeyId,
      secretAccessKey: storage.s3SecretAccessKey
    }
  };

  if (storage.s3Endpoint) {
    clientConfig.endpoint = storage.s3Endpoint;
  }

  return new S3Client(clientConfig);
}

function assertStorageConfig(storage) {
  if (!storage?.s3Bucket) {
    throw new Error("缺少 ASSET_S3_BUCKET。");
  }
  if (!storage.s3AccessKeyId || !storage.s3SecretAccessKey) {
    throw new Error("缺少 ASSET_S3_ACCESS_KEY_ID 或 ASSET_S3_SECRET_ACCESS_KEY。");
  }
  if (!storage.s3Endpoint && storage.s3Region === "auto") {
    throw new Error("未设置 ASSET_S3_ENDPOINT 时，ASSET_S3_REGION 不能是 auto。");
  }
  if (!storage.s3PublicBaseUrl && !(storage.s3SignedUrlExpiresSec > 0)) {
    throw new Error("需要配置 ASSET_S3_PUBLIC_BASE_URL，或把 ASSET_S3_SIGNED_URL_EXPIRES_SEC 设为大于 0。");
  }
}

function buildPrefix(defaultPrefix, customPrefix, now) {
  const dateSegment = now.toISOString().slice(0, 10).replace(/-/g, "");
  const prefixParts = [defaultPrefix, customPrefix, dateSegment]
    .filter(Boolean)
    .map((value) => trimSlashes(value));
  return prefixParts.join("/");
}

function buildObjectKey({ localPath, role, index, keyPrefix }) {
  const extension = path.extname(localPath).toLowerCase();
  const baseName = path.basename(localPath, extension);
  const rolePrefix = roleToKeyPrefix(role);
  const uniquePart = `${Date.now()}-${index + 1}`;
  return [keyPrefix, `${uniquePart}-${rolePrefix}-${slugify(baseName)}${extension}`]
    .filter(Boolean)
    .join("/");
}

function roleToKeyPrefix(role) {
  switch (role) {
    case "sourceVideoUrl":
      return "source-video";
    case "speakerImageUrl":
      return "speaker-image";
    case "sourceAudioUrl":
      return "source-audio";
    default:
      return "asset";
  }
}

function detectContentType(filePath) {
  switch (path.extname(filePath).toLowerCase()) {
    case ".png":
      return "image/png";
    case ".jpg":
    case ".jpeg":
      return "image/jpeg";
    case ".webp":
      return "image/webp";
    case ".gif":
      return "image/gif";
    case ".mp4":
      return "video/mp4";
    case ".mov":
      return "video/quicktime";
    case ".m4v":
      return "video/x-m4v";
    case ".webm":
      return "video/webm";
    case ".wav":
      return "audio/wav";
    case ".mp3":
      return "audio/mpeg";
    default:
      return "application/octet-stream";
  }
}

async function buildAccessUrl({ client, storage, bucket, key }) {
  if (storage.s3PublicBaseUrl) {
    const encodedKey = key
      .split("/")
      .map((part) => encodeURIComponent(part))
      .join("/");
    return `${trimSlashes(storage.s3PublicBaseUrl)}/${encodedKey}`;
  }

  return getSignedUrl(
    client,
    new GetObjectCommand({
      Bucket: bucket,
      Key: key
    }),
    {
      expiresIn: storage.s3SignedUrlExpiresSec
    }
  );
}

function trimSlashes(value) {
  return String(value).replace(/^\/+|\/+$/g, "");
}
