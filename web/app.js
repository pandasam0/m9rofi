import * as E from './engine.js';

// ───────────── Storage (IndexedDB, on this device only) ─────────────
const DB = 'm9rofi', STORE = 'kv';
const idb = () => new Promise((ok, bad) => {
  const r = indexedDB.open(DB, 1);
  r.onupgradeneeded = () => r.result.createObjectStore(STORE);
  r.onsuccess = () => ok(r.result); r.onerror = () => bad(r.error);
});
async function load() {
  const db = await idb();
  return new Promise(ok => { const q = db.transaction(STORE).objectStore(STORE).get('state'); q.onsuccess = () => ok(q.result || null); q.onerror = () => ok(null); });
}
async function save() {
  if (HOST) { window.__M9OUT__ = JSON.stringify(state); return; }
  const db = await idb();
  return new Promise(ok => { const t = db.transaction(STORE, 'readwrite'); t.objectStore(STORE).put(state, 'state'); t.oncomplete = ok; t.onerror = ok; });
}

let state = E.newState();
let notices = [];

// ───────────── Host bridge ─────────────
// When running inside the Scriptable app, the host injects window.__M9HOST__ and polls window.__M9OUT__ / __M9REQ__.
const HOST = window.__M9HOST__ || null;
let reqSeq = 0;
const pending = {};
function hostRequest(req) {
  return new Promise(ok => { const id = ++reqSeq; pending[id] = ok; (window.__M9REQ__ ||= []).push({ id, ...req }); });
}
window.__m9reply = (id, value) => { const f = pending[id]; delete pending[id]; if (f) f(value); };
window.__m9ingest = async text => {
  const items = E.parseInbox(text, state.templates);
  if (!items.length) return 0;
  const r = E.record(state, items, now());
  await commit(r);
  return r.added.length;
};

// ───────────── Helpers ─────────────
const $ = s => document.querySelector(s);
const h = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const money = (v, d = true) => `<span class="num">${E.sar(v, d)}</span>`;
const pct = r => `${Math.round(r * 100)}%`;
const now = () => Date.now();
const acct = id => state.accounts.find(a => a.id === id);
const uid = () => (crypto.randomUUID ? crypto.randomUUID() : 'id-' + Math.random().toString(36).slice(2));
const EFFECT_AR = { expense: 'مصروف', refund: 'مسترد (يُخصم من المصروفات)', income: 'دخل', transferIn: 'تحويل وارد (ليس دخلاً)',
  cash: 'سحب نقدي (ليس مصروفاً)', transferOut: 'تحويل لشخص خارج العائلة (غير محتسب). غيّر التصنيف لاحتسابه', internal: 'تحويل داخلي (غير محتسب)', pending: 'معلقة (غير محتسبة)', unconfirmed: 'قيد المراجعة (غير محتسبة)', excluded: 'مستبعدة' };
const BADGE = { transferOut: 'تحويل غير محتسب', internal: 'تحويل داخلي', pending: 'معلقة', unconfirmed: 'مراجعة', excluded: 'مستبعدة', cash: 'سحب نقدي', transferIn: 'تحويل وارد', refund: 'مسترد' };
const STATUS_AR = { pending: 'معلقة', completed: 'مكتملة', reversed: 'ملغاة', refunded: 'مستردة' };
const SRC_AR = { sms: 'رسالة بنك', wallet: 'Apple Pay', statement: 'كشف حساب', manual: 'يدوي', email: 'بريد' };

async function commit(report) {
  if (report) {
    const fresh = E.alerts(state, now(), report.added);
    for (const a of fresh) state.fired[a.id] = 1;
    notices = [...fresh, ...notices].slice(0, 20);
  }
  await save();
  render();
}

function sheet(html) { $('#sheet-body').innerHTML = html; $('#sheet').hidden = false; }
function closeSheet() { $('#sheet').hidden = true; $('#sheet-body').innerHTML = ''; }
$('#sheet').addEventListener('click', e => { if (e.target.id === 'sheet') closeSheet(); });

async function askYesNo(msg) {
  if (!HOST) return confirm(msg);
  return new Promise(ok => {
    sheet(`<h3>${h(msg)}</h3><button class="wide danger" id="yes">نعم</button><button class="wide ghost" id="no">إلغاء</button>`);
    $('#yes').onclick = () => { closeSheet(); ok(true); };
    $('#no').onclick = () => { closeSheet(); ok(false); };
  });
}
function tell(msg) { if (HOST) { sheet(`<p>${h(msg)}</p><button class="wide" id="ok">تم</button>`); $('#ok').onclick = closeSheet; } else alert(msg); }

function pickFile(accept) {
  if (HOST) return hostRequest({ type: 'pick' }).then(text => (text == null ? null : { text: async () => text }));
  return new Promise(ok => {
    const f = $('#file'); f.value = ''; f.accept = accept;
    f.onchange = () => ok(f.files[0] || null); f.click();
  });
}

function reportText(r) {
  return `أضيفت ${r.added.length} · دُمجت ${r.merged.length} · مسجلة مسبقاً ${r.dup} · للمراجعة ${r.review.length} · تحويلات داخلية ${r.internal} · متجاهلة ${r.ignored}`;
}

function txRow(t) {
  const e = E.effect(state, t);
  const amt = t.base ?? t.amount;
  const color = ['income', 'refund', 'transferIn'].includes(e.type) ? 'green' : ['pending', 'unconfirmed'].includes(e.type) ? 'orange' : ['internal', 'excluded', 'cash'].includes(e.type) ? 'muted' : '';
  return `<div class="row" data-tx="${h(t.id)}">
    <div class="ic">${E.catIcon(t.category)}</div>
    <div class="mid"><div>${h(t.merchant || t.counterparty || E.catName(t.category))}</div>
      <div class="muted">${h(E.catName(t.category))} · <span class="num">${E.fmtDate(t.ts, t.hasTime)}</span></div></div>
    <div class="end"><div class="num ${color} ${e.type === 'excluded' ? 'strike' : ''}">${t.direction === 'debit' ? '−' : '+'}${E.sar(amt)}</div>
      ${t.currency !== 'SAR' ? `<div class="muted num">${(t.amount / 100).toFixed(2)} ${h(t.currency)}</div>` : ''}
      ${BADGE[e.type] ? `<span class="badge">${BADGE[e.type]}</span>` : ''}</div></div>`;
}

