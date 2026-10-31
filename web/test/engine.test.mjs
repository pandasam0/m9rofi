import test from 'node:test';
import assert from 'node:assert/strict';
import * as E from '../engine.js';

const D = s => { const [d, t = '12:00'] = s.split(' '); const [y, m, dd] = d.split('-').map(Number); const [h, mi] = t.split(':').map(Number); return E.riyadhTs(y, m, dd, h, mi); };
const NOW = D('2026-10-28 12:00');
const S = (text, sender = 'SNB') => E.parseSMS(text, sender, D('2026-10-15 12:00'));
function L(withCC = false) {
  const s = E.newState();
  s.accounts = [
    { id: 'snb-0001', name: 'الأهلي', institution: 'snb', type: 'current', cards: ['1234'], numbers: ['5678'], walletNames: ['SNB mada'], senders: ['SNB'], tracked: true },
    { id: 'barq-002', name: 'Barq', institution: 'barq', type: 'wallet', cards: ['7777'], numbers: ['9012'], walletNames: ['Barq'], senders: ['Barq'], tracked: true },
    { id: 'd360-003', name: 'D360', institution: 'd360', type: 'current', cards: ['3600'], numbers: ['3601'], walletNames: [], senders: ['D360'], tracked: true },
  ];
  if (withCC) s.accounts.push({ id: 'cc-00004', name: 'ائتمانية', institution: 'snb', type: 'creditCard', cards: ['4321'], numbers: [], walletNames: [], senders: [], tracked: true });
  s.settings.ownerNames = ['Sami Alharbi'];
  return s;
}
const month = s => E.summary(s, E.period('month', NOW), NOW);

const starbucks = 'شراء عبر نقاط البيع\nبطاقة: مدى *1234\nمبلغ: SAR 25.50\nلدى: STARBUCKS\nفي: 2026-10-15 08:15\nالرصيد: SAR 4,974.50';
const panda = 'POS Purchase\nCard: mada **1234\nAmount: SAR 120.00\nAt: PANDA HYPER\nDate: 15/10/2026 19:40\nBalance: SAR 4,854.50';
const toBarq = 'حوالة صادرة\nمن حساب: **5678\nمبلغ: 1,000.00 ر.س\nإلى: BARQ ***9012\nفي: 2026-10-16 10:00';
const barqIn = 'حوالة واردة\nمبلغ: SAR 1000\nمن: Sami Alharbi\nحساب **9012\n2026-10-16 10:01';
const salary = 'إيداع راتب\nمبلغ: SAR 15,000.00\nحساب **5678\n2026-10-27 06:00';
const atm = 'سحب نقدي من الصراف الآلي\nمبلغ: ٥٠٠ ريال\nبطاقة مدى *1234\n٢٠٢٦-١٠-١٧ ٢٠:٠٠';
const netflix = 'Online Purchase\nCard: Visa *4321\nAmount: USD 20.00 (SAR 75.30)\nAt: NETFLIX.COM\n2026-10-10 03:00';
const refund = 'استرداد مبلغ\nمبلغ: SAR 120.00\nلدى: PANDA HYPER\nبطاقة مدى *1234\n2026-10-18 12:00';
const reversal = 'عكس عملية شراء\nمبلغ SAR 25.50\nلدى: STARBUCKS\nبطاقة *1234\n2026-10-15 09:00';
const hold = 'حجز مبلغ (عملية معلقة)\nبطاقة *1234\nمبلغ: SAR 850.00\nلدى: MARRIOTT RIYADH\n2026-10-20 22:00';
const holdDone = 'شراء\nبطاقة *1234\nمبلغ: SAR 850.00\nلدى: MARRIOTT RIYADH\n2026-10-22 09:00';

test('amount parsing', () => {
  assert.equal(E.parseHalalas('١٬٢٣٤٫٥٠'), 123450);
  assert.equal(E.parseHalalas('1,000.00'), 100000);
  assert.equal(E.parseHalalas('12a'), null);
});

