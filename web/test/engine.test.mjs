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

test('external transfer is spending; incoming is not income', () => {
  const s = L();
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