function bindRows(root = document) {
  root.querySelectorAll('[data-tx]').forEach(el => el.onclick = () => txDetail(el.dataset.tx));
}

// ───────────── Screens ─────────────
const routes = { home, txs, ask, reports, more, review, accounts, budgets, subs, importView, settings, guide, alertsView };

function render() {
  const [route] = (location.hash.slice(1) || 'home').split('/');
  const fn = routes[route] || home;
  document.querySelectorAll('#tabs a').forEach(a => a.classList.toggle('on', a.dataset.tab === route));
  $('#actions').innerHTML = '';
  $('#view').innerHTML = '';
  fn();
  bindRows($('#view'));
  window.scrollTo(0, 0);
}
window.addEventListener('hashchange', () => { closeSheet(); render(); });

function setTitle(t, actions = '') { $('#title').textContent = t; $('#actions').innerHTML = actions; }

// Home
function home() {
  setTitle('مصروفي', HOST ? `<span class="badge">تلقائي ✓</span><button class="small ghost" id="add">＋</button>` : `<button class="small" id="sync">⟳ تحديث</button><button class="small ghost" id="add">＋</button>`);
  const d = E.dashboard(state, now());
  const budgets = E.budgetStatus(state, now());
  const rec = E.recurring(state, now());
  const m = d.month;
  let html = '';
  if (!state.accounts.length) html += `<a class="banner" href="#guide">👋 ابدأ من هنا: خطوات الإعداد</a>`;
  if (d.reviewCount) html += `<a class="banner" href="#review">⚠️ ${d.reviewCount} عمليات تحتاج مراجعتك</a>`;
  if (notices.length) html += `<a class="banner" href="#alertsView">🔔 ${notices.length} تنبيهات جديدة</a>`;
  html += `<div class="card hero"><div class="muted">مصروفات هذا الشهر</div><div class="big">${money(m.spending)}</div>
    ${d.change != null ? `<div class="${d.change > 0 ? 'red' : 'green'}">${d.change > 0 ? '▲' : '▼'} ${pct(Math.abs(d.change))} مقارنة بنفس الفترة من الشهر الماضي</div>` : ''}
    ${m.pending || m.unconfirmed ? `<div class="muted">غير محتسب: معلقة ${E.sar(m.pending)} · قيد المراجعة ${E.sar(m.unconfirmed)}</div>` : ''}</div>
  <div class="grid">
    <div class="stat"><small>اليوم</small><b>${money(d.today.spending)}</b></div>
    <div class="stat"><small>هذا الأسبوع</small><b>${money(d.week.spending)}</b></div>
    <div class="stat"><small>هذه السنة</small><b>${money(d.year.spending)}</b></div>
    <div class="stat"><small>الدخل (الشهر)</small><b class="green">${money(m.income)}</b></div>
    <div class="stat"><small>صافي التدفق النقدي</small><b class="${m.net >= 0 ? 'green' : 'red'}">${money(m.net)}</b></div>
    <div class="stat"><small>إجمالي الأرصدة</small><b>${money(d.total)}</b></div>
    <div class="stat"><small>عدد العمليات (الشهر)</small><b>${m.count}</b></div>
    <div class="stat"><small>متوسط الإنفاق اليومي</small><b>${money(m.dailyAvg)}</b></div>
    <div class="stat"><small>أعلى تصنيف</small><b>${m.byCategory[0] ? E.catIcon(m.byCategory[0].category) + ' ' + E.catName(m.byCategory[0].category) : '—'}</b></div>
    <div class="stat"><small>الشهر الماضي (نفس الفترة)</small><b>${money(d.prevToDate.spending)}</b></div>
  </div>`;
  if (m.byCategory.length) {
    const max = Math.max(...m.byCategory.map(c => c.amount));
    html += `<div class="card"><h3>المصروفات حسب التصنيف</h3>${m.byCategory.map(c => `
      <div style="margin:8px 0"><div style="display:flex;justify-content:space-between"><span>${E.catIcon(c.category)} ${E.catName(c.category)}</span>${money(c.amount)}</div>
      <div class="bar"><i style="width:${Math.max(2, c.amount / max * 100)}%"></i></div></div>`).join('')}</div>`;
  }
  if (budgets.length) html += `<div class="card"><h3>الميزانيات</h3>${budgets.slice(0, 4).map(budgetRow).join('')}<a href="#budgets" class="muted">كل الميزانيات ←</a></div>`;
  if (rec[0]) html += `<div class="card"><h3>الخصم المتكرر القادم</h3><div class="row"><div class="mid"><div>${h(rec[0].name)}</div><div class="muted">${E.fmtDate(rec[0].next, false)}</div></div>${money(rec[0].expected)}</div><a href="#subs" class="muted">كل الاشتراكات ←</a></div>`;
  html += `<div class="card"><h3>الحسابات</h3>${d.balances.map(b => `<div class="row"><div class="mid"><div>${h(b.account.name)}</div>${b.latest ? `<div class="muted">آخر تحديث ${E.fmtDate(b.latest.ts)}</div>` : ''}</div>${b.latest ? money(b.latest.balance) : '<span class="muted">—</span>'}</div>`).join('') || '<a href="#accounts">أضف حساباتك ←</a>'}</div>`;
  const recent = [...state.txs].sort((a, b) => b.ts - a.ts).slice(0, 5);
  if (recent.length) html += `<div class="card"><h3>آخر العمليات</h3>${recent.map(txRow).join('')}</div>`;
  $('#view').innerHTML = html;
  if ($('#sync')) $('#sync').onclick = syncInbox;
  $('#add').onclick = addTx;
}

