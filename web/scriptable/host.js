// ─────────────────────────── Scriptable host ───────────────────────────
// Modes: Shortcuts "Run Script" (args.shortcutParameter) · Home-screen widget · App (full UI in a WebView).
// Data lives in iCloud Drive/Scriptable/m9rofi/ on the user's own account. No server.

const fm = (() => { try { return FileManager.iCloud(); } catch (e) { return FileManager.local(); } })();
const DIR = fm.joinPath(fm.documentsDirectory(), 'm9rofi');
if (!fm.fileExists(DIR)) fm.createDirectory(DIR, true);
const P = n => fm.joinPath(DIR, n);
const STATE = P('state.json'), QUEUE = P('queue.txt'), FIRED = P('fired.json');

async function read(path) {
  if (!fm.fileExists(path)) return null;
  try { if (!fm.isFileDownloaded(path)) await fm.downloadFileFromiCloud(path); } catch (e) {}
  return fm.readString(path);
}
async function loadState() {
  const base = E.newState();
  const t = await read(STATE);
  if (!t) return base;
  const d = JSON.parse(t);
  return { ...base, ...d, settings: { ...base.settings, ...d.settings } };
}
const sleep = ms => new Promise(r => Timer.schedule(ms, false, r));
const ingestText = (state, text) => E.ingest(state, E.parseInbox(text || '', state.templates), Date.now());

function normalizeParam(p) {
  let t = Array.isArray(p) ? p.join('\n') : String(p ?? '');
  t = t.trim();
  if (!t) return '';
  return t.includes('###|') ? t : '###|sms\n' + t;
}

// ── Shortcut mode: append to queue (only the app writes state.json), notify. ──
async function runShortcut() {
  const text = normalizeParam(args.shortcutParameter);
  if (!text) { Script.setShortcutOutput('فارغ'); return; }
  const q = (await read(QUEUE)) || '';
  fm.writeString(QUEUE, q + '\n' + text + '\n');

  const state = await loadState();
  ingestText(state, q);
  const fired = JSON.parse((await read(FIRED)) || '{}');
  Object.assign(state.fired, fired);
  const r = ingestText(state, text);
  const out = [];
  for (const id of r.added) {
    const t = state.txs.find(x => x.id === id);
    const e = E.effect(state, t);
    if (e.type === 'expense') {
      const today = E.summary(state, E.period('day', Date.now()), Date.now()).spending;
      await notify(`${E.sar(e.amount)} – ${t.merchant || E.catName(e.category)}`, `${E.catIcon(e.category)} ${E.catName(e.category)} · مصروف اليوم ${E.sar(today)}`);
      out.push('مصروف');
    } else out.push({ income: 'دخل', internal: 'تحويل داخلي', transferIn: 'تحويل وارد', refund: 'مسترد', pending: 'معلقة', unconfirmed: 'مراجعة', cash: 'سحب نقدي' }[e.type] || e.type);
  }
  for (const a of E.alerts(state, Date.now(), r.added)) {
    if (fired[a.id]) continue;
    fired[a.id] = 1;
    await notify(a.title, a.body);
  }
  fm.writeString(FIRED, JSON.stringify(fired));
  Script.setShortcutOutput(out.join('، ') || (r.dup ? 'مسجلة مسبقاً' : r.ignored ? 'ليست عملية مالية' : 'لم تُفهم'));
}

async function notify(title, body) {
  try { const n = new Notification(); n.title = title; n.body = body; n.threadIdentifier = 'm9rofi'; await n.schedule(); } catch (e) {}
}

// ── Widget mode: read-only (state + pending queue in memory). ──
async function runWidget() {
  const state = await loadState();
  ingestText(state, await read(QUEUE));
  const now = Date.now();
  const d = E.dashboard(state, now);
  const w = new ListWidget();
  w.backgroundColor = Color.dynamic(new Color('#ffffff'), new Color('#111111'));
  w.setPadding(12, 14, 12, 14);
  w.url = URLScheme.forRunningScript();
  const text = (s, size, color, bold) => {
    const t = w.addText(s); t.font = bold ? Font.boldSystemFont(size) : Font.systemFont(size);
    t.textColor = color || Color.dynamic(new Color('#111111'), new Color('#f2f2f7')); t.rightAlignText(); t.minimumScaleFactor = 0.6; t.lineLimit = 1; return t;
  };
  const muted = Color.dynamic(new Color('#6b7280'), new Color('#9ca3af'));
  const green = new Color('#1b873f');
  text('مصروفي', 12, green, true);
  w.addSpacer(4);
  text('اليوم', 11, muted);
  text(E.sar(d.today.spending), 20, null, true);
  w.addSpacer(4);
  text('هذا الشهر', 11, muted);
  text(E.sar(d.month.spending), config.widgetFamily === 'small' ? 15 : 18, null, true);
  if (config.widgetFamily !== 'small') {
    w.addSpacer(4);
    const top = d.month.byCategory[0];
    if (top) text(`أعلى تصنيف: ${E.catName(top.category)} ${E.sar(top.amount, false)}`, 11, muted);
    const b = E.budgetStatus(state, now)[0];
    if (b) text(`ميزانية ${E.catName(b.category)}: ${Math.round(b.ratio * 100)}%`, 11, b.ratio >= 0.9 ? new Color('#c62828') : muted);
  }
  if (d.reviewCount) { w.addSpacer(2); text(`⚠️ ${d.reviewCount} للمراجعة`, 11, new Color('#d97706')); }
  w.addSpacer();
  w.refreshAfterDate = new Date(now + 15 * 60e3);
  Script.setWidget(w);
}