test('SMS parsing', () => {
  const r = S(starbucks).rec;
  assert.deepEqual([r.kind, r.direction, r.amount, r.merchant, r.card, r.balance, r.ts], ['purchase', 'debit', 2550, 'STARBUCKS', '1234', 497450, D('2026-10-15 08:15')]);
  const p = S(panda).rec;
  assert.deepEqual([p.amount, p.merchant, p.ts], [12000, 'PANDA HYPER', D('2026-10-15 19:40')]);
  const n = S(netflix).rec;
  assert.deepEqual([n.currency, n.amount, n.base], ['USD', 2000, 7530]);
  const t = S(toBarq).rec;
  assert.deepEqual([t.kind, t.acct, t.cpAcct], ['transferOut', '5678', '9012']);
  assert.equal(S(atm).rec.amount, 50000);
  assert.equal(S(hold).rec.status, 'pending');
  assert.equal(S('رمز التحقق: 123456 لعملية شراء بمبلغ 50 ريال. لا تشارك الرمز').reason, 'otp');
  assert.equal(S('عملية شراء مرفوضة بمبلغ SAR 300 - رصيد غير كاف').reason, 'declined');
  assert.equal(S('Purchase at RIYADH TREATMENT CENTER\nAmount: SAR 300.00').rec.kind, 'purchase');
});

test('same SMS twice counts once', () => {
  const s = L(); E.ingest(s, [S(starbucks)], NOW); const r = E.ingest(s, [S(starbucks)], NOW);
  assert.equal(r.dup, 1); assert.equal(month(s).spending, 2550);
});

test('Apple Pay + SMS merge into one', () => {
  const s = L();
  E.ingest(s, [{ type: 'record', rec: E.walletRecord('Starbucks', 'SAR 25.50', 'SNB mada', D('2026-10-15 08:14')) }], NOW);
  const r = E.ingest(s, [S(starbucks)], NOW);
  assert.equal(r.merged.length, 1); assert.equal(s.txs.length, 1); assert.equal(month(s).spending, 2550);
});

test('statement after SMS not double counted; reimport safe', () => {
  const s = L(); E.ingest(s, [S(starbucks), S(panda)], NOW);
  const csv = 'Date,Description,Debit,Credit,Balance\n15/10/2026,POS PURCHASE STARBUCKS RIYADH,25.50,,4974.50\n16/10/2026,POS PURCHASE PANDA HYPER,120.00,,4854.50\n20/10/2026,POS PURCHASE JARIR BOOKSTORE,300.00,,4554.50';
  const imp = () => E.importStatement(E.parseCSV(csv), 'snb-0001').records.map(rec => ({ type: 'record', rec }));
  const r = E.ingest(s, imp(), NOW);
  assert.equal(r.merged.length, 2); assert.equal(r.added.length, 1); assert.equal(month(s).spending, 44550);
  assert.equal(E.ingest(s, imp(), NOW).dup, 3); assert.equal(month(s).spending, 44550);
});

test('two genuine identical purchases both count', () => {
  const s = L(); E.ingest(s, [S(starbucks), S(starbucks.replace('08:15', '08:17').replace('4,974.50', '4,949.00'))], NOW);
  assert.equal(month(s).spending, 5100);
});

test('internal transfer SNB → Barq is not spending', () => {
  const s = L(); E.ingest(s, [S(toBarq)], NOW); E.ingest(s, [S(barqIn, 'Barq')], NOW);
  const m = month(s);
  assert.deepEqual([m.spending, m.income, m.transfersIn, m.internalCount], [0, 0, 0, 2]);
});

test('external transfer is spending when enabled; incoming is not income', () => {
  const s = L(); s.settings.externalTransfersAsSpending = true;
  E.ingest(s, [{ source: 'sms', id: 'o', amount: 25000, currency: 'SAR', direction: 'debit', kind: 'transferOut', ts: D('2026-10-12 09:00'), hasTime: true, counterparty: 'Ahmed', accountId: 'snb-0001' },
    { source: 'sms', id: 'i', amount: 40000, currency: 'SAR', direction: 'credit', kind: 'transferIn', ts: D('2026-10-13 09:00'), hasTime: true, counterparty: 'Khalid', accountId: 'snb-0001' }], NOW);
  const m = month(s);
  assert.deepEqual([m.spending, m.income, m.transfersIn], [25000, 0, 40000]);
});