function budgetRow(b) {
  const color = b.ratio >= 1 ? 'var(--red)' : b.ratio >= 0.9 ? 'var(--orange)' : b.ratio >= 0.75 ? '#eab308' : 'var(--green)';
  return `<div style="margin:10px 0" data-budget="${b.category}"><div style="display:flex;justify-content:space-between"><span>${E.catIcon(b.category)} ${E.catName(b.category)}</span>
    <span class="muted num">${E.sar(b.spent, false)} / ${E.sar(b.limit, false)}</span></div>
    <div class="bar"><i style="width:${Math.min(100, b.ratio * 100)}%;background:${color}"></i></div>
    <div class="muted ${b.remaining < 0 ? 'red' : ''}">${b.remaining >= 0 ? 'المتبقي ' + E.sar(b.remaining) : 'تجاوزت بـ ' + E.sar(-b.remaining)}</div></div>`;
}

async function syncInbox() {
  const f = await pickFile('.txt,text/plain');
  if (!f) return;
  const items = E.parseInbox(await f.text(), state.templates);
  const r = E.record(state, items, now());
  await commit(r);
  sheet(`<h3>تم التحديث</h3><p>${reportText(r)}</p><p class="muted">قرأت ${items.length} رسالة. الرسائل القديمة المسجلة مسبقاً لا تتكرر.</p><button class="wide" id="ok">تم</button>`);
  $('#ok').onclick = closeSheet;
}

// Transactions
function txs() {
  const [, filter] = location.hash.split('/');
  setTitle('العمليات', `<button class="small ghost" id="add">＋</button>`);
  const reviewCount = state.txs.filter(t => t.review.length).length;
  let html = reviewCount ? `<a class="banner" href="#review">⚠️ قائمة المراجعة (${reviewCount})</a>` : '';
  html += `<input id="q" placeholder="بحث…" value="${h(decodeURIComponent(filter || ''))}">
    <select id="cat"><option value="">كل التصنيفات</option>${Object.keys(E.CATEGORIES).map(c => `<option value="${c}">${E.catIcon(c)} ${E.catName(c)}</option>`).join('')}</select><div id="list"></div>`;
  $('#view').innerHTML = html;
  const draw = () => {
    const q = $('#q').value.trim().toLowerCase(), c = $('#cat').value;
    const list = state.txs.filter(t => (!c || t.category === c) && (!q || `${t.merchant || ''} ${t.counterparty || ''} ${t.note || ''} ${E.catName(t.category)} ${t.amount / 100}`.toLowerCase().includes(q)))
      .sort((a, b) => b.ts - a.ts);
    const days = {};
    for (const t of list) (days[E.fmtDate(t.ts, false)] ??= []).push(t);
    $('#list').innerHTML = Object.entries(days).slice(0, 120).map(([d, ts]) => {
      const spent = ts.reduce((s, t) => { const e = E.effect(state, t); return s + (e.type === 'expense' ? e.amount : e.type === 'refund' ? -e.amount : 0); }, 0);
      return `<div class="card"><h3 style="display:flex;justify-content:space-between"><span>${d}</span>${money(spent)}</h3>${ts.map(txRow).join('')}</div>`;
    }).join('') || '<p class="muted">لا توجد عمليات. اضغط «تحديث» في الرئيسية بعد إعداد الاختصارات، أو استورد كشف حساب من «المزيد».</p>';
    bindRows($('#list'));
  };
  $('#q').oninput = draw; $('#cat').onchange = draw; draw();
  $('#add').onclick = addTx;
}

function txDetail(id) {
  const t = state.txs.find(x => x.id === id); if (!t) return;
  const e = E.effect(state, t);
  const line = (k, v) => v ? `<div class="row"><div class="mid muted">${k}</div><div>${v}</div></div>` : '';
  sheet(`<h3>${h(t.merchant || t.counterparty || E.catName(t.category))}</h3>
    <div class="card">
      ${line('المبلغ', money(t.base ?? t.amount))}
      ${t.currency !== 'SAR' ? line('المبلغ الأصلي', `<span class="num">${(t.amount / 100).toFixed(2)} ${h(t.currency)}</span>`) : ''}
      ${line('النوع', t.direction === 'debit' ? 'خصم' : 'إيداع')}
      ${line('الحالة', STATUS_AR[t.status])}
      ${line('يُحتسب كـ', EFFECT_AR[e.type])}
      ${line('التاريخ', E.fmtDate(t.ts, t.hasTime))}
      ${line('الحساب', h(acct(t.accountId)?.name))}
      ${line('البطاقة', t.card ? '•••• ' + h(t.card) : '')}
      ${line('المصدر', t.sources.map(s => SRC_AR[s.type] || s.type).join(' + '))}
    </div>
    ${t.review.length ? `<div class="banner">${t.review.map(r => E.REVIEW_TEXT[r]).join('<br>')}</div><button class="wide" id="fix">معالجة</button>` : ''}
    <label>التصنيف</label><select id="c">${Object.keys(E.CATEGORIES).map(c => `<option value="${c}" ${c === t.category ? 'selected' : ''}>${E.catIcon(c)} ${E.catName(c)}</option>`).join('')}</select>
    <label><input type="checkbox" id="learn" checked style="width:auto"> طبّق على كل عمليات هذه الجهة مستقبلاً</label>
    ${t.note ? `<p class="muted">${h(t.note)}</p>` : ''}
    <button class="wide" id="save">حفظ</button>
    <button class="wide ghost" id="ex">${t.excluded ? 'تضمين في الإجماليات' : 'استبعاد من الإجماليات'}</button>
    ${!t.internal && ['transferOut', 'transferIn'].includes(t.kind) ? '<button class="wide ghost" id="int">تحويل بين حساباتي</button>' : ''}
    <button class="wide danger" id="del">حذف</button>`);
  $('#save').onclick = async () => { E.userOp(state, id, { op: 'cat', category: $('#c').value, learn: $('#learn').checked }); closeSheet(); await commit(); };
  $('#ex').onclick = async () => { E.userOp(state, id, { op: 'exclude', value: !t.excluded }); closeSheet(); await commit(); };
  if ($('#int')) $('#int').onclick = async () => { E.userOp(state, id, { op: 'resolve', action: 'internal' }); closeSheet(); await commit(); };
  $('#del').onclick = async () => { if (await askYesNo('حذف العملية؟')) { E.userOp(state, id, { op: 'delete' }); closeSheet(); await commit(); } };
  if ($('#fix')) $('#fix').onclick = () => reviewDetail(id);
}