const SRC_URL = 'https://pandasam0.github.io/m9rofi/scriptable.js';
const CACHE = P('app.js');

/** Download the latest app, bypassing caches. Returns { changed, build }. */
async function downloadUpdate() {
  const req = new Request(SRC_URL + '?t=' + Date.now());
  req.timeoutInterval = 15;
  req.headers = { 'Cache-Control': 'no-cache' };
  const code = await req.loadString();
  if (!code || !code.startsWith('// M9ROFI_APP')) throw new Error('bad download');
  const old = fm.fileExists(CACHE) ? fm.readString(CACHE) : '';
  if (code !== old) fm.writeString(CACHE, code);
  const m = /APP_BUILD = "([^"]+)"/.exec(code);
  return { changed: code !== old, build: m ? m[1] : '' };
}

/** Older loaders fetched without a cache-buster; patch the user's script once so updates arrive immediately. */
function patchLoader() {
  try {
    const path = fm.joinPath(fm.documentsDirectory(), Script.name() + '.js');
    if (!fm.fileExists(path)) return;
    const src = fm.readString(path);
    if (src.includes('github.io/m9rofi/scriptable.js') && src.includes('new Request(SRC)'))
      fm.writeString(path, src.replace('new Request(SRC)', 'new Request(SRC + "?t=" + Date.now())'));
  } catch (e) {}
}

/** One backup per day of state.json, last 7 kept, in the same iCloud folder. */
function dailyBackup() {
  try {
    if (!fm.fileExists(STATE)) return;
    const day = new Date().toISOString().slice(0, 10);
    const b = P(`backup-${day}.json`);
    if (!fm.fileExists(b)) fm.writeString(b, fm.readString(STATE));
    const olds = fm.listContents(DIR).filter(n => /^backup-\d{4}-\d{2}-\d{2}\.json$/.test(n)).sort();
    for (const n of olds.slice(0, Math.max(0, olds.length - 7))) fm.remove(P(n));
  } catch (e) {}
}

// ── App mode: full UI in a WebView; the page is the single writer of state.json. ──
async function runApp() {
  patchLoader();
  dailyBackup();
  const state = await loadState();
  const safe = s => JSON.stringify(s).replace(/</g, '\\u003c').replace(/\u2028/g, '\\u2028').replace(/\u2029/g, '\\u2029');
  const html = `<!DOCTYPE html><html lang="ar" dir="rtl"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover"><style>${CSS_SRC}</style></head>
<body>${BODY_SRC}<script>window.__M9HOST__ = { state: ${safe(state)}, build: ${safe(APP_BUILD)} };</script>
<script>${ENGINE_WRAPPED}\n${APP_SRC}</script></body></html>`;
  const wv = new WebView();
  await wv.loadHTML(html);

  async function flush() {
    const res = await wv.evaluateJavaScript(`(() => { const o = window.__M9OUT__ || null; window.__M9OUT__ = null; const r = window.__M9REQ__ || []; window.__M9REQ__ = []; return JSON.stringify({ o, r }); })()`, false);
    const { o, r } = JSON.parse(res);
    if (o) fm.writeString(STATE, o);
    for (const req of r) await handle(req);
  }
  async function drainQueue() {
    const q = (await read(QUEUE)) || '';
    if (!q.trim()) return;
    await wv.evaluateJavaScript(`window.__m9ingest(${safe(q)}).then(n => completion(n)).catch(e => completion(-1)); 0`, true);
    await flush();
    const cur = (await read(QUEUE)) || '';
    fm.writeString(QUEUE, cur.startsWith(q) ? cur.slice(q.length) : cur);
  }
  async function handle(req) {
    if (req.type === 'pick') {
      let text = null;
      try { const paths = await DocumentPicker.open(); if (paths && paths[0]) text = FileManager.local().readString(paths[0]); } catch (e) {}
      await wv.evaluateJavaScript(`window.__m9reply(${req.id}, ${safe(text)}); 0`, false);
    } else if (req.type === 'update') {
      let result;
      try { result = await downloadUpdate(); } catch (e) { result = { error: String(e) }; }
      await wv.evaluateJavaScript(`window.__m9reply(${req.id}, ${safe(result)}); 0`, false);
    } else if (req.type === 'share') {
      // Save the file via the iOS Files picker (CSV report or JSON backup).
      try { await DocumentPicker.exportString(req.content, req.name); } catch (e) {}
      await wv.evaluateJavaScript(`window.__m9reply(${req.id}, true); 0`, false);
    }
  }

  await drainQueue();
  let open = true;
  const shown = wv.present(true).then(() => { open = false; });
  while (open) {
    await sleep(1500);
    if (!open) break;
    try { await flush(); await drainQueue(); } catch (e) {}
  }
  try { await flush(); } catch (e) {}
  await shown;
}

if (args.shortcutParameter != null && args.shortcutParameter !== '') await runShortcut();
else if (config.runsInWidget) await runWidget();
else await runApp();
Script.complete();
