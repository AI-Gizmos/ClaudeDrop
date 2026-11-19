#!/usr/bin/env node
// ClaudeDrop connector: a zero-dependency MCP server (stdio) that lets Claude
// read what the ClaudeDrop app saved into ~/ClaudeDrop/Inbox/<Project>/.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import readline from 'node:readline';
import { execFileSync } from 'node:child_process';

const ROOT = process.env.CLAUDEDROP_INBOX || path.join(os.homedir(), 'ClaudeDrop', 'Inbox');
const CACHE = path.join(os.tmpdir(), 'claudedrop-cache');
const MAX_TEXT = 100_000; // characters returned for one item
const MAX_IMAGE_BYTES = 700_000; // keeps the base64 result under the tool-result limit
const ID_RE = /^[A-Za-z0-9_-]+$/;

// ---------- inbox access ----------

function projectNames() {
  if (!fs.existsSync(ROOT)) return [];
  return fs
    .readdirSync(ROOT, { withFileTypes: true })
    .filter((d) => d.isDirectory() && !d.name.startsWith('.'))
    .map((d) => d.name)
    .sort((a, b) => a.localeCompare(b));
}

// Resolve what Claude typed to a real folder name, never to a path it supplied.
function resolveProject(input) {
  const names = projectNames();
  const want = String(input ?? '').trim().toLowerCase();
  if (!want) throw new Error(`No project given. Projects: ${names.join(', ') || '(none yet)'}`);
  const exact = names.find((n) => n.toLowerCase() === want);
  if (exact) return exact;
  const partial = names.filter((n) => n.toLowerCase().includes(want) || want.includes(n.toLowerCase()));
  if (partial.length === 1) return partial[0];
  throw new Error(`No drop box project matches "${input}". Projects: ${names.join(', ') || '(none yet)'}`);
}

function readItems(project, archived = false) {
  const dir = archived ? path.join(ROOT, project, 'archived') : path.join(ROOT, project);
  if (!fs.existsSync(dir)) return [];
  const items = [];
  for (const f of fs.readdirSync(dir)) {
    if (!f.endsWith('.json')) continue;
    try {
      const item = JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8'));
      if (item && ID_RE.test(item.id ?? '')) items.push({ ...item, archived });
    } catch {
      // skip a half-written or damaged entry
    }
  }
  return items.sort((a, b) => String(a.id).localeCompare(String(b.id)));
}

function findItem(project, id) {
  if (!ID_RE.test(id ?? '')) throw new Error(`Invalid item id: ${id}`);
  for (const archived of [false, true]) {
    const p = path.join(ROOT, project, archived ? 'archived' : '', `${id}.json`);
    if (fs.existsSync(p)) return { ...JSON.parse(fs.readFileSync(p, 'utf8')), archived };
  }
  throw new Error(`No item ${id} in project "${project}".`);
}

// Stored file paths are relative to the project folder; refuse anything that escapes it.
function storedPath(project, rel) {
  const base = path.join(ROOT, project);
  const full = path.resolve(base, rel);
  if (!full.startsWith(base + path.sep)) throw new Error('Stored path escapes the project folder.');
  return full;
}

function summary(item) {
  const bits = [`[${item.id}] ${item.kind}: ${item.title ?? '(untitled)'}`];
  if (item.url) bits.push(`  url: ${item.url}`);
  if (item.note) bits.push(`  note: ${item.note}`);
  if (item.size) bits.push(`  size: ${item.size} bytes`);
  bits.push(`  added: ${item.addedAt}${item.archived ? ' (archived)' : ''}`);
  return bits.join('\n');
}

// ---------- content readers ----------

function clip(text) {
  if (text.length <= MAX_TEXT) return text;
  return `${text.slice(0, MAX_TEXT)}\n\n[Truncated: showing the first ${MAX_TEXT} of ${text.length} characters.]`;
}

function looksLikeText(buf) {
  const sample = buf.subarray(0, 8192);
  if (sample.includes(0)) return false;
  try {
    new TextDecoder('utf-8', { fatal: true }).decode(sample.subarray(0, Math.max(0, sample.length - 4)));
    return true;
  } catch {
    return false;
  }
}