function addTx() {
  sheet(`<h3>إضافة عملية</h3>
    <div class="seg"><button class="on" data-d="debit">مصروف</button><button data-d="credit">دخل</button></div>
    <label>المبلغ (ريال)</label><input id="amt" inputmode="decimal" placeholder="0.00">
    <label>الجهة / الوصف</label><input id="mer">
    <label>التصنيف</label><select id="c"><option value="">تلقائي</option>${Object.keys(E.CATEGORIES).map(c => `<option value="${c}">${E.catIcon(c)} ${E.catName(c)}</option>`).join('')}</select>
    <label>الحساب</label><select id="ac"><option value="">بدون</option>${state.accounts.filter(a => !a.archived).map(a => `<option value="${a.id}">${h(a.name)}</option>`).join('')}</select>
    <label>التاريخ</label><input id="dt" type="datetime-local">
    <button class="wide" id="save">حفظ</button>`);
  let dir = 'debit';
  document.querySelectorAll('.seg button').forEach(b => b.onclick = () => { dir = b.dataset.d; document.querySelectorAll('.seg button').forEach(x => x.classList.toggle('on', x === b)); });
  const d = new Date(); d.setMinutes(d.getMinutes() - d.getTimezoneOffset()); $('#dt').value = d.toISOString().slice(0, 16);
  $('#save').onclick = async () => {
    const amount = E.parseHalalas($('#amt').value);
    if (!amount || amount <= 0) { $('#amt').focus(); return; }
    const cat = $('#c').value || null;
    const rec = { source: 'manual', id: 'manual:' + uid(), amount, currency: 'SAR', direction: dir,
      kind: dir === 'debit' ? 'purchase' : (cat === 'salary' ? 'income' : 'transferIn'), status: 'completed',
      ts: new Date($('#dt').value).getTime() || now(), hasTime: true, merchant: $('#mer').value.trim() || null,
      accountId: $('#ac').value || null, category: cat };
    const r = E.record(state, [rec], now());
    closeSheet(); await commit(r);
  };
}

// Review
function review() {
  setTitle('المراجعة');
  const q = state.txs.filter(t => t.review.length).sort((a, b) => b.ts - a.ts);
  $('#view').innerHTML = `<p class="muted">هذه العمليات غير محتسبة في الإجماليات حتى تؤكدها.</p>` +
    (q.map(t => `<div class="card">${txRow(t)}<div class="orange">${t.review.map(r => E.REVIEW_TEXT[r]).join(' · ')}</div>
      <button class="small wide" data-rv="${h(t.id)}">معالجة</button></div>`).join('') || '<p class="muted">لا شيء للمراجعة ✓</p>');
  document.querySelectorAll('[data-rv]').forEach(b => b.onclick = () => reviewDetail(b.dataset.rv));
}

function reviewDetail(id) {
  const t = state.txs.find(x => x.id === id); if (!t) return;
  const other = t.link && state.txs.find(x => x.id === t.link);
  let html = `<h3>معالجة</h3><div class="card">${txRow(t)}</div><div class="banner">${t.review.map(r => E.REVIEW_TEXT[r]).join('<br>')}</div>`;
  if (t.review.includes('possibleDuplicate') && other) html += `<div class="card"><h3>قد تكون نفس هذه العملية:</h3>${txRow(other)}</div>
    <button class="wide" data-a="merge">نفس العملية — ادمجها</button><button class="wide ghost" data-a="confirm">عملية مختلفة — احتسبها</button>`;
  if (t.review.includes('possibleInternal')) html += `<button class="wide" data-a="internal">نعم، تحويل لحسابي (ليس مصروفاً)</button><button class="wide ghost" data-a="confirm">لا، دفعة لشخص آخر</button>`;
  if (t.review.includes('cardPaymentUntracked')) html += `<p class="muted">إذا كانت مشتريات البطاقة الائتمانية مسجلة في التطبيق فهذا السداد ليس مصروفاً. إذا لم تكن مسجلة، فالسداد نفسه هو المصروف.</p>
    <button class="wide" data-a="internal">مشترياتها مسجلة — ليس مصروفاً</button><button class="wide ghost" data-a="cardExpense">احتسب السداد كمصروف</button>`;
  if (t.review.includes('unmatchedReversal')) html += `<p class="muted">لم أجد العملية الأصلية. إبقاؤها مستبعدة آمن لأن الإلغاء والأصل يلغي أحدهما الآخر.</p><button class="wide" data-a="keepExcluded">إبقاؤها مستبعدة</button>`;
  if (['missingAmount', 'missingBaseAmount', 'unknownDirection', 'lowConfidence'].some(r => t.review.includes(r))) html += `
    ${t.review.includes('missingAmount') ? '<label>المبلغ</label><input id="amt" inputmode="decimal">' : ''}
    ${t.currency !== 'SAR' ? '<label>المبلغ المخصوم بالريال (من كشف البنك)</label><input id="base" inputmode="decimal">' : ''}
    <label>الاتجاه</label><select id="dir"><option value="debit" ${t.direction === 'debit' ? 'selected' : ''}>خصم (خروج)</option><option value="credit" ${t.direction === 'credit' ? 'selected' : ''}>إيداع (دخول)</option></select>
    <button class="wide" data-a="confirm">تأكيد</button>`;
  html += `<button class="wide danger" data-a="delete">ليست عملية حقيقية — حذف</button>`;
  sheet(html);
  document.querySelectorAll('#sheet [data-a]').forEach(b => b.onclick = async () => {
    const data = {};
    if ($('#amt')) data.amount = E.parseHalalas($('#amt').value);
    if ($('#base')) data.base = E.parseHalalas($('#base').value);
    if ($('#dir')) data.direction = $('#dir').value;
    E.userOp(state, id, { op: 'resolve', action: b.dataset.a, data });
    closeSheet(); await commit();
  });
}

