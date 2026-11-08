// Transcript parser shared by sync.mjs (builds history/<machine>/index.json),
// viewer.mjs (local server) and index.html (browser). No Node or DOM APIs.

export function cleanText(t) {
  if (typeof t !== 'string') return '';
  let s = t.replace(/<system-reminder>[\s\S]*?<\/system-reminder>/g, '');
  const name = s.match(/<command-name>([\s\S]*?)<\/command-name>/);
  if (name) {
    const a = s.match(/<command-args>([\s\S]*?)<\/command-args>/);
    s = `${name[1].trim()}${a && a[1].trim() ? ' ' + a[1].trim() : ''}`;
  }
  s = s.replace(/<\/?(local-command-stdout|local-command-stderr|command-message|command-args|command-name)>/g, '');
  return s.trim();
}

function imageBlock(b) {
  const src = b.source;
  if (src?.type === 'base64' && src.data) return { type: 'image', src: `data:${src.media_type || 'image/png'};base64,${src.data}` };
  if (src?.type === 'url' && /^https?:\/\//.test(src.url || '')) return { type: 'image', src: src.url };
  return { type: 'text', text: '[รูปภาพ]' };
}

function normBlocks(content) {
  if (typeof content === 'string') {
    const t = cleanText(content);
    return t ? [{ type: 'text', text: t }] : [];
  }
  if (!Array.isArray(content)) return [];
  const out = [];
  for (const b of content) {
    if (!b || typeof b !== 'object') continue;
    if (b.type === 'text') { const t = cleanText(b.text); if (t) out.push({ type: 'text', text: t }); }
    else if (b.type === 'image') out.push(imageBlock(b));
    else if (b.type === 'thinking' && b.thinking?.trim()) out.push({ type: 'thinking', text: b.thinking });
    else if (b.type === 'tool_use') out.push({ type: 'tool_use', id: b.id, name: b.name, input: b.input });
    else if (b.type === 'tool_result') {
      const c = typeof b.content === 'string' ? [{ type: 'text', text: b.content }]
        : (Array.isArray(b.content) ? b.content : []).map(x => (x?.type === 'image' ? imageBlock(x) : { type: 'text', text: typeof x?.text === 'string' ? x.text : JSON.stringify(x) }));
      out.push({ type: 'tool_result', id: b.tool_use_id, error: !!b.is_error, content: c });
    } else if (b.type === 'document') out.push({ type: 'text', text: '[เอกสารแนบ]' });
  }
  return out;
}

export function projectLabel(cwd, folder = '') {
  const src = cwd || folder || '';
  if (/scratch-workspaces|local-agent-mode/i.test(src)) return 'Cowork';
  if (cwd) return cwd.replace(/[\\/]+$/, '').split(/[\\/]/).pop() || cwd;
  return folder.replace(/^[A-Za-z]--Users-[^-]+-?/, '') || folder;
}

// text: the raw .jsonl content of one session
export function parseTranscript(text) {
  let title = null, aiTitle = null, summary = null, cwd = null, sessionId = null, first = null, last = null;
  const msgs = [];
  const toolUses = new Map();
  let lastAssistant = null;
  for (const line of String(text).split('\n')) {
    if (!line.trim()) continue;
    let o;
    try { o = JSON.parse(line); } catch { continue; }
    if (o.type === 'custom-title' && o.customTitle) title = o.customTitle;
    else if (o.type === 'ai-title' && (o.aiTitle || o.title)) aiTitle = o.aiTitle || o.title;
    else if (o.type === 'summary' && o.summary) summary ||= o.summary;
    sessionId ||= o.sessionId; cwd ||= o.cwd;
    if ((o.type !== 'user' && o.type !== 'assistant') || !o.message) continue;
    if (o.timestamp) { first ||= o.timestamp; last = o.timestamp; }
    const blocks = normBlocks(o.message.content);
    if (!blocks.length) continue;

    if (o.type === 'assistant') {
      for (const b of blocks) if (b.type === 'tool_use') toolUses.set(b.id, b);
      const id = o.message.id;
      if (lastAssistant && id && lastAssistant.mid === id) { lastAssistant.blocks.push(...blocks); continue; }
      lastAssistant = { role: 'assistant', mid: id, time: o.timestamp, side: !!o.isSidechain, blocks };
      msgs.push(lastAssistant);
      continue;
    }
    // user entry: attach tool results to the call that produced them
    const rest = [];
    for (const b of blocks) {
      if (b.type === 'tool_result' && toolUses.has(b.id)) toolUses.get(b.id).result = b;
      else rest.push(b);
    }
    if (!rest.length) continue;
    lastAssistant = null;
    msgs.push({ role: 'user', time: o.timestamp, side: !!o.isSidechain, meta: !!o.isMeta, blocks: rest });
  }
  const firstUser = msgs.find(m => m.role === 'user' && !m.meta && m.blocks.some(b => b.type === 'text'));
  const firstText = firstUser?.blocks.find(b => b.type === 'text')?.text || '';
  return {
    sessionId, cwd, first, last, msgs,
    title: title || aiTitle || summary || firstText.slice(0, 80) || '(ไม่มีหัวข้อ)',
    count: msgs.filter(m => !m.meta && m.blocks.some(b => b.type === 'text')).length,
    text: msgs.filter(m => !m.meta).flatMap(m => m.blocks.filter(b => b.type === 'text').map(b => b.text)).join('\n'),
  };
}

// One entry of history/<machine>/index.json. `path` is repo-relative (or live/... for the local server).
export const INDEX_TEXT_LIMIT = 30000;
export function indexEntry(path, folder, parsed) {
  return {
    path, sessionId: parsed.sessionId, project: projectLabel(parsed.cwd, folder), cwd: parsed.cwd,
    title: parsed.title, first: parsed.first, last: parsed.last, count: parsed.count,
    text: parsed.text.slice(0, INDEX_TEXT_LIMIT),
  };
}

// Merge the per-machine indexes; the same session can exist on two machines (or live + synced).
export function mergeIndexes(indexes) {
  const byId = new Map();
  for (const ix of indexes) {
    for (const s of ix.sessions || []) {
      if (!s.count) continue;
      const item = { ...s, machine: ix.machine, live: !!ix.live };
      const id = s.sessionId || s.path;
      const prev = byId.get(id);
      if (!prev || (item.live && !prev.live) || (item.live === prev.live && String(item.last) > String(prev.last))) byId.set(id, item);
    }
  }
  return [...byId.values()].sort((a, b) => String(b.last || '').localeCompare(String(a.last || '')));
}