test('card payment with tracked card not counted twice; untracked goes to review', () => {
  const s = L(true); E.ingest(s, [S(netflix)], NOW);
  E.ingest(s, [{ source: 'sms', id: 'p', amount: 7530, currency: 'SAR', direction: 'debit', kind: 'cardPayment', ts: D('2026-10-25 09:00'), hasTime: true, accountId: 'snb-0001' }], NOW);
  assert.equal(month(s).spending, 7530);
  const u = L();
  E.ingest(u, [{ source: 'sms', id: 'p', amount: 150000, currency: 'SAR', direction: 'debit', kind: 'cardPayment', ts: D('2026-10-25 09:00'), hasTime: true, accountId: 'snb-0001' }], NOW);
  assert.deepEqual(u.txs[0].review, ['cardPaymentUntracked']); assert.equal(month(u).spending, 0);
  E.resolve(u, u.txs[0].id, 'cardExpense'); assert.equal(month(u).spending, 150000);
});

test('pending excluded, then completed counted once', () => {
  const s = L(); E.ingest(s, [S(hold)], NOW);
  assert.deepEqual([month(s).spending, month(s).pending], [0, 85000]);
  E.ingest(s, [S(holdDone)], NOW);
  assert.equal(s.txs.length, 1); assert.deepEqual([month(s).spending, month(s).pending], [85000, 0]);
  assert.equal(month(s).byCategory[0].category, 'travel');
});

test('refund reduces same category; reversal cancels', () => {
  const s = L(); E.ingest(s, [S(panda), S(starbucks)], NOW); E.ingest(s, [S(refund)], NOW);
  assert.equal(month(s).spending, 2550);
  E.ingest(s, [S(reversal)], NOW);
  assert.equal(month(s).spending, 0);
});

test('foreign without SAR → review until confirmed', () => {
  const s = L();
  E.ingest(s, [{ source: 'sms', id: 'f', amount: 5000, currency: 'USD', direction: 'debit', kind: 'purchase', ts: D('2026-10-12 09:00'), hasTime: true, merchant: 'AMAZON.COM' }], NOW);
  assert.deepEqual(s.txs[0].review, ['missingBaseAmount']); assert.equal(month(s).spending, 0);
  E.resolve(s, s.txs[0].id, 'confirm', { base: 18810 }); assert.equal(month(s).spending, 18810);
});

test('salary income, ATM not spending', () => {
  const s = L(); E.ingest(s, [S(salary), S(atm), S(starbucks)], NOW);
  const m = month(s); assert.deepEqual([m.income, m.cash, m.spending, m.net], [1500000, 50000, 2550, 1497450]);
});

test('ambiguous duplicate held for review then merged', () => {
  const s = L(); E.ingest(s, [S(starbucks), S(starbucks.replace('08:15', '08:16').replace('4,974.50', '4,949.00'))], NOW);
  E.ingest(s, [{ source: 'statement', id: 's1', amount: 2550, currency: 'SAR', direction: 'debit', kind: 'purchase', ts: D('2026-10-15'), hasTime: false, merchant: 'STARBUCKS', accountId: 'snb-0001' }], NOW);
  const rv = s.txs.find(t => t.review.length);
  assert.deepEqual(rv.review, ['possibleDuplicate']); assert.equal(month(s).spending, 5100);
  E.resolve(s, rv.id, 'merge'); assert.equal(s.txs.length, 2); assert.equal(month(s).spending, 5100);
});

test('learned category applies to past and future', () => {
  const s = L(); const mk = (id, d) => ({ source: 'sms', id, amount: 4000, currency: 'SAR', direction: 'debit', kind: 'purchase', ts: D(d), hasTime: true, merchant: 'ABU KHALID KITCHEN', card: '1234' });
  E.ingest(s, [mk('1', '2026-10-01 13:00')], NOW); assert.equal(s.txs[0].category, 'dining');
  E.recategorize(s, s.txs[0].id, 'personal'); E.ingest(s, [mk('2', '2026-10-08 13:00')], NOW);
  assert.ok(s.txs.every(t => t.category === 'personal'));
});

test('inbox file from Shortcuts', () => {
  const inbox = `###|sms|2026-10-15T08:16:00+03:00|SNB\n${starbucks}\n###|pay|2026-10-15T08:14:00+03:00|SNB mada|Starbucks|SAR 25.50\n###|sms|2026-10-15T09:00:00+03:00|SNB\nرمز التحقق 1234 لا تشارك\n`;
  const s = L(); const r = E.ingest(s, E.parseInbox(inbox), NOW);
  assert.equal(s.txs.length, 1); assert.equal(r.ignored, 1); assert.equal(month(s).spending, 2550);
  assert.equal(E.ingest(s, E.parseInbox(inbox), NOW).dup, 2);
});

