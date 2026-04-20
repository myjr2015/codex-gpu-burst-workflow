import { getNestedValue } from "./utils.js";

export function buildJobsFromPlan({ plan, workflowRegistry, globals }) {
  const jobs = [];

  for (const segment of plan.segments) {
    const workflow = workflowRegistry[segment.runcomfyWorkflow];
    if (!workflow) {
      jobs.push({
        segmentIndex: segment.index,
        workflowKey: segment.runcomfyWorkflow,
        error: "workflow 未在 config/workflows.local.json 中配置",
        segment
      });
      continue;
    }
    if (!hasConfiguredDeploymentId(workflow.deploymentId)) {
      jobs.push({
        segmentIndex: segment.index,
        workflowKey: segment.runcomfyWorkflow,
        error: "deploymentId 未在 config/workflows.local.json 中配置",
        segment
      });
      continue;
    }

    const context = { segment, globals };
    const overrides = structuredClone(workflow.baseOverrides || {});

    for (const binding of workflow.inputBindings || []) {
      const value = getNestedValue(context, binding.from);
      if (value === undefined || value === null || value === "") {
        continue;
      }

      overrides[binding.nodeId] = overrides[binding.nodeId] || { inputs: {} };
      overrides[binding.nodeId].inputs = overrides[binding.nodeId].inputs || {};
      overrides[binding.nodeId].inputs[binding.inputName] = value;
    }

    jobs.push({
      segmentIndex: segment.index,
      workflowKey: segment.runcomfyWorkflow,
      deploymentId: workflow.deploymentId,
      request: {
        overrides
      },
      segment
    });
  }

  return jobs;
}

function hasConfiguredDeploymentId(deploymentId) {
  if (!deploymentId) {
    return false;
  }

  return deploymentId.trim().toLowerCase() !== "replace-with-your-runcomfy-deployment-id";
}

export async function submitJob({ config, deploymentId, requestBody }) {
  const response = await fetch(
    `${config.runComfyBaseUrl}/deployments/${deploymentId}/inference`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${config.runComfyApiKey}`
      },
      body: JSON.stringify(requestBody)
    }
  );

  const json = await response.json();
  if (!response.ok || hasRunComfyError(json)) {
    throw new Error(`RunComfy 提交失败: ${response.status} ${JSON.stringify(json)}`);
  }

  return json;
}

export async function createDeployment({ config, body }) {
  const response = await fetch(`${config.runComfyBaseUrl.replace(/\/v1$/, "/v2")}/deployments`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${config.runComfyApiKey}`
    },
    body: JSON.stringify(body)
  });

  const json = await response.json();
  if (!response.ok || hasRunComfyError(json)) {
    throw new Error(`RunComfy deployment 创建失败: ${response.status} ${JSON.stringify(json)}`);
  }

  return json;
}

export async function getDeployment({ config, deploymentId, includePayload = true }) {
  const url = new URL(`${config.runComfyBaseUrl.replace(/\/v1$/, "/v2")}/deployments/${deploymentId}`);
  if (includePayload) {
    url.searchParams.append("includes", "payload");
  }

  const response = await fetch(url, {
    headers: {
      Authorization: `Bearer ${config.runComfyApiKey}`
    }
  });

  const json = await response.json();
  if (!response.ok || hasRunComfyError(json)) {
    throw new Error(`RunComfy deployment 查询失败: ${response.status} ${JSON.stringify(json)}`);
  }

  return json;
}

export async function updateDeployment({ config, deploymentId, body }) {
  const response = await fetch(`${config.runComfyBaseUrl.replace(/\/v1$/, "/v2")}/deployments/${deploymentId}`, {
    method: "PATCH",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${config.runComfyApiKey}`
    },
    body: JSON.stringify(body)
  });

  const json = await response.json();
  if (!response.ok || hasRunComfyError(json)) {
    throw new Error(`RunComfy deployment 更新失败: ${response.status} ${JSON.stringify(json)}`);
  }

  return json;
}

export async function getRequestStatus({ config, deploymentId, requestId }) {
  const response = await fetch(
    `${config.runComfyBaseUrl}/deployments/${deploymentId}/requests/${requestId}/status`,
    {
      headers: {
        Authorization: `Bearer ${config.runComfyApiKey}`
      }
    }
  );

  const json = await response.json();
  if (!response.ok || hasRunComfyError(json)) {
    throw new Error(`RunComfy 状态查询失败: ${response.status} ${JSON.stringify(json)}`);
  }

  return json;
}

export async function getRequestResult({ config, deploymentId, requestId }) {
  const response = await fetch(
    `${config.runComfyBaseUrl}/deployments/${deploymentId}/requests/${requestId}/result`,
    {
      headers: {
        Authorization: `Bearer ${config.runComfyApiKey}`
      }
    }
  );

  const json = await response.json();
  if (!response.ok || hasRunComfyError(json)) {
    throw new Error(`RunComfy 结果查询失败: ${response.status} ${JSON.stringify(json)}`);
  }

  return json;
}

export async function listDeployments({ config, includePayload = false }) {
  const url = new URL(`${config.runComfyBaseUrl.replace(/\/v1$/, "/v2")}/deployments`);
  if (includePayload) {
    url.searchParams.append("includes", "payload");
  }

  const response = await fetch(url, {
    headers: {
      Authorization: `Bearer ${config.runComfyApiKey}`
    }
  });

  const json = await response.json();
  if (!response.ok || hasRunComfyError(json)) {
    throw new Error(`RunComfy deployment 列表查询失败: ${response.status} ${JSON.stringify(json)}`);
  }

  return json;
}

function hasRunComfyError(payload) {
  return Boolean(payload && typeof payload === "object" && "error_code" in payload);
}
