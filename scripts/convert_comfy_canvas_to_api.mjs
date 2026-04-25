const PASSTHROUGH_NODE_TYPES = new Set([
  "easy cleanGpuUsed",
  "easy sleep",
]);

const LOCAL_HELPER_NODE_TYPES = new Set([
  "DF_Integer",
  "Int",
  "SimpleMath+",
  "StringToInt",
  "easy showAnything",
]);

function cloneJson(value) {
  return JSON.parse(JSON.stringify(value));
}

function getNodeTitle(node) {
  return node.title || node.properties?.["Node name for S&R"] || node.type;
}

function normalizeNodeId(value) {
  return String(value);
}

function getWidgetValue(node, inputName, widgetIndexByInputName) {
  const values = node.widgets_values;
  if (values === undefined || values === null) {
    return undefined;
  }

  if (Array.isArray(values)) {
    const index = widgetIndexByInputName.get(inputName);
    if (index === undefined || index >= values.length) {
      return undefined;
    }
    return cloneJson(values[index]);
  }

  if (typeof values === "object" && Object.hasOwn(values, inputName)) {
    return cloneJson(values[inputName]);
  }

  return undefined;
}

function buildWidgetIndex(node) {
  const widgetInputs = (node.inputs || []).filter((input) => input.widget?.name);
  const indexByInputName = new Map();

  if (node.type === "KSampler") {
    const fixedIndexes = {
      seed: 0,
      steps: 2,
      cfg: 3,
      sampler_name: 4,
      scheduler: 5,
      denoise: 6,
    };
    for (const input of widgetInputs) {
      if (Object.hasOwn(fixedIndexes, input.name)) {
        indexByInputName.set(input.name, fixedIndexes[input.name]);
      }
    }
    return indexByInputName;
  }

  let widgetIndex = 0;
  for (const input of widgetInputs) {
    indexByInputName.set(input.name, widgetIndex);
    widgetIndex += 1;
  }

  return indexByInputName;
}

function createWorkflowIndex(workflow) {
  const nodes = Array.isArray(workflow.nodes) ? workflow.nodes : [];
  const nodeById = new Map(nodes.map((node) => [normalizeNodeId(node.id), node]));
  const linkById = new Map();

  for (const link of workflow.links || []) {
    const [id, originId, originSlot, targetId, targetSlot, type] = link;
    linkById.set(id, {
      id,
      originId: normalizeNodeId(originId),
      originSlot,
      targetId: normalizeNodeId(targetId),
      targetSlot,
      type,
    });
  }

  return { nodes, nodeById, linkById };
}