test('history: recurring, budgets, assistant', () => {
  const s = L(); const recs = []; let n = 0;
  const add = (amount, direction, kind, d, merchant) => recs.push({ source: 'sms', id: 'h' + ++n, amount, currency: 'SAR', direction, kind, ts: D(d), hasTime: true, merchant, card: '1234' });
  for (const mo of ['07', '08', '09', '10']) {
    add(1500000, 'credit', 'income', `2026-${mo}-27 06:00`, null);
    add(5699, 'debit', 'purchase', `2026-${mo}-05 03:00`, 'NETFLIX.COM');
    for (let d = 1; d <= 25; d += 3) add(1800, 'debit', 'purchase', `2026-${mo}-${String(d).padStart(2, '0')} 08:00`, 'BARNS');
    add(40000, 'debit', 'purchase', `2026-${mo}-10 18:00`, 'TAMIMI MARKETS');
  }
  E.ingest(s, recs, NOW);
  const nf = E.recurring(s, NOW).find(r => r.key.includes('netflix'));
  assert.deepEqual([nf.cadence, nf.expected, nf.next], ['monthly', 5699, D('2026-11-05 03:00')]);
  s.budgets = { coffee: 20000 };
  const b = E.budgetStatus(s, NOW)[0]; assert.deepEqual([b.spent, b.crossed, b.remaining], [16200, 75, 3800]);
  assert.equal(E.suggestBudgets(s, NOW).coffee, 20000);
  assert.equal(E.answer(s, 'كم صرفت على القهوة هذا الشهر؟', NOW).value, 16200);
  assert.equal(E.answer(s, 'كم صرفت هذا الشهر', NOW).value, 61899);
  assert.equal(E.answer(s, 'كم صرفت في آخر ٧ أيام', NOW).query.days, 7);
  assert.equal(E.answer(s, 'كم يتبقى لي من راتبي؟', NOW).value, 1500000);
  assert.equal(E.answer(s, 'كم يمكنني توفيره شهرياً؟', NOW).value, 1438101);
  assert.equal(E.answer(s, 'ما أكثر شيء استنزف أموالي؟', NOW).value, 40000);
  assert.equal(E.parseQuestion(s, 'أين يمكنني تقليل مصاريفي؟').intent, 'tips');
  assert.equal(E.parseQuestion(s, 'كم دفعت على الاشتراكات؟').category, 'subscriptions');
  assert.ok(E.exportCSV(s, E.period('month', NOW)).startsWith('﻿التاريخ'));
});

test('real SNB formats (Oct 2026)', () => {
  const a = E.parseSMS('شراء-POS\nبـSAR 1\nمن Shahrazad\nمدى-ابل*3098\nفي 19:13 31/10/26', 'SNB-AlAhli', 0).rec;
  assert.deepEqual([a.kind, a.amount, a.merchant, a.card, a.ts], ['purchase', 100, 'Shahrazad', '3098', D('2026-10-31 19:13')]);
  const b = E.parseSMS('شراء انترنت\nبـSAR 150\nمن 2002*\nمن barq\nمدى-ابل *3098\nفي 17:05 31/10/26', 'SNB-AlAhli', 0).rec;
  assert.deepEqual([b.kind, b.amount, b.merchant, b.card, b.acct], ['purchase', 15000, 'barq', '3098', '2002']);
});

test('real Barq ↔ SNB transfer is internal', () => {
  const st = L();
  st.accounts[0].numbers = ['2002']; st.accounts[1].numbers = ['0032'];
  const barqOut = 'حوالة صادرة محلية\nمبلغ1.00SAR\nرسوم0.00SAR\nلحساب2002\n2026-10-31 19:24';
  const snbIn = 'حوالة واردة محلية ب SAR 1\nمن KHALIL SAMMAN 0032*\n31/10/26 19:26';
  const o = E.parseSMS(barqOut, null, 0).rec, i = E.parseSMS(snbIn, null, 0).rec;
  assert.deepEqual([o.kind, o.amount, o.cpAcct], ['transferOut', 100, '2002']);
  assert.deepEqual([i.kind, i.amount, i.cpAcct], ['transferIn', 100, '0032']);
  E.ingest(st, [{ type: 'record', rec: o }, { type: 'record', rec: i }], NOW);
  const m = month(st);
  assert.deepEqual([m.spending, m.transfersIn, m.internalCount], [0, 0, 2]);
  const p = E.parseSMS('شراء نقاط بيع\nفيزاSAR 30.00\nرصيد106.78\nلدىQatrat\n2026-10-31 18:28', null, 0).rec;
  assert.deepEqual([p.kind, p.amount, p.merchant, p.balance], ['purchase', 3000, 'Qatrat', 10678]);
});