// Assistant
let chat = [];
const EXAMPLES = ['كم صرفت اليوم؟', 'كم صرفت على القهوة هذا الشهر؟', 'كم صرفت في المطاعم؟', 'كم دفعت على الاشتراكات؟', 'ما أكثر شيء استنزف أموالي؟',
  'كم صرفت في آخر 7 أيام؟', 'كم صرفت على السفر خلال السنة؟', 'أين يمكنني تقليل مصاريفي؟', 'كم يتبقى لي من راتبي؟', 'كم يمكنني توفيره شهرياً؟'];
function ask() {
  setTitle('المساعد');
  $('#view').innerHTML = `<p class="muted">الإجابات محسوبة من عملياتك المسجلة فقط.</p>
    ${chat.length ? '' : `<div class="chips">${EXAMPLES.map(e => `<button>${e}</button>`).join('')}</div>`}
    <div id="chat">${chat.map(m => `<div class="msg ${m.me ? 'me' : 'bot'}">${h(m.text)}${m.notes?.length ? `<div class="orange" style="font-size:13px;margin-top:6px">${m.notes.map(h).join('<br>')}</div>` : ''}</div>`).join('')}</div>
    <div style="height:70px"></div>
    <div class="askbar"><input id="qq" placeholder="اسأل عن مصاريفك…"><button id="go">↑</button></div>`;
  const go = q => { q = q.trim(); if (!q) return; const a = E.answer(state, q, now()); chat.push({ me: true, text: q }, { text: a.text, notes: a.notes }); ask(); window.scrollTo(0, document.body.scrollHeight); };
  document.querySelectorAll('.chips button').forEach(b => b.onclick = () => go(b.textContent));
  $('#go').onclick = () => go($('#qq').value);
  $('#qq').onkeydown = e => { if (e.key === 'Enter') go($('#qq').value); };
}

// Reports
let rp = { kind: 'month', anchor: Date.now() };
function reports() {
  setTitle('التقارير', `<button class="small ghost" id="csv">Excel</button><button class="small ghost" id="pdf">PDF</button>`);
  const iv = E.period(rp.kind, rp.anchor);
  const s = E.summary(state, iv, now());
  const rec = E.recurring(state, now());
  const keys = new Set(rec.map(r => r.key));
  let fixed = 0, variable = 0;
  for (const t of state.txs) if (t.ts >= iv[0] && t.ts < iv[1]) { const e = E.effect(state, t); if (e.type === 'expense') (keys.has(t.mkey) ? fixed += e.amount : variable += e.amount); }
  const series = E.monthlySeries(state, 12, now());
  const max = Math.max(1, ...series.map(m => Math.max(m.spending, m.income)));
  const kinds = { day: 'يوم', week: 'أسبوع', month: 'شهر', year: 'سنة' };
  $('#view').innerHTML = `<div class="seg noprint">${Object.entries(kinds).map(([k, v]) => `<button data-k="${k}" class="${rp.kind === k ? 'on' : ''}">${v}</button>`).join('')}</div>
    <div style="display:flex;justify-content:space-between;align-items:center" class="noprint"><button class="small ghost" id="prev">→</button>
      <b>${E.fmtDate(iv[0], false)} – ${E.fmtDate(iv[1] - 1, false)}</b><button class="small ghost" id="next">←</button></div>
    <div class="grid" style="margin-top:10px">
      <div class="stat"><small>المصروفات</small><b>${money(s.spending)}</b></div>
      <div class="stat"><small>الدخل</small><b class="green">${money(s.income)}</b></div>
      <div class="stat"><small>صافي التدفق</small><b class="${s.net >= 0 ? 'green' : 'red'}">${money(s.net)}</b></div>
      <div class="stat"><small>المستردات</small><b>${money(s.refunds)}</b></div>
      <div class="stat"><small>مصروفات ثابتة</small><b>${money(fixed)}</b></div>
      <div class="stat"><small>مصروفات متغيرة</small><b>${money(variable)}</b></div>
      <div class="stat"><small>تحويلات واردة</small><b>${money(s.transfersIn)}</b></div>
      <div class="stat"><small>تحويلات صادرة غير محتسبة</small><b>${money(s.transfersOut)}</b></div>
      <div class="stat"><small>سحب نقدي</small><b>${money(s.cash)}</b></div>
    </div>
    <div class="card"><h3>توزيع المصروفات</h3>${s.byCategory.filter(c => c.amount > 0).map(c => `
      <div style="margin:8px 0"><div style="display:flex;justify-content:space-between"><span>${E.catIcon(c.category)} ${E.catName(c.category)} <span class="muted">(${c.count})</span></span>${money(c.amount)}</div>
      <div class="bar"><i style="width:${Math.max(2, c.amount / Math.max(1, s.spending) * 100)}%"></i></div></div>`).join('') || '<p class="muted">لا توجد مصروفات</p>'}</div>
    <div class="card"><h3>الدخل مقابل المصروفات (12 شهراً)</h3>
      <div class="legend muted"><span style="background:var(--red)"></span>مصروفات &nbsp; <span style="background:var(--green)"></span>دخل</div>
      <div class="cols">${series.map(m => `<div><div class="pair" style="display:flex;height:100%;align-items:flex-end;width:100%">
        <i style="height:${m.spending / max * 100}%;background:var(--red)"></i><i style="height:${m.income / max * 100}%;background:var(--green)"></i></div>
        <small>${E.riyadhParts(m.start).m}</small></div>`).join('')}</div></div>
    <div class="card"><h3>أكثر الجهات إنفاقاً</h3>${s.byMerchant.slice(0, 10).map(m => `<div class="row"><div class="mid">${h(m.name)} <span class="muted">(${m.count})</span></div>${money(m.amount)}</div>`).join('') || '<p class="muted">—</p>'}</div>`;
  document.querySelectorAll('.seg button').forEach(b => b.onclick = () => { rp.kind = b.dataset.k; reports(); });
  const shift = n => { const [a, b] = E.period(rp.kind, rp.anchor); rp.anchor = n < 0 ? a - 1 : b + 1; reports(); };
  $('#prev').onclick = () => shift(-1); $('#next').onclick = () => shift(1);
  $('#csv').onclick = () => download(`m9rofi-${E.fmtDate(iv[0], false)}.csv`, E.exportCSV(state, iv), 'text/csv;charset=utf-8');
  if (HOST) $('#pdf').remove(); else $('#pdf').onclick = () => window.print();
}

