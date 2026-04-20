import fs from "node:fs/promises";
import path from "node:path";
import { chromium } from "playwright";

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function ensurePageOpen(page) {
  if (page.isClosed()) {
    throw new Error("浏览器页面已关闭，请重新运行导出脚本。");
  }
}

function parseArgs(argv) {
  const options = {};
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (!token.startsWith("--")) {
      continue;
    }

    const key = token.slice(2);
    const next = argv[index + 1];
    if (!next || next.startsWith("--")) {
      options[key] = true;
      continue;
    }

    options[key] = next;
    index += 1;
  }
  return options;
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const targetUrl = options.url || "https://www.runcomfy.com/";
  const outputDir = path.resolve(process.cwd(), options.output || "./output/runcomfy");
  const profileDir = path.resolve(process.cwd(), ".playwright/runcomfy-profile");

  await fs.mkdir(outputDir, { recursive: true });
  await fs.mkdir(path.dirname(profileDir), { recursive: true });

  const context = await chromium.launchPersistentContext(profileDir, {
    headless: false,
    acceptDownloads: true,
    viewport: { width: 1440, height: 960 }
  });
  let contextClosed = false;
  context.on("close", () => {
    contextClosed = true;
  });

  const page = context.pages().find((item) => !item.isClosed()) || (await context.newPage());

  try {
    console.log(`打开页面: ${targetUrl}`);
    await page.goto(targetUrl, { waitUntil: "domcontentloaded" });

    console.log("如果还没登录，请先在打开的浏览器里完成登录。");
    console.log("如果页面不是目标 workflow，请手动切到 RunComfy 的 ComfyUI 工作流页面。");

    await sleep(1500);
    await waitForWorkflowUi(page);

    const exportPath = path.join(outputDir, "workflow_api.json");
    const download = await exportWorkflowApi(page, exportPath);

    console.log(`导出完成: ${download}`);
    console.log(`已保存到: ${exportPath}`);
  } finally {
    if (!contextClosed) {
      await context.close();
    }
  }
}

async function waitForWorkflowUi(page) {
  const workflowButton = page.getByText("Workflow", { exact: true });
  const timeoutMs = 10 * 60 * 1000;
  const start = Date.now();

  while (Date.now() - start < timeoutMs) {
    ensurePageOpen(page);
    if (await workflowButton.count()) {
      try {
        await workflowButton.first().waitFor({ state: "visible", timeout: 1000 });
        return;
      } catch {
        // keep waiting
      }
    }
    await sleep(1000);
  }

  throw new Error("10 分钟内没看到 ComfyUI 的 Workflow 菜单。请确认你已经进入 RunComfy 的工作流页面。");
}

async function exportWorkflowApi(page, exportPath) {
  ensurePageOpen(page);
  const workflowButton = page.getByText("Workflow", { exact: true }).first();
  await workflowButton.click();

  const exportApiItem = page.getByText("Export (API)", { exact: true }).first();
  await exportApiItem.waitFor({ state: "visible", timeout: 10000 });

  const downloadPromise = page.waitForEvent("download", { timeout: 20000 });
  await exportApiItem.click();
  const download = await downloadPromise;
  await download.saveAs(exportPath);
  return exportPath;
}

main().catch((error) => {
  console.error(error.message || error);
  process.exitCode = 1;
});