test('real weekly allowance: SNB + D360 (Oct 31)', () => {
  const st = L();
  st.accounts[0].numbers = ['2002']; st.accounts[0].cards = ['3098'];
  st.accounts[1].numbers = ['0032'];
  st.accounts[2].numbers = ['9631'];
  const msgs = [
    'حوالة واردة داخلية بSAR 1000\nمن9705* رامي سمان\n31/10/26 19:51',
    'حوالة صادرة داخلية بSAR 250\nل2405* رناد سمان\n31/10/26 20:00',
    'حوالة صادرة داخلية بSAR 250\nل6602* عبدالقادر سمان\n31/10/26 20:01',
    'شراء انترنت\nبـSAR 250\nمن 2002*\nمن MYSR D360\nمدى-ابل *3098\nفي 20:06 31/10/26',
    'اضافة باستخدام آبل باى\nمبلغ:SAR 250\nبطاقة:*3098 - mada\nإلى:*9631\nفي:20:06:23 31/10/2026',
    'حوالة صادرة داخلية\nمن : *9631\nمبلغ: SAR 250.00\nإلى: ELHAM SAMMAN\nرقم الحساب: *0529\nفي: 31-10-2026 20:06',
  ];
  const p = msgs.map(m => E.parseSMS(m, null, 0));
  assert.equal(p[0].rec.counterparty, 'رامي سمان');
  assert.equal(p[1].rec.counterparty, 'رناد سمان');
  assert.deepEqual([p[4].rec.kind, p[4].rec.direction, p[4].rec.acct, p[4].rec.cpAcct], ['transferIn', 'credit', '9631', '3098']);
  assert.deepEqual([p[5].rec.kind, p[5].rec.acct, p[5].rec.cpAcct, p[5].rec.counterparty], ['transferOut', '9631', '0529', 'ELHAM SAMMAN']);
  E.ingest(st, p, NOW);
  const m = month(st);
  assert.equal(m.spending, 0);                     // without owner name: transfers to people are not spending by default
  assert.equal(m.transfersOut, 75000);
  assert.equal(m.transfersIn, 100000);             // 1000 from Rami is an incoming transfer, not income
  assert.equal(m.income, 0);
  // With the owner's name, family transfers are recognised automatically.
  st.settings.ownerNames = ['خليل سمان', 'KHALIL SAMMAN'];
  E.refreshCategories(st);
  const f = month(st);
  assert.equal(f.income, 100000);                  // weekly allowance from Rami
  assert.equal(f.transfersIn, 0);
  assert.equal(f.spending, 75000);
  assert.deepEqual(f.byCategory.map(c => [c.category, c.amount]), [['family', 75000]]);
  assert.equal(E.relation('KHALIL SAMMAN', st.settings.ownerNames), 'self');
  assert.equal(E.relation('ELHAM SAMMAN', st.settings.ownerNames), 'family');
  assert.equal(E.relation('رامي سمان', st.settings.ownerNames), 'family');
  assert.equal(E.relation('Ahmed Ali', st.settings.ownerNames), null);
  assert.equal(m.internalCount, 2);                // SNB → D360 top-up legs
});

test('non-family transfer is not spending unless the user categorises it', () => {
  const st = L(); st.settings.ownerNames = ['خليل سمان', 'KHALIL SAMMAN'];
  E.ingest(st, [E.parseSMS('حوالة صادرة داخلية بSAR 300\nل1111* احمد علي\n31/10/26 20:00', null, 0),
                E.parseSMS('حوالة صادرة داخلية بSAR 250\nل2405* رناد سمان\n31/10/26 20:05', null, 0)], NOW);
  let m = month(st);
  assert.deepEqual([m.spending, m.transfersOut], [25000, 30000]);
  const ahmed = st.txs.find(t => t.counterparty === 'احمد علي');
  E.recategorize(st, ahmed.id, 'transfers', true);
  m = month(st);
  assert.deepEqual([m.spending, m.transfersOut], [55000, 0]);
  const old = E.newState(); old.settings = { externalTransfersAsSpending: true };
  assert.equal(E.migrate(old), true); assert.equal(old.settings.externalTransfersAsSpending, false);
});