function download(name, content, type) {
  if (HOST) { hostRequest({ type: 'share', name, content }); return; }
  const url = URL.createObjectURL(new Blob([content], { type }));
  const a = document.createElement('a'); a.href = url; a.download = name; a.click();
  setTimeout(() => URL.revokeObjectURL(url), 5000);
}

// More
function more() {
  setTitle('المزيد');
  const links = [['guide', '📖', 'خطوات الإعداد'], ['accounts', '🏦', 'الحسابات'], ['budgets', '🎯', 'الميزانيات'], ['subs', '🔁', 'الاشتراكات'],
    ['review', '⚠️', 'قائمة المراجعة'], ['importView', '📥', 'استيراد كشف أو رسائل'], ['alertsView', '🔔', 'التنبيهات'], ['settings', '🔒', 'الإعدادات والخصوصية']];
  $('#view').innerHTML = `<div class="card">${links.map(([r, i, t]) => `<a href="#${r}" class="row" style="color:inherit;text-decoration:none"><div class="ic">${i}</div><div class="mid">${t}</div><span class="muted">‹</span></a>`).join('')}</div>`;
}

function alertsView() {
  setTitle('التنبيهات', `<button class="small ghost" id="clr">مسح</button>`);
  $('#view').innerHTML = notices.map(n => `<div class="card"><b>${h(n.title)}</b><div>${h(n.body)}</div></div>`).join('') || '<p class="muted">لا توجد تنبيهات جديدة.</p>';
  $('#clr').onclick = () => { notices = []; render(); };
}

function accounts() {
  setTitle('الحسابات', `<button class="small" id="add">＋ حساب</button>`);
  $('#view').innerHTML = `<p class="muted">آخر 4 أرقام فقط تكفي لربط الرسائل وApple Pay والكشوف بالحساب الصحيح، ولكشف التحويلات بين حساباتك. لا تكتب رقم البطاقة كاملاً أبداً.</p>` +
    `<div class="card">${state.accounts.filter(a => !a.archived).map(a => { const b = E.latestBalance(state, a.id);
      return `<div class="row" data-acc="${a.id}"><div class="mid"><div>${h(a.name)}</div><div class="muted">بطاقات: ${a.cards.join('، ') || '—'} · حساب: ${a.numbers.join('، ') || '—'}</div></div>${b ? money(b.balance) : ''}</div>`; }).join('') || '<p class="muted">لا توجد حسابات</p>'}</div>`;
  document.querySelectorAll('[data-acc]').forEach(el => el.onclick = () => editAccount(acct(el.dataset.acc)));
  $('#add').onclick = () => editAccount(null);
}

const PRESETS = { snb: ['البنك الأهلي', 'current', 'SNB'], barq: ['Barq', 'wallet', 'Barq'], d360: ['D360', 'current', 'D360'], credit: ['بطاقة ائتمانية', 'creditCard', ''], cash: ['نقد', 'cash', ''], other: ['', 'current', ''] };
function editAccount(a) {
  const isNew = !a;
  a = a || { id: uid(), name: '', institution: 'other', type: 'current', cards: [], numbers: [], walletNames: [], senders: [], tracked: true, lowBalance: null };
  const bal = E.latestBalance(state, a.id);
  sheet(`<h3>${isNew ? 'حساب جديد' : h(a.name)}</h3>
    ${isNew ? `<div class="chips">${Object.entries(PRESETS).map(([k, p]) => `<button data-p="${k}">${p[0] || 'أخرى'}</button>`).join('')}</div>` : ''}
    <label>الاسم</label><input id="n" value="${h(a.name)}">
    <label>النوع</label><select id="t">${[['current', 'حساب جاري'], ['savings', 'ادخار'], ['wallet', 'محفظة'], ['creditCard', 'بطاقة ائتمانية'], ['cash', 'نقد']].map(([v, l]) => `<option value="${v}" ${a.type === v ? 'selected' : ''}>${l}</option>`).join('')}</select>
    <label>آخر 4 أرقام لكل بطاقة (افصل بفاصلة)</label><input id="c" inputmode="numeric" value="${h(a.cards.join(', '))}">
    <label>آخر 4 أرقام للحساب / الآيبان</label><input id="no" inputmode="numeric" value="${h(a.numbers.join(', '))}">
    <label>اسم البطاقة في Apple Wallet</label><input id="w" value="${h(a.walletNames.join(', '))}">
    <label>اسم مرسل رسائل البنك</label><input id="s" value="${h(a.senders.join(', '))}">
    <label>الرصيد الحالي (اختياري)</label><input id="b" inputmode="decimal" value="${bal ? (bal.balance / 100).toFixed(2) : ''}">
    <label>نبهني إذا نزل الرصيد عن</label><input id="lb" inputmode="decimal" value="${a.lowBalance ? a.lowBalance / 100 : ''}">
    <button class="wide" id="save">حفظ</button>${isNew ? '' : '<button class="wide danger" id="arch">حذف الحساب</button>'}`);
  let inst = a.institution;
  document.querySelectorAll('[data-p]').forEach(b => b.onclick = () => { const p = PRESETS[b.dataset.p]; inst = ['snb', 'barq', 'd360'].includes(b.dataset.p) ? b.dataset.p : b.dataset.p === 'cash' ? 'cash' : 'other';
    $('#n').value = p[0]; $('#t').value = p[1]; $('#s').value = p[2]; });
  const list = v => v.split(/[,،]/).map(x => x.trim()).filter(Boolean);
  const last4 = v => list(E.normDigits(v)).map(x => x.replace(/\D/g, '').slice(-4)).filter(x => x.length === 4);
  $('#save').onclick = async () => {
    if (!$('#n').value.trim()) { $('#n').focus(); return; }
    Object.assign(a, { name: $('#n').value.trim(), type: $('#t').value, institution: inst, cards: last4($('#c').value), numbers: last4($('#no').value),
      walletNames: list($('#w').value), senders: list($('#s').value), lowBalance: E.parseHalalas($('#lb').value) || null });
    if (isNew) state.accounts.push(a);
    for (const t of state.txs) if (!t.accountId) {
      if (t.card && a.cards.includes(t.card)) t.accountId = a.id; else if (t.acct && a.numbers.includes(t.acct)) t.accountId = a.id;
    }
    const nb = E.parseHalalas($('#b').value);
    if (nb != null && (!bal || nb !== bal.balance)) state.balances.push({ accountId: a.id, balance: nb, ts: now(), source: 'manual' });
    closeSheet(); await commit();
  };
  if ($('#arch')) $('#arch').onclick = async () => { if (await askYesNo('حذف الحساب؟ العمليات المسجلة تبقى.')) { a.archived = true; closeSheet(); await commit(); } };
}