// Downscale with the built-in `sips` so large screenshots still fit in a tool result.
function imageContent(file, id) {
  fs.mkdirSync(CACHE, { recursive: true });
  for (const maxSide of [1568, 1024, 640]) {
    const out = path.join(CACHE, `${id}-${maxSide}.jpg`);
    try {
      execFileSync('/usr/bin/sips', ['-Z', String(maxSide), '-s', 'format', 'jpeg', '-s', 'formatOptions', '80', file, '--out', out], { stdio: 'ignore' });
      const data = fs.readFileSync(out);
      if (data.length <= MAX_IMAGE_BYTES || maxSide === 640) {
        return { type: 'image', data: data.toString('base64'), mimeType: 'image/jpeg' };
      }
    } catch {
      return null;
    }
  }
  return null;
}

function itemContent(project, item) {
  const content = [{ type: 'text', text: summary(item) }];
  if (item.kind === 'link') {
    content.push({ type: 'text', text: `This item is a link. Open it with a web tool if you need the page itself: ${item.url}` });
    return content;
  }
  if (item.kind === 'text') {
    content.push({ type: 'text', text: clip(item.text ?? '') });
    return content;
  }
  if (!item.file) return content;
  const file = storedPath(project, item.file);
  if (!fs.existsSync(file)) {
    content.push({ type: 'text', text: 'The stored file is missing from the drop box folder.' });
    return content;
  }
  if (item.kind === 'image') {
    const img = imageContent(file, item.id);
    content.push(img ?? { type: 'text', text: `Could not read this image. It is stored at ${file}` });
    return content;
  }
  if (item.extractedText) {
    const p = storedPath(project, item.extractedText);
    if (fs.existsSync(p)) {
      content.push({ type: 'text', text: `Text extracted from ${item.originalName ?? 'the file'}:\n\n${clip(fs.readFileSync(p, 'utf8'))}` });
      return content;
    }
  }
  const buf = fs.readFileSync(file);
  if (looksLikeText(buf)) {
    content.push({ type: 'text', text: clip(buf.toString('utf8')) });
  } else {
    content.push({ type: 'text', text: `This file type can't be read as text here. It is stored on the user's Mac at ${file}` });
  }
  return content;
}

// ---------- tools ----------

const tools = [
  {
    name: 'list_projects',
    description: "List the projects in the user's ClaudeDrop drop box (things they saved for Claude with a hotkey), with how many new items each holds.",
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
    run: () => {
      const names = projectNames();
      if (!names.length) return text('The drop box has no projects yet.');
      return text(names.map((n) => `${n}: ${readItems(n).length} new item(s)`).join('\n'));
    },
  },
  {
    name: 'list_items',
    description: "List what the user dropped into one drop box project: links, notes, images and files, with ids. Use the name of the current Claude project. Then call get_item for the ones you need.",
    inputSchema: {
      type: 'object',
      properties: {
        project: { type: 'string', description: 'Drop box project name (case-insensitive, partial match allowed).' },
        include_archived: { type: 'boolean', description: 'Also list items already archived. Default false.' },
      },
      required: ['project'],
      additionalProperties: false,
    },
    run: ({ project, include_archived }) => {
      const p = resolveProject(project);
      const items = [...readItems(p), ...(include_archived ? readItems(p, true) : [])];
      if (!items.length) return text(`No ${include_archived ? '' : 'new '}items in "${p}".`);
      return text(
        `Drop box project "${p}", ${items.length} item(s):\n\n${items.map(summary).join('\n\n')}\n\nArchive each item with archive_items once you have brought it up with the user.`,
      );
    },
  },
  {
    name: 'get_item',
    description: 'Open one drop box item: returns the text, the image, the link, or the text extracted from a document.',
    inputSchema: {
      type: 'object',
      properties: {
        project: { type: 'string' },
        id: { type: 'string', description: 'Item id from list_items.' },
      },
      required: ['project', 'id'],
      additionalProperties: false,
    },
    run: ({ project, id }) => {
      const p = resolveProject(project);
      return { content: itemContent(p, findItem(p, id)) };
    },
  },
  {
    name: 'archive_items',
    description: "Move drop box items to the project's archive so they stop showing as new in later sessions. Do this yourself, without asking, as soon as you have opened an item and brought it up with the user in this conversation, then tell them in one line what you archived. Leave items you listed but did not get to. Archived items stay on disk, can still be opened, and can be brought back with restore_items.",
    inputSchema: {
      type: 'object',
      properties: {
        project: { type: 'string' },
        ids: { type: 'array', items: { type: 'string' }, minItems: 1 },
      },
      required: ['project', 'ids'],
      additionalProperties: false,
    },
    run: ({ project, ids }) => moveItems(project, ids, true),
  },
  {
    name: 'restore_items',
    description: 'Bring archived drop box items back so they show as new again. Use this when the user wants to return to something that was archived.',
    inputSchema: {
      type: 'object',
      properties: {
        project: { type: 'string' },
        ids: { type: 'array', items: { type: 'string' }, minItems: 1, description: 'Item ids from list_items with include_archived.' },
      },
      required: ['project', 'ids'],
      additionalProperties: false,
    },
    run: ({ project, ids }) => moveItems(project, ids, false),
  },
];