function createLinkResolver(index) {
  const variableSourceByName = new Map();
  const resolvingVariables = new Set();

  function getLocalInputValue(node, inputName, seen) {
    const input = (node.inputs || []).find((candidate) => candidate.name === inputName);
    if (!input) {
      return undefined;
    }
    if (input.link !== null && input.link !== undefined) {
      const resolved = resolveLink(input.link, seen);
      if (resolved !== null && resolved !== undefined && !Array.isArray(resolved)) {
        return resolved;
      }
    }

    const widgetIndexByInputName = buildWidgetIndex(node);
    return getWidgetValue(node, input.name, widgetIndexByInputName);
  }

  function evaluateExpression(expression, values) {
    const source = String(expression || "").trim();
    if (!/^[abc0-9+\-*/ ().]+$/.test(source)) {
      return undefined;
    }

    const a = Number(values.a ?? 0);
    const b = Number(values.b ?? 0);
    const c = Number(values.c ?? 0);
    return Function("a", "b", "c", `"use strict"; return (${source});`)(a, b, c);
  }

  function evaluateLocalHelperNode(node, seen) {
    if (node.type === "Int") {
      return getLocalInputValue(node, "value", seen);
    }

    if (node.type === "DF_Integer") {
      return getLocalInputValue(node, "Value", seen);
    }

    if (node.type === "SimpleMath+") {
      return evaluateExpression(getLocalInputValue(node, "value", seen), {
        a: getLocalInputValue(node, "a", seen),
        b: getLocalInputValue(node, "b", seen),
        c: getLocalInputValue(node, "c", seen),
      });
    }

    if (node.type === "easy showAnything") {
      const linkedValue = getLocalInputValue(node, "anything", seen);
      if (linkedValue !== undefined) {
        return String(linkedValue);
      }
      return Array.isArray(node.widgets_values) ? node.widgets_values[0] : undefined;
    }

    if (node.type === "StringToInt") {
      const value = getLocalInputValue(node, "string", seen);
      if (value === undefined || value === null || value === "") {
        return undefined;
      }
      return Number.parseInt(String(value), 10);
    }

    return undefined;
  }

  function resolveLink(linkId, seen = new Set()) {
    const link = index.linkById.get(linkId);
    if (!link) {
      return null;
    }

    const sourceNode = index.nodeById.get(link.originId);
    if (!sourceNode) {
      return null;
    }

    const seenKey = `${link.originId}:${link.originSlot}`;
    if (seen.has(seenKey)) {
      return null;
    }
    seen.add(seenKey);

    if (sourceNode.type === "GetNode") {
      const name = Array.isArray(sourceNode.widgets_values) ? sourceNode.widgets_values[0] : null;
      if (!name) {
        return null;
      }
      return resolveVariable(name, seen);
    }

    if (sourceNode.type === "SetNode") {
      const firstLinkedInput = (sourceNode.inputs || []).find((input) => input.link !== null && input.link !== undefined);
      return firstLinkedInput ? resolveLink(firstLinkedInput.link, seen) : null;
    }

    if (PASSTHROUGH_NODE_TYPES.has(sourceNode.type)) {
      const firstLinkedInput = (sourceNode.inputs || []).find((input) => input.link !== null && input.link !== undefined);
      return firstLinkedInput ? resolveLink(firstLinkedInput.link, seen) : null;
    }

    if (LOCAL_HELPER_NODE_TYPES.has(sourceNode.type)) {
      const value = evaluateLocalHelperNode(sourceNode, seen);
      return value === undefined ? null : value;
    }

    return [link.originId, link.originSlot];
  }

  function resolveVariable(name, seen = new Set()) {
    if (variableSourceByName.has(name)) {
      return variableSourceByName.get(name);
    }
    if (resolvingVariables.has(name)) {
      return null;
    }

    resolvingVariables.add(name);
    const setNode = index.nodes
      .filter((node) => node.type === "SetNode")
      .filter((node) => Array.isArray(node.widgets_values) && node.widgets_values[0] === name)
      .sort((left, right) => (left.order ?? 0) - (right.order ?? 0))
      .at(-1);

    let source = null;
    const firstLinkedInput = setNode?.inputs?.find((input) => input.link !== null && input.link !== undefined);
    if (firstLinkedInput) {
      source = resolveLink(firstLinkedInput.link, seen);
    }

    variableSourceByName.set(name, source);
    resolvingVariables.delete(name);
    return source;
  }

  return { resolveLink };
}

export function convertCanvasWorkflow(workflow) {
  if (!Array.isArray(workflow?.nodes)) {
    return cloneJson(workflow);
  }

  const index = createWorkflowIndex(workflow);
  const resolver = createLinkResolver(index);
  const prompt = {};

  const nodes = [...index.nodes]
    .filter((node) => node.type !== "GetNode" && node.type !== "SetNode")
    .filter((node) => !PASSTHROUGH_NODE_TYPES.has(node.type))
    .filter((node) => !LOCAL_HELPER_NODE_TYPES.has(node.type))
    .sort((left, right) => Number(left.id) - Number(right.id));

  for (const node of nodes) {
    const widgetIndexByInputName = buildWidgetIndex(node);
    const inputs = {};

    for (const input of node.inputs || []) {
      let value;
      if (input.link !== null && input.link !== undefined) {
        const resolvedLink = resolver.resolveLink(input.link);
        if (resolvedLink !== null && resolvedLink !== undefined) {
          value = resolvedLink;
        }
      }

      if (value === undefined && input.widget?.name) {
        value = getWidgetValue(node, input.name, widgetIndexByInputName);
      }

      if (value !== undefined) {
        inputs[input.name] = value;
      }
    }

    prompt[normalizeNodeId(node.id)] = {
      inputs,
      class_type: node.type,
      _meta: {
        title: getNodeTitle(node),
      },
    };
  }

  return prompt;
}