function budgets() {
  setTitle('الميزانيات');
  const st = E.budgetStatus(state, now());
  const sug = E.suggestBudgets(state, now());
  const missing = Object.entries(sug).filter(([c]) => !state.budgets[c]);
  $('#view').innerHTML = `<div class="card"><h3>هذا الشهر</h3>${st.map(budgetRow).join('') || '<p class="muted">لا توجد ميزانيات</p>'}</div>
    ${missing.length ? `<div class="card"><h3>مقترحة من إنفاقك (وسيط آخر 3 أشهر)</h3>${missing.map(([c, v]) => `<div class="row"><div class="mid">${E.catIcon(c)} ${E.catName(c)}</div>${money(v, false)}<button class="small" data-add="${c}" data-v="${v}">إضافة</button></div>`).join('')}</div>` : ''}
    <div class="card"><h3>إضافة / تعديل</h3><select id="c">${E.EXPENSE_CATEGORIES.map(c => `<option value="${c}">${E.catIcon(c)} ${E.catName(c)}</option>`).join('')}</select>
    <input id="v" inputmode="decimal" placeholder="المبلغ الشهري بالريال (0 للحذف)"><button class="wide" id="save">حفظ</button>
    <p class="muted">التنبيه عند 50% و75% و90% و100%.</p></div>`;
  document.querySelectorAll('[data-add]').forEach(b => b.onclick = async () => { state.budgets[b.dataset.add] = +b.dataset.v; await commit(); });
  document.querySelectorAll('[data-budget]').forEach(el => el.onclick = () => { $('#c').value = el.dataset.budget; $('#v').focus(); });
  $('#save').onclick = async () => { const v = E.parseHalalas($('#v').value); if (v === null) return; if (v > 0) state.budgets[$('#c').value] = v; else delete state.budgets[$('#c').value]; await commit(); };
}

function subs() {
  setTitle('الاشتراكات');
  const r = E.recurring(state, now());
  const mc = E.monthlyCost(r);
  $('#view').innerHTML = `<div class="grid"><div class="stat"><small>التكلفة الشهرية</small><b>${money(mc)}</b></div><div class="stat"><small>التكلفة السنوية</small><b>${money(mc * 12)}</b></div></div>
    <div class="card"><h3>المدفوعات المتكررة المكتشفة</h3>${r.map(x => `<div class="row"><div class="ic">${E.catIcon(x.category)}</div><div class="mid"><div>${h(x.name)}</div>
      <div class="muted">${x.label} · القادم ${E.fmtDate(x.next, false)} · ${x.count} مرات${x.confidence < 0.6 ? ' · ثقة منخفضة' : ''}</div></div>${money(x.expected)}</div>`).join('') ||
      '<p class="muted">تظهر بعد 2–3 خصومات من نفس الجهة.</p>'}</div>`;
}

function importView() {
  setTitle('الاستيراد');
  $('#view').innerHTML = `<div class="card"><h3>كشف حساب CSV</h3>
      <p class="muted">نزّل كشف الحساب من تطبيق البنك بصيغة CSV أو Excel، ثم احفظه كـ CSV. استيراد فترات متداخلة آمن: المسجل لا يتكرر.</p>
      <label>الحساب</label><select id="ac">${state.accounts.filter(a => !a.archived).map(a => `<option value="${a.id}">${h(a.name)}</option>`).join('')}</select>
      <button class="wide" id="csv" ${state.accounts.length ? '' : 'disabled'}>اختر ملف CSV</button>
      ${state.accounts.length ? '' : '<p class="orange">أضف حساباً أولاً من «الحسابات».</p>'}</div>
    <div class="card"><h3>لصق رسائل بنكية</h3><p class="muted">الصق رسالة أو أكثر، وافصل بينها بسطر فارغ. مفيد للرسائل القديمة.</p>
      <textarea id="txt" rows="6"></textarea><button class="wide" id="paste">معالجة الرسائل</button></div>
    <div class="card"><h3>ملف الاختصارات</h3><p class="muted">نفس زر «تحديث» في الرئيسية.</p><button class="wide ghost" id="inbox">اختر ملف m9rofi.txt</button></div>
    <div id="out"></div>`;
  const show = (r, extra = '') => { $('#out').innerHTML = `<div class="card"><b>النتيجة</b><p>${reportText(r)}</p>${extra}</div>`; };
  $('#csv').onclick = async () => {
    const f = await pickFile('.csv,text/csv,text/plain'); if (!f) return;
    const res = E.importStatement(E.parseCSV(await f.text()), $('#ac').value);
    const r = E.record(state, res.records.map(rec => ({ type: 'record', rec })), now());
    if (res.closing) state.balances.push({ accountId: $('#ac').value, balance: res.closing.balance, ts: res.closing.ts, source: 'statement' });
    await commit(r); location.hash = 'importView'; show(r, res.skipped.length ? `<p class="orange">${res.skipped.slice(0, 10).map(h).join('<br>')}</p>` : '');
  };
  $('#paste').onclick = async () => {
    const blocks = $('#txt').value.split(/\n\s*\n/).filter(b => b.trim());
    const r = E.record(state, blocks.map(b => E.parseSMS(b, null, now(), state.templates)), now());
    await commit(r); location.hash = 'importView'; show(r);
  };
  $('#inbox').onclick = syncInbox;
}