// Move item entries into the project's archived folder, or back out of it.
function moveItems(project, ids, toArchive) {
  const p = resolveProject(project);
  const live = path.join(ROOT, p);
  const archive = path.join(live, 'archived');
  const [fromDir, toDir] = toArchive ? [live, archive] : [archive, live];
  fs.mkdirSync(toDir, { recursive: true });
  const done = [];
  const missing = [];
  for (const id of ids ?? []) {
    const from = path.join(fromDir, `${id}.json`);
    if (ID_RE.test(id) && fs.existsSync(from)) {
      fs.renameSync(from, path.join(toDir, `${id}.json`));
      done.push(id);
    } else {
      missing.push(id);
    }
  }
  return text(`${toArchive ? 'Archived' : 'Restored'}: ${done.join(', ') || 'none'}${missing.length ? `\nNot found: ${missing.join(', ')}` : ''}`);
}

function text(t) {
  return { content: [{ type: 'text', text: t }] };
}

// ---------- JSON-RPC over stdio ----------

function send(msg) {
  process.stdout.write(`${JSON.stringify(msg)}\n`);
}

function handle(msg) {
  const { id, method, params } = msg;
  if (id === undefined || id === null) return; // notification: nothing to answer
  try {
    if (method === 'initialize') {
      return send({
        jsonrpc: '2.0',
        id,
        result: {
          protocolVersion: params?.protocolVersion ?? '2024-11-05',
          capabilities: { tools: {} },
          serverInfo: { name: 'claudedrop', version: '1.0.0' },
          instructions:
            "ClaudeDrop is the user's personal drop box for Claude. They save links, notes, images and files into it per project with a hotkey. When they mention the drop box, or something they 'dropped' or 'sent', call list_items with the current project's name. Once you have opened an item and brought it up with them, call archive_items for it without being asked, so it is not raised again in later sessions, and say in one line what you archived. If they want an archived item back, use restore_items.",
        },
      });
    }
    if (method === 'ping') return send({ jsonrpc: '2.0', id, result: {} });
    if (method === 'tools/list') {
      return send({ jsonrpc: '2.0', id, result: { tools: tools.map(({ run, ...t }) => t) } });
    }
    if (method === 'tools/call') {
      const tool = tools.find((t) => t.name === params?.name);
      if (!tool) return send({ jsonrpc: '2.0', id, error: { code: -32602, message: `Unknown tool: ${params?.name}` } });
      try {
        return send({ jsonrpc: '2.0', id, result: tool.run(params.arguments ?? {}) });
      } catch (err) {
        return send({ jsonrpc: '2.0', id, result: { content: [{ type: 'text', text: String(err.message ?? err) }], isError: true } });
      }
    }
    if (method === 'resources/list') return send({ jsonrpc: '2.0', id, result: { resources: [] } });
    if (method === 'prompts/list') return send({ jsonrpc: '2.0', id, result: { prompts: [] } });
    send({ jsonrpc: '2.0', id, error: { code: -32601, message: `Method not found: ${method}` } });
  } catch (err) {
    send({ jsonrpc: '2.0', id, error: { code: -32603, message: String(err.message ?? err) } });
  }
}

readline.createInterface({ input: process.stdin }).on('line', (line) => {
  if (!line.trim()) return;
  let msg;
  try {
    msg = JSON.parse(line);
  } catch {
    return send({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Parse error' } });
  }
  handle(msg);
});
