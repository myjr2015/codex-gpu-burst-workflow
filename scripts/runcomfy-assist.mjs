import fs from "node:fs/promises";
import path from "node:path";
import { chromium } from "playwright";

const outputDir = path.resolve(process.cwd(), "output/runcomfy-assist");
const profileDir = path.resolve(process.cwd(), ".playwright/runcomfy-assist-profile");
const statePath = path.join(outputDir, "state.json");
const runComfyUrl = "https://www.runcomfy.com/";

let latestState = null;

async function ensureDirs() {
  await fs.mkdir(outputDir, { recursive: true });
  await fs.mkdir(path.dirname(profileDir), { recursive: true });
}

async function writeState(state) {
  latestState = state;
  await fs.writeFile(statePath, `${JSON.stringify(state, null, 2)}\n`, "utf8");
}

function uniqueStrings(values) {
  return [...new Set(values.filter(Boolean))];
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function isClosedError(error) {
  return /Target page, context or browser has been closed/i.test(error?.message || "");
}

async function getActivePage(context, currentPage) {
  if (currentPage && !currentPage.isClosed()) {
    return currentPage;
  }

  const existingPage = context.pages().find((page) => !page.isClosed());
  if (existingPage) {
    return existingPage;
  }

  try {
    return await context.newPage();
  } catch {
    return null;
  }
}

async function ensureRunComfyPage(page) {
  if (!page || page.isClosed()) {
    return;
  }

  if (page.url() === "about:blank") {
    await page.goto(runComfyUrl, { waitUntil: "domcontentloaded" });
  }
}

async function inspectPage(page) {
  return page.evaluate(() => {
    const bodyText = document.body?.innerText || "";
    const html = document.documentElement?.outerHTML || "";

    const uuidRegex = /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi;
    const allUuids = Array.from(new Set([...(bodyText.match(uuidRegex) || []), ...(html.match(uuidRegex) || [])]));

    const tokenPatterns = [
      /rc_[A-Za-z0-9_-]{20,}/g,
      /sk_[A-Za-z0-9_-]{20,}/g,
      /Bearer\s+([A-Za-z0-9._-]{20,})/g
    ];

    const foundTokens = [];
    for (const pattern of tokenPatterns) {
      for (const match of bodyText.matchAll(pattern)) {
        foundTokens.push(match[1] || match[0]);
      }
      for (const match of html.matchAll(pattern)) {
        foundTokens.push(match[1] || match[0]);
      }
    }

    const labels = Array.from(document.querySelectorAll("body *"))
      .map((node) => (node.textContent || "").trim())
      .filter(Boolean)
      .slice(0, 2000);

    const apiTokenVisible = labels.some((text) => text.includes("API Token"));
    const accountVisible = labels.some((text) => text === "Account" || text.includes("Account"));
    const deploymentsVisible = labels.some((text) => text === "Deployments" || text.includes("Deployments"));
    const workflowVisible = labels.some((text) => text === "Workflow" || text.includes("Workflow"));

    return {
      url: location.href,
      title: document.title,
      apiTokenVisible,
      accountVisible,
      deploymentsVisible,
      workflowVisible,
      uuids: allUuids,
      tokens: Array.from(new Set(foundTokens)),
      textHints: labels
        .filter((text) =>
          /(API Token|Account|Deployments|deployment|Workflow|Export|Profile|token)/i.test(text)
        )
        .slice(0, 50)
    };
  });
}

async function tryHelpfulClicks(page) {
  const clickByText = async (text) => {
    const locator = page.getByText(text, { exact: true }).first();
    if (await locator.count()) {
      try {
        if (await locator.isVisible({ timeout: 500 })) {
          await locator.click({ timeout: 1000 });
          return true;
        }
      } catch {
        return false;
      }
    }
    return false;
  };

  await clickByText("Account");
  await clickByText("Deployments");
  const revealCandidates = ["Show", "Reveal", "View", "Copy"];
  for (const label of revealCandidates) {
    await clickByText(label);
  }
}

async function main() {
  await ensureDirs();

  const state = {
    startedAt: new Date().toISOString(),
    pagesSeen: [],
    uuidCandidates: [],
    tokenCandidates: [],
    lastSnapshot: null
  };
  await writeState(state);

  const context = await chromium.launchPersistentContext(profileDir, {
    headless: false,
    viewport: { width: 1440, height: 960 }
  });
  let contextClosed = false;
  context.on("close", () => {
    contextClosed = true;
  });

  let page = (await getActivePage(context, null)) || null;
  if (!page) {
    throw new Error("无法创建浏览器页面。");
  }
  await page.goto(runComfyUrl, { waitUntil: "domcontentloaded" });

  console.log("RunComfy 浏览器已打开。请你登录，然后尽量依次点：Account -> API Token，再点 Deployments。");
  console.log(`我会把候选结果持续写到: ${statePath}`);

  const maxMinutes = 30;
  const startedAt = Date.now();

  while (Date.now() - startedAt < maxMinutes * 60 * 1000) {
    if (contextClosed) {
      state.finishedAt = new Date().toISOString();
      state.stopReason = "browser_closed";
      await writeState(state);
      break;
    }

    page = await getActivePage(context, page);
    if (!page) {
      state.finishedAt = new Date().toISOString();
      state.stopReason = "browser_closed";
      await writeState(state);
      break;
    }

    try {
      await ensureRunComfyPage(page);
      await tryHelpfulClicks(page);
      const snapshot = await inspectPage(page);
      state.lastSnapshot = {
        at: new Date().toISOString(),
        ...snapshot
      };
      state.pagesSeen = uniqueStrings([...state.pagesSeen, snapshot.url]);
      state.uuidCandidates = uniqueStrings([...state.uuidCandidates, ...snapshot.uuids]);
      state.tokenCandidates = uniqueStrings([...state.tokenCandidates, ...snapshot.tokens]);
      await writeState(state);
    } catch (error) {
      state.lastSnapshot = {
        at: new Date().toISOString(),
        error: error.message
      };
      await writeState(state);
      if (isClosedError(error) && contextClosed) {
        state.finishedAt = new Date().toISOString();
        state.stopReason = "browser_closed";
        await writeState(state);
        break;
      }
    }

    await sleep(2000);
  }

  state.finishedAt = state.finishedAt || new Date().toISOString();
  state.stopReason = state.stopReason || "timeout";
  await writeState(state);

  if (!contextClosed) {
    await context.close();
  }
}

main().catch(async (error) => {
  await ensureDirs();
  const state = latestState || {
    startedAt: new Date().toISOString(),
    pagesSeen: [],
    uuidCandidates: [],
    tokenCandidates: [],
    lastSnapshot: null
  };
  state.finishedAt = new Date().toISOString();
  state.error = error.message;
  state.lastSnapshot = state.lastSnapshot || {
    at: state.finishedAt,
    error: error.message
  };
  await writeState(state);
  console.error(error.message || error);
  process.exitCode = 1;
});