function settings() {
  setTitle('الإعدادات');
  const s = state.settings;
  $('#view').innerHTML = `<div class="card"><h3>قواعد الاحتساب</h3>
      <label><input type="checkbox" id="ext" style="width:auto" ${s.externalTransfersAsSpending ? 'checked' : ''}> احتساب كل التحويلات لأشخاص خارج العائلة كمصروف</label><br>
      <label><input type="checkbox" id="cash" style="width:auto" ${s.cashAsSpending ? 'checked' : ''}> احتساب السحب النقدي كمصروف</label>
      <label>اسمك كما يظهر في التحويلات، بالعربي والإنجليزي (مثال: خليل سمان, KHALIL SAMMAN). يُستخدم لكشف التحويل لنفسك ولتصنيف تحويلات العائلة تلقائياً.</label><input id="own" value="${h(s.ownerNames.join(', '))}">
      <button class="wide" id="save">حفظ</button></div>
    <div class="card"><h3>الخصوصية</h3><p class="muted">بياناتك محفوظة في هذا الجهاز فقط داخل Safari. لا تُرسل لأي خادم. حذف التطبيق من الشاشة الرئيسية أو مسح بيانات Safari يحذفها، لذلك صدّر نسخة احتياطية بانتظام.</p>
      <button class="wide ghost" id="bk">تصدير نسخة احتياطية</button><button class="wide ghost" id="rs">استعادة نسخة احتياطية</button>
      <button class="wide danger" id="wipe">حذف جميع البيانات</button></div>
    <p class="muted">عدد العمليات: ${state.txs.length} · الحسابات: ${state.accounts.length}</p>`;
  $('#save').onclick = async () => { s.externalTransfersAsSpending = $('#ext').checked; s.cashAsSpending = $('#cash').checked;
    s.ownerNames = $('#own').value.split(/[,،]/).map(x => x.trim()).filter(Boolean); E.refreshCategories(state); await commit(); tell('تم الحفظ'); };
  $('#bk').onclick = () => download(`m9rofi-backup-${E.fmtDate(now(), false)}.json`, JSON.stringify(state), 'application/json');
  $('#rs').onclick = async () => { const f = await pickFile('.json,application/json'); if (!f) return;
    try { const d = JSON.parse(await f.text()); if (!Array.isArray(d.txs)) throw 0; if (await askYesNo('استبدال البيانات الحالية بالنسخة الاحتياطية؟')) { state = { ...E.newState(), ...d }; await commit(); } }
    catch { tell('ملف غير صالح'); } };
  $('#wipe').onclick = async () => { if (await askYesNo('حذف كل العمليات والحسابات والميزانيات نهائياً؟') && await askYesNo('متأكد؟ لا يمكن التراجع.')) { state = E.newState(); notices = []; await commit(); } };
}

function guide() {
  setTitle('خطوات الإعداد');
  $('#view').innerHTML = `
  <div class="card"><h3>١. أضف حساباتك</h3><p>من «المزيد ← الحسابات» أضف الأهلي وBarq وD360، واكتب آخر 4 أرقام لكل بطاقة وحساب.</p><a class="btn" href="#accounts">الحسابات</a></div>
  <div class="card"><h3>٢. اختصار رسائل البنك (مرة واحدة لكل البنوك)</h3><ol>
    <li>الاختصارات ← <b>Automation</b> ← <b>+</b> ← <b>Edit</b> ← زر <b>Automation</b> ← <b>Message</b>.</li>
    <li>اضغط <b>Add Filter</b> واختر <b>Message contains</b> واكتب: <code>SAR</code></li>
    <li>ابحث عن إجراء <b>Text</b> والصق فيه:<pre class="code">###|sms</pre>ثم سطر جديد ← <b>Select Variable</b> ← <b>Message</b>.</li>
    <li>ابحث عن إجراء <b>Append to Text File</b>، واكتب في File Path: <code>m9rofi.txt</code></li></ol></div>
  <div class="card"><h3>٣. اختصار Apple Pay</h3><ol>
    <li><b>الأتمتة</b> ← <b>+</b> ← <b>معاملة</b> ← اختر كل البطاقات ← <b>تشغيل فوراً</b>.</li>
    <li>إجراء <b>نص</b>:<pre class="code">###|pay|[التاريخ الحالي]|[البطاقة]|[التاجر]|[المبلغ]</pre>(التاريخ بتنسيق ISO 8601، والبقية من مُدخل الاختصار).</li>
    <li>إجراء <b>إلحاق بملف نصي</b> لنفس الملف <code>m9rofi.txt</code>.</li></ol></div>
  <div class="card"><h3>٤. كل يوم</h3><p>افتح مصروفي ← اضغط <b>⟳ تحديث</b> ← اختر <code>m9rofi.txt</code> من مجلد <b>Shortcuts</b> في iCloud Drive. خلاص.</p></div>
  <div class="card"><h3>٥. أول مرة</h3><p>استورد كشف آخر شهر لكل حساب من «المزيد ← الاستيراد» حتى يكتمل السجل.</p></div>`;
}

// ───────────── Boot ─────────────
(async () => {
  try { const s = HOST ? HOST.state : await load(); if (s) { state = { ...E.newState(), ...s, settings: { ...E.newState().settings, ...s.settings } }; const m = E.upgrade(state); if (E.refreshCategories(state) || m) await save(); } } catch { /* first run */ }
  if (!HOST && navigator.storage?.persist) navigator.storage.persist();
  if (!HOST && 'serviceWorker' in navigator) navigator.serviceWorker.register('sw.js').catch(() => {});
  render();
})();