test('self-healing: legacy wrong D360 entries are fixed automatically on upgrade', () => {
  const st = L(); st.settings.ownerNames = ['خليل سمان', 'KHALIL SAMMAN'];
  st.accounts[0].numbers = ['2002']; st.accounts[0].cards = ['3098']; st.accounts[2].numbers = ['9631']; st.accounts[2].type = 'wallet';
  const base = { currency: 'SAR', direction: 'debit', status: 'completed', hasTime: true, card: '3098', accountId: 'snb-0001', internal: false, link: null,
    review: [], excluded: false, created: 0, catConf: 0, counterparty: null, acct: null, cpAcct: null, ref: null, note: null };
  delete st.parserVersion; delete st.log;
  st.txs = [
    { ...base, id: 'a', amount: 25000, base: 25000, kind: 'purchase', ts: D('2026-10-31 20:06'), merchant: 'MYSR D360', mkey: 'mysr d', category: 'other', catSource: 'none', sources: [{ type: 'sms', id: 'x1' }] },
    { ...base, id: 'b', amount: 25000, base: 25000, kind: 'purchase', ts: D('2026-10-31 20:06') + 23000, merchant: null, mkey: null, category: 'other', catSource: 'none', sources: [{ type: 'sms', id: 'x2' }] },
    { ...base, id: 'c', amount: 25000, base: 25000, kind: 'transferOut', ts: D('2026-10-31 20:00'), merchant: null, mkey: 'رناد سمان', counterparty: 'رناد سمان', category: 'transfers', catSource: 'kind', sources: [{ type: 'sms', id: 'x3' }] },
  ];
  assert.equal(E.upgrade(st), true);
  E.refreshCategories(st);
  const m = month(st);
  assert.equal(m.spending, 25000);
  assert.deepEqual(m.byCategory.map(c => c.category), ['family']);
  assert.equal(m.internalCount, 2);
});

test('self-healing: rebuild re-parses history and keeps user corrections', () => {
  const st = L();
  const inbox = '###|sms\nشراء-POS\nبـSAR 40\nمن Shahrazad\nمدى-ابل*1234\nفي 13:00 20/10/26\n';
  E.record(st, E.parseInbox(inbox), NOW);
  const t = st.txs[0];
  assert.equal(t.category, 'other');
  E.userOp(st, t.id, { op: 'cat', category: 'dining', learn: true });
  st.parserVersion = 0;                      // simulate a parser update
  assert.equal(E.upgrade(st), true);
  assert.equal(st.txs.length, 1);
  assert.equal(st.txs[0].category, 'dining');
  assert.equal(month(st).spending, 4000);
});

test('Apple Intelligence hint categorises unknown merchants only', () => {
  const st = L();
  E.record(st, E.parseInbox('###|sms\n@ai: Restaurant\nشراء-POS\nبـSAR 40\nمن Shahrazad\nمدى-ابل*1234\nفي 13:00 20/10/26\n' +
    '###|sms\n@ai: dining\nشراء-POS\nبـSAR 18\nمن STARBUCKS\nمدى-ابل*1234\nفي 08:00 21/10/26\n'), NOW);
  const sh = st.txs.find(t => t.merchant === 'Shahrazad'), sb = st.txs.find(t => t.merchant === 'STARBUCKS');
  assert.deepEqual([sh.category, sh.catSource], ['dining', 'ai']);
  assert.deepEqual([sb.category, sb.catSource], ['coffee', 'dictionary']);
  assert.equal(E.aiCategory('القهوة'), 'coffee');
  assert.equal(E.aiCategory('Groceries.'), 'groceries');
  assert.equal(E.aiCategory('blah'), null);
});

test('card top-up to own wallet is internal even without the wallet message', () => {
  const st = L();
  E.record(st, [E.parseSMS('شراء انترنت\nبـSAR 150\nمن 2002*\nمن barq\nمدى-ابل *1234\nفي 17:05 31/10/26', null, 0)], NOW);
  assert.equal(st.txs[0].internal, true);
  assert.equal(month(st).spending, 0);
});
