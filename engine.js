// M9rofi finance engine (web). Port of Sources/FinanceCore.
// All money is stored as integer halalas (1 SAR = 100) to avoid floating-point errors.

export const TZ = 'Asia/Riyadh';
const TZ_OFFSET_MIN = 180; // Saudi Arabia has no DST

// ───────────────────────── Categories ─────────────────────────
export const CATEGORIES = {
  dining: ['المطاعم والمقاهي', '🍽️'], coffee: ['القهوة', '☕'], groceries: ['البقالة والسوبرماركت', '🛒'],
  shopping: ['التسوق والملابس', '🛍️'], auto: ['السيارات والبنزين', '⛽'], transport: ['المواصلات', '🚕'],
  subscriptions: ['الاشتراكات', '🔁'], entertainment: ['الترفيه والألعاب', '🎮'], travel: ['السفر والفنادق', '✈️'],
  health: ['الصحة والرياضة', '💊'], bills: ['الفواتير والخدمات', '🧾'], transfers: ['التحويلات المالية', '↔️'],
  cash: ['السحب النقدي', '💵'], personal: ['المصروفات الشخصية', '💈'], other: ['أخرى', '•'],
  family: ['تحويلات العائلة', '👨‍👩‍👧‍👦'],
  salary: ['الراتب', '💼'], allowance: ['الراتب الأسبوعي', '💰'], otherIncome: ['دخل آخر', '➕'], internalTransfer: ['تحويل داخلي', '🔄'],
};
export const EXPENSE_CATEGORIES = ['dining', 'coffee', 'groceries', 'shopping', 'auto', 'transport', 'subscriptions',
  'entertainment', 'travel', 'health', 'bills', 'family', 'transfers', 'cash', 'personal', 'other'];
export const isExpenseCat = c => EXPENSE_CATEGORIES.includes(c);
export const INCOME_CATEGORIES = ['salary', 'allowance', 'otherIncome'];
export const isIncomeCat = c => INCOME_CATEGORIES.includes(c);

// Family = counterparty shares the owner's family name (last word), but is not the owner.
const normName = s => normDigits(s || '').toLowerCase().replace(/[أإآ]/g, 'ا').replace(/ة/g, 'ه').replace(/ى/g, 'ي')
  .replace(/^ال/, '').replace(/[^\p{L}\s]/gu, ' ').split(/\s+/).filter(Boolean);
export function relation(counterparty, ownerNames = []) {
  const cp = normName(counterparty);
  if (!cp.length) return null;
  for (const o of ownerNames) {
    const on = normName(o);
    if (on.length && on.join(' ') === cp.join(' ')) return 'self';
  }
  const surnames = new Set(ownerNames.map(o => normName(o).pop()).filter(x => x && x.length >= 3));
  return surnames.has(cp[cp.length - 1]) && cp.length >= 2 ? 'family' : null;
}
export const catName = c => (CATEGORIES[c] || CATEGORIES.other)[0];
export const catIcon = c => (CATEGORIES[c] || CATEGORIES.other)[1];

export const REVIEW_TEXT = {
  missingAmount: 'المبلغ غير واضح', unknownDirection: 'لا يُعرف إن كانت خصماً أم إيداعاً',
  missingBaseAmount: 'عملة أجنبية دون المبلغ المخصوم بالريال', possibleDuplicate: 'قد تكون مكررة',
  unmatchedReversal: 'إلغاء لم تُعرف عمليته الأصلية', cardPaymentUntracked: 'سداد بطاقة ائتمانية غير مضافة',
  possibleInternal: 'قد يكون تحويلاً لحسابك', lowConfidence: 'بيانات الرسالة غير مكتملة',
};

// ───────────────────────── Text helpers ─────────────────────────
const DIGITS = { '٠': '0', '١': '1', '٢': '2', '٣': '3', '٤': '4', '٥': '5', '٦': '6', '٧': '7', '٨': '8', '٩': '9',
  '۰': '0', '۱': '1', '۲': '2', '۳': '3', '۴': '4', '۵': '5', '۶': '6', '۷': '7', '۸': '8', '۹': '9', '٫': '.', '٬': ',', '،': ',' };

export function normDigits(s) {
  return String(s ?? '').replace(/[٠-٩۰-۹٫٬،]/g, ch => DIGITS[ch]).replace(/[‎‏‪-‮⁦-⁩؜]/g, '');
}

/** "1,234.50" → 123450 halalas. null if invalid. */
export function parseHalalas(raw) {
  let s = normDigits(raw).trim().replace(/[,\s ]/g, '');
  let neg = false;
  if (s.startsWith('-')) { neg = true; s = s.slice(1); }
  if (s.startsWith('(') && s.endsWith(')')) { neg = true; s = s.slice(1, -1); }
  if (!/^\d+(\.\d{1,3})?$/.test(s)) return null;
  const [i, f = ''] = s.split('.');
  const v = parseInt(i, 10) * 100 + parseInt((f + '00').slice(0, 2), 10) + (f.length > 2 && f[2] >= '5' ? 1 : 0);
  return neg ? -v : v;
}

export function fnv1a(str) {
  let h = 0xcbf29ce484222325n;
  const bytes = typeof TextEncoder !== 'undefined' ? new TextEncoder().encode(str)
    : Array.from(unescape(encodeURIComponent(str)), c => c.charCodeAt(0)); // Scriptable runtime has no TextEncoder
  for (const b of bytes) { h ^= BigInt(b); h = (h * 0x100000001b3n) & 0xffffffffffffffffn; }
  return h.toString(16);
}

const STOP = new Set(['ksa', 'sa', 'saudi', 'arabia', 'riyadh', 'jeddah', 'dammam', 'khobar', 'makkah', 'madinah', 'co', 'ltd',
  'llc', 'est', 'company', 'branch', 'store', 'the', 'com', 'الرياض', 'جدة', 'الدمام', 'الخبر', 'مكة', 'المدينة', 'شركة', 'مؤسسة', 'فرع']);

export function merchantKey(raw) {
  let s = normDigits(raw || '').toLowerCase();
  for (const p of ['sq *', 'sq*', 'pos ', 'pos*', 'apl*', 'apple pay ', 'paypal *', 'pp*']) if (s.startsWith(p)) s = s.slice(p.length);
  s = s.replace(/[^\p{L}\s]/gu, ' ');
  return s.split(/\s+/).filter(t => t && !STOP.has(t)).join(' ');
}

export function similarity(a, b) {
  if (!a || !b) return 0;
  const ka = merchantKey(a), kb = merchantKey(b);
  if (!ka || !kb) return 0;
  if (ka === kb) return 1;
  if (ka.includes(kb) || kb.includes(ka)) return 0.85;
  const ta = new Set(ka.split(' ')), tb = new Set(kb.split(' '));
  const inter = [...ta].filter(x => tb.has(x)).length;
  return inter / new Set([...ta, ...tb]).size;
}

function has(lower, words) {
  return words.some(w => /^[a-z]{1,6}$/.test(w) ? new RegExp(`\\b${w}\\b`).test(lower) : lower.includes(w));
}

// ───────────────────────── Dates (Riyadh) ─────────────────────────
export function riyadhParts(ts) {
  const d = new Date(ts + TZ_OFFSET_MIN * 60000);
  return { y: d.getUTCFullYear(), m: d.getUTCMonth() + 1, d: d.getUTCDate(), h: d.getUTCHours(), min: d.getUTCMinutes(), wd: d.getUTCDay() };
}
export function riyadhTs(y, m, d, h = 12, min = 0) { return Date.UTC(y, m - 1, d, h, min) - TZ_OFFSET_MIN * 60000; }
export const startOfDay = ts => { const p = riyadhParts(ts); return riyadhTs(p.y, p.m, p.d, 0, 0); };
export function fmtDate(ts, withTime = true) {
  const p = riyadhParts(ts);
  const pad = n => String(n).padStart(2, '0');
  return `${p.y}-${pad(p.m)}-${pad(p.d)}` + (withTime ? ` ${pad(p.h)}:${pad(p.min)}` : '');
}

const MONTHS = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];

/** Returns {ts, hasTime} or null. */
export function parseDate(text) {
  const s = normDigits(text);
  let y, mo, d, end = -1, m;
  if ((m = /(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})/.exec(s))) { [y, mo, d] = [+m[1], +m[2], +m[3]]; }
  else if ((m = /(\d{1,2})[-/.](\d{1,2})[-/.](\d{4})/.exec(s))) { [d, mo, y] = [+m[1], +m[2], +m[3]]; }
  else if ((m = /(\d{1,2})[-/.](\d{1,2})[-/.](\d{2})(?!\d)/.exec(s))) { [d, mo, y] = [+m[1], +m[2], 2000 + +m[3]]; }
  else if ((m = /(\d{1,2})[\s-]([A-Za-z]{3})[A-Za-z]*[\s-,]*(\d{2,4})/.exec(s)) && MONTHS.includes(m[2].toLowerCase())) {
    [d, mo, y] = [+m[1], MONTHS.indexOf(m[2].toLowerCase()) + 1, +m[3] < 100 ? 2000 + +m[3] : +m[3]];
  }
  if (!m || !(mo >= 1 && mo <= 12 && d >= 1 && d <= 31)) return null;
  end = m.index + m[0].length;
  const tre = /(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(am|pm|AM|PM|ص|م)?/;
  const t = tre.exec(s.slice(end)) || tre.exec(s);
  if (t && +t[1] < 24 && +t[2] < 60) {
    let h = +t[1];
    const ap = (t[4] || '').toLowerCase();
    if ((ap === 'pm' || ap === 'م') && h < 12) h += 12;
    if ((ap === 'am' || ap === 'ص') && h === 12) h = 0;
    return { ts: riyadhTs(y, mo, d, h, +t[2]), hasTime: true };
  }
  return { ts: riyadhTs(y, mo, d, 12, 0), hasTime: false };
}

// ───────────────────────── SMS parser ─────────────────────────
const OTP = ['رمز التحقق', 'رمز التفعيل', 'كلمة المرور لمرة واحدة', 'otp', 'verification code', 'one time password', 'لا تشارك', 'do not share', 'رمز الدخول', 'passcode'];
const DECLINED = ['مرفوضة', 'مرفوض', 'تم رفض', 'رفض العملية', 'declined', 'rejected', 'insufficient', 'رصيد غير كاف', 'الرصيد غير كاف', 'فشلت', 'failed', 'غير ناجحة', 'unsuccessful'];
const PROMO = ['عرض خاص', 'احصل على', 'offer', 'promo', 'تمويل شخصي', 'سجل الآن', 'قسّط'];
export const KIND_RULES = [
  ['reversal', ['عكس', 'معكوسة', 'reversal', 'reversed', 'إلغاء العملية', 'الغاء العملية', 'ملغاة', 'cancelled', 'canceled', 'void']],
  ['refund', ['استرداد', 'مسترد', 'استرجاع', 'refund', 'refunded', 'merchant credit']],
  ['cardPayment', ['سداد بطاقة', 'سداد البطاقة', 'سداد مستحقات البطاقة', 'credit card payment', 'card payment received', 'payment to card', 'سداد الائتمانية']],
  ['income', ['راتب', 'الراتب', 'salary', 'payroll', 'رواتب']],
  ['cashWithdrawal', ['سحب نقدي', 'سحب صراف', 'صراف آلي', 'سحب من الصراف', 'atm withdrawal', 'cash withdrawal', 'atm']],
  ['cashDeposit', ['إيداع نقدي', 'ايداع نقدي', 'cash deposit']],
  ['transferIn', ['حوالة واردة', 'تحويل وارد', 'حوالة محلية واردة', 'حوالة دولية واردة', 'incoming transfer', 'transfer received', 'received a transfer', 'inward transfer', 'إيداع حوالة', 'ايداع حوالة', 'استلام حوالة',
    'اضافة باستخدام', 'إضافة باستخدام', 'اضافة رصيد', 'إضافة رصيد', 'تعبئة المحفظة', 'top up', 'top-up', 'money added']],
  ['transferOut', ['حوالة صادرة', 'تحويل صادر', 'حوالة محلية صادرة', 'حوالة دولية', 'outgoing transfer', 'outward transfer', 'transfer to', 'تحويل إلى', 'تحويل الى', 'حوالة إلى', 'حوالة الى', 'حوالة داخلية', 'حوالة فورية', 'sarie', 'سريع', 'transfer sent']],
  ['billPayment', ['سداد فاتورة', 'سداد فواتير', 'سداد', 'sadad', 'bill payment', 'فاتورة', 'مدفوعات حكومية', 'government payment']],
  ['fee', ['رسوم', 'عمولة', 'fee', 'charges', 'commission']],
  ['purchase', ['شراء', 'purchase', 'pos', 'نقاط البيع', 'مدى', 'mada', 'apple pay', 'ابل باي', 'أبل باي', 'online', 'عبر الإنترنت', 'عبر الانترنت', 'e-commerce', 'دفع', 'payment at', 'spent', 'مشتريات']],
];
const DEBIT = ['خصم', 'مدين', 'debited', 'debit', 'deducted', 'spent', 'سحب', 'صادرة', 'دفع'];
const CREDIT = ['إيداع', 'ايداع', 'دائن', 'credited', 'credit', 'أضيف', 'اضافة', 'إضافة', 'واردة', 'received', 'deposited'];
const PENDING = ['معلقة', 'معلق', 'قيد المعالجة', 'قيد التنفيذ', 'pending', 'pre-auth', 'preauth', 'authorization hold', 'حجز مبلغ', 'محجوز'];
export const CURRENCY = { 'sar': 'SAR', 'sr': 'SAR', 'ر.س': 'SAR', 'ر س': 'SAR', 'رس': 'SAR', 'ريال': 'SAR', 'ريال سعودي': 'SAR', 'rs': 'SAR',
  'usd': 'USD', '$': 'USD', 'دولار': 'USD', 'eur': 'EUR', '€': 'EUR', 'يورو': 'EUR', 'gbp': 'GBP', '£': 'GBP', 'aed': 'AED', 'درهم': 'AED',
  'kwd': 'KWD', 'bhd': 'BHD', 'qar': 'QAR', 'omr': 'OMR', 'egp': 'EGP', 'try': 'TRY', 'jod': 'JOD', 'inr': 'INR', 'jpy': 'JPY', 'cny': 'CNY' };
const BALANCE_LBL = ['الرصيد', 'رصيد', 'balance', 'bal', 'avail', 'المتاح', 'available'];
const FEE_LBL = ['رسوم', 'fee', 'عمولة', 'vat', 'ضريبة'];
const MERCHANT_LBL = ['لدى:', 'لدى', 'عند:', 'عند', 'التاجر:', 'التاجر', 'merchant:', 'merchant', 'at:', ' at ', 'من:', 'from:', 'في متجر', 'المتجر:', 'من '];
const OUT_LBL = ['إلى:', 'الى:', 'إلى', 'الى', 'to:', ' to ', 'المستفيد:', 'المستفيد', 'beneficiary:', 'beneficiary', 'لصالح'];
const IN_LBL = ['من:', 'from:', 'المرسل:', 'المرسل', 'sender:', 'by:', ' from '];
const esc = s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const CUR_RE = '(' + Object.keys(CURRENCY).sort((a, b) => b.length - a.length).map(esc).join('|') + ')';
const NUM_RE = '(\\d{1,3}(?:,\\d{3})+(?:\\.\\d{1,3})?|\\d+(?:\\.\\d{1,3})?)';

export function moneyMatches(text) {
  const out = [];
  const add = (index, len, num, cur) => {
    const v = parseHalalas(num);
    if (v === null) return;
    if (out.some(o => index < o.index + o.len && o.index < index + len)) return;
    out.push({ index, len, value: v, currency: cur ? CURRENCY[cur.toLowerCase()] : null });
  };
  for (const m of text.matchAll(new RegExp(CUR_RE + '\\s*[:.]?\\s*' + NUM_RE, 'gi'))) add(m.index, m[0].length, m[2], m[1]);
  for (const m of text.matchAll(new RegExp(NUM_RE + '\\s*' + CUR_RE + '(?![a-z])', 'gi'))) add(m.index, m[0].length, m[1], m[2]);
  for (const m of text.matchAll(new RegExp('(?:مبلغ|بمبلغ|بقيمة|المبلغ|amount|amt)\\s*[:：]?\\s*' + NUM_RE, 'gi'))) add(m.index, m[0].length, m[1], null);
  return out.sort((a, b) => a.index - b.index);
}

const CARD_RE = /(?:بطاقة|البطاقة|card|مدى|mada|visa|فيزا|ماستركارد|mastercard|credit card|الائتمانية)[^\d\n]{0,25}?[*xX#•.]+\s*(\d{4})(?!\d)|(?:بطاقة|البطاقة|card)\s*(?:رقم|no\.?|number)?\s*[:：]?\s*(\d{4})(?!\d)/i;
const ACCT_RE = /(?:من حساب|حساب|الحساب|account|acct|a\/c|ac)[^\d\n]{0,15}?[*xX#•.]+\s*(\d{4})(?!\d)|(?:من حساب|حساب|الحساب|account|a\/c)\s*(?:رقم|no\.?)?\s*[:：]?\s*\d*?(\d{4})(?!\d)/i;
const REF_RE = /(?:مرجع|الرقم المرجعي|رقم العملية|رقم المرجع|ref(?:erence)?(?:\s*no)?\.?)\s*[:：#]?\s*([A-Za-z0-9]{5,})/i;
const cap = (re, t) => { const m = re.exec(t); return m ? (m[1] || m[2] || null) : null; };
// SNB style: a line "من 2002*" = debited account last 4.
const ACCT_LINE_RE = /^\s*من\s*[:：]?\s*\*?(\d{4})\*?\s*$/m;
const TO_LINE_RE = /^\s*(?:إلى|الى)\s*[:：]?\s*\*?(\d{4})\*?\s*$/m;

// "لحساب2002" = destination account (not the debited one).
const TO_ACCT_RE = /(?:لحساب|للحساب|إلى حساب|الى حساب|to account)\s*[:：]?\s*\*?\s*(\d{4})(?!\d)/gi;
export function counterpartyAccount(text) {
  const iban = /SA\d{2}[\d\s]{18,26}/i.exec(text);
  if (iban) return iban[0].replace(/\D/g, '').slice(-4);
  // Barq style: "لحساب2002"
  const to = new RegExp(TO_ACCT_RE.source, 'i').exec(text);
  if (to) return to[1];
  const lower = text.toLowerCase();
  for (const l of ['إلى', 'الى', 'to', 'للحساب', 'المستفيد']) {
    const i = lower.indexOf(l);
    if (i < 0) continue;
    const m = /[*xX#•]+\s*(\d{4})(?!\d)/.exec(lower.slice(i + l.length, i + l.length + 40));
    if (m) return m[1];
  }
  return null;
}

function labelled(text, labels) {
  const lines = text.split(/\r?\n/);
  for (const label of labels) for (const line of lines) {
    const i = line.toLowerCase().indexOf(label.toLowerCase());
    if (i < 0) continue;
    let v = line.slice(i + label.length);
    for (const stop of [' في ', ' on ', ' بتاريخ', ' date', ' بمبلغ', ' مبلغ', ' amount', ' بطاقة', ' card', ' رصيد', ' balance', ' الرصيد', ' SAR', ' ر.س', ' ريال', ',', '،', ' via ', ' عبر ']) {
      const j = v.toLowerCase().indexOf(stop.toLowerCase());
      if (j >= 0) v = v.slice(0, j);
    }
    v = v.replace(/^[\s:：\-.*\t]+|[\s:：\-.*\t]+$/g, '');
    if (v.length >= 2 && v.length <= 60 && /\p{L}/u.test(v)) return v;
  }
  return null;
}

/** Bump when parsing/matching rules change: saved message history is re-processed automatically. */
export const PARSER_VERSION = 6;

/** Which bank wrote the message, from its format. Used when no card/account digits identify the account. */
export function guessInstitution(text) {
  const n = normDigits(text);
  if (/مدى-ابل|بـ\s*SAR|^حوالة (?:صادرة|واردة) (?:داخلية|محلية) ب\s*SAR|\d{2}\/\d{2}\/\d{2}\s+\d{2}:\d{2}\s*$/m.test(n)) return 'snb';
  if (/^فيزا\s*SAR|^لدى\S|لحساب\d{4}|^رصيد\d/m.test(n) || (/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}\s*$/m.test(n) && /مبلغ\d|^فيزا/m.test(n))) return 'barq';
  if (/في:\s*\d|^من\s*:\s*\*\d{4}|^إلى:\s*\*\d{4}|اضافة باستخدام/m.test(n)) return 'd360';
  return null;
}

/** Parse one bank message. Returns {type:'record', rec} | {type:'balance', ...} | {type:'ignored', reason} | {type:'unparseable'}.
 *  Every outcome carries .src (the raw message) so history can be re-parsed after parser improvements. */
export function parseSMS(text, sender = null, receivedAt = Date.now(), templates = [], ai = null) {
  const o = parseSMSCore(text, sender, receivedAt, templates);
  o.src = { k: 'sms', text: String(text), sender: sender || null, ts: receivedAt, ai: ai || null };
  if (o.type === 'record' && ai) o.rec.ai = ai;
  if (o.type === 'record' && !o.rec.inst) o.rec.inst = guessInstitution(text);
  if (o.type === 'balance' && !o.inst) o.inst = guessInstitution(text);
  return o;
}

function parseSMSCore(text, sender, receivedAt, templates) {
  const n = normDigits(text);
  const lower = n.toLowerCase();
  if (!/\d/.test(lower)) return { type: 'ignored', reason: 'no numbers' };
  if (has(lower, OTP)) return { type: 'ignored', reason: 'otp' };
  if (has(lower, DECLINED)) return { type: 'ignored', reason: 'declined' };
  if (has(lower, PROMO) && moneyMatches(n).length === 0) return { type: 'ignored', reason: 'promotion' };
  const id = 'sms:' + fnv1a(n.trim());

  for (const t of templates) {
    if (t.sender && (!sender || t.sender.toLowerCase() !== sender.toLowerCase())) continue;
    let re; try { re = new RegExp(t.pattern, 'is'); } catch { continue; }
    const m = re.exec(n);
    if (!m || !m.groups?.amount) continue;
    const amt = parseHalalas(m.groups.amount);
    if (amt === null) continue;
    const pd = m.groups.date ? parseDate(m.groups.date) : null;
    const credit = ['transferIn', 'income', 'refund', 'cashDeposit'].includes(t.kind);
    return { type: 'record', rec: { source: 'sms', id, amount: Math.abs(amt), currency: CURRENCY[(m.groups.currency || 'sar').toLowerCase()] || 'SAR',
      direction: credit ? 'credit' : 'debit', kind: t.kind, status: has(lower, PENDING) ? 'pending' : 'completed',
      ts: pd?.ts ?? receivedAt, hasTime: pd?.hasTime ?? true, merchant: m.groups.merchant?.trim() || null,
      counterparty: m.groups.counterparty?.trim() || null, card: m.groups.card?.slice(-4) || null, acct: m.groups.account?.slice(-4) || null,
      balance: m.groups.balance ? parseHalalas(m.groups.balance) : null, hint: sender, confidence: 1 } };
  }

  let kind = 'unknown';
  for (const [k, w] of KIND_RULES) if (has(lower, w)) { kind = k; break; }
  if (kind === 'transferIn' || kind === 'transferOut') {
    const inHit = has(lower, KIND_RULES[6][1]), outHit = has(lower, KIND_RULES[7][1]);
    if (inHit && outHit) { const d = has(lower, DEBIT), c = has(lower, CREDIT); kind = d && !c ? 'transferOut' : c && !d ? 'transferIn' : 'unknown'; }
  }
  if (kind === 'unknown' && /حوالة|تحويل|transfer/.test(lower)) kind = has(lower, CREDIT) ? 'transferIn' : 'transferOut';

  let amount = null, currency = null, base = null, balance = null, confidence = 1;
  for (const mm of moneyMatches(n)) {
    const before = n.slice(Math.max(0, mm.index - 28), mm.index).toLowerCase();
    if (has(before, BALANCE_LBL) && !before.includes('مبلغ') && !before.includes('amount')) { if (balance === null) balance = mm.value; continue; }
    if (has(before, FEE_LBL) && amount !== null) continue;
    if (amount === null) { amount = mm.value; currency = mm.currency; }
    else if (base === null && currency && currency !== 'SAR' && mm.currency === 'SAR') base = mm.value;
  }
  if (amount !== null && !currency) { currency = 'SAR'; confidence -= 0.2; }

  if (kind === 'unknown' && amount === null) {
    if (balance !== null) return { type: 'balance', acct: cap(ACCT_RE, n), card: cap(CARD_RE, n), balance, ts: parseDate(n)?.ts ?? receivedAt, hint: sender };
    return { type: 'unparseable' };
  }

  let direction = null;
  if (['purchase', 'billPayment', 'fee', 'transferOut', 'cardPayment', 'cashWithdrawal'].includes(kind)) direction = 'debit';
  else if (['transferIn', 'income', 'refund', 'cashDeposit'].includes(kind)) direction = 'credit';
  else {
    const d = has(lower, DEBIT), c = has(lower, CREDIT);
    if (d !== c) direction = d ? 'debit' : 'credit'; else if (kind === 'reversal') direction = 'credit';
  }
  if (kind === 'cardPayment' && has(lower, CREDIT) && !has(lower, DEBIT)) direction = 'credit';
  if (kind === 'unknown') confidence -= 0.4;
  const status = has(lower, PENDING) ? 'pending' : 'completed';
  if (kind === 'unknown' && status === 'pending' && !direction) { kind = 'purchase'; direction = 'debit'; confidence += 0.4; }

  let merchant = null, counterparty = null;
  if (kind === 'transferOut') counterparty = labelled(n, OUT_LBL);
  else if (kind === 'transferIn' || kind === 'income') counterparty = labelled(n, IN_LBL);
  else merchant = labelled(n, MERCHANT_LBL);
  if (kind === 'purchase' && !merchant) confidence -= 0.2;

  // Balance written without currency, e.g. Barq "رصيد106.78"
  if (balance === null) { const bm = /(?:الرصيد|رصيد|balance)\s*[:：]?\s*(\d[\d,]*(?:\.\d{1,2})?)/i.exec(n); if (bm) balance = parseHalalas(bm[1]); }
  let cpAcct = counterpartyAccount(n);
  let card = cap(CARD_RE, n);
  // "رقم الحساب: *0529" after "إلى" in an outgoing transfer is the beneficiary, not the debited account.
  const ownText = n.replace(TO_ACCT_RE, ' ').replace(kind === 'transferOut' ? /رقم الحساب\s*[:：]?\s*\*?\d{4}/g : /$^/, ' ');
  let acct = cap(ACCT_LINE_RE, n) || cap(ACCT_RE, ownText);
  if (kind === 'transferIn') {
    // SNB: "من KHALIL SAMMAN 0032*" / "من9705* رامي سمان" → sender account last 4 and name
    if (!cpAcct) { const m = /من\s*[^\n]*?\*?(\d{4})\*/.exec(n); if (m) cpAcct = m[1]; }
    if (!counterparty) { const m = /من\s*\*?\d{4}\*\s*(\p{L}[^\n]*)$/mu.exec(n) || /من\s+(\p{L}[\p{L} ]*?)\s+\*?\d{4}\*/u.exec(n); if (m) counterparty = m[1].trim(); }
    // D360 top-up: "بطاقة:*3098 … إلى:*9631" → credited account is 9631; the card is the (own) source.
    const to = cap(TO_LINE_RE, n);
    if (to) { acct = to; if (card) cpAcct = card; card = null; }
  }
  if (kind === 'transferOut') {
    // SNB: "ل2405* رناد سمان"
    if (!cpAcct) { const m = /(?:^|\s)ل\s*\*?(\d{4})\*/m.exec(n); if (m) cpAcct = m[1]; }
    if (!counterparty) { const m = /(?:^|\s)ل\s*\*?\d{4}\*\s*(\p{L}[^\n]*)$/mu.exec(n); if (m) counterparty = m[1].trim(); }
  }
  const pd = parseDate(n);
  return { type: 'record', rec: { source: 'sms', id, amount, currency, base, direction, kind, status,
    ts: pd?.ts ?? receivedAt, hasTime: pd ? pd.hasTime : true, merchant, counterparty,
    card, acct, cpAcct, balance, ref: cap(REF_RE, n), hint: sender,
    confidence: Math.max(0, confidence) } };
}

// ───────────────────────── Apple Pay (Wallet automation) ─────────────────────────
export function walletRecord(merchant, amountText, card, ts) {
  const n = normDigits(amountText || '');
  const mm = moneyMatches(n)[0];
  let amount = mm?.value ?? parseHalalas(n.replace(/[^\d.,]/g, ''));
  let currency = mm?.currency || Object.entries(CURRENCY).find(([k]) => n.toLowerCase().includes(k))?.[1] || 'SAR';
  return { source: 'wallet', id: 'wallet:' + fnv1a(`${card}|${merchant}|${amountText}|${Math.floor(ts / 60000)}`),
    amount: amount === null ? null : Math.abs(amount), currency, direction: 'debit', kind: 'purchase', status: 'completed',
    ts, hasTime: true, merchant: merchant || null, walletCard: card || null, confidence: amount === null ? 0.3 : 0.9 };
}

/** Inbox file written by Shortcuts. Entries start with a line "###|sms|<iso date>|<sender>" or "###|pay|<iso date>|<card>|<merchant>|<amount>". */
export function parseInbox(text, templates = []) {
  const out = [];
  const blocks = String(text).replace(/\r\n/g, '\n').split(/^###\|/m).slice(1);
  for (const b of blocks) {
    const nl = b.indexOf('\n');
    const head = (nl < 0 ? b : b.slice(0, nl)).split('|').map(s => s.trim());
    const body = nl < 0 ? '' : b.slice(nl + 1).trim();
    const ts = Date.parse(head[1]) || Date.now();
    if (head[0] === 'pay') out.push({ type: 'record', rec: walletRecord(head[3], head[4] || body, head[2], ts) });
    else if (head[0] === 'sms' && body) {
      // Optional line "@ai: <category>" added by the Shortcuts "Use Model" action (Apple Intelligence).
      let ai = null;
      const clean = body.split('\n').filter(l => { const m = /^\s*@ai\s*:?\s*(.*)$/i.exec(l); if (m) { ai = aiCategory(m[1]); return false; } return true; }).join('\n').trim();
      if (clean) out.push(parseSMS(clean, head[2] || null, ts, templates, ai));
    }
  }
  return out;
}

/** Map a model answer ("coffee", "القهوة", "Coffee.") to a category key, or null. */
export function aiCategory(answer) {
  const a = normDigits(answer || '').toLowerCase().replace(/[^\p{L}\s]/gu, ' ').trim();
  if (!a) return null;
  for (const c of EXPENSE_CATEGORIES) if (a.split(/\s+/).includes(c.toLowerCase())) return c;
  const syn = { restaurant: 'dining', food: 'dining', مطعم: 'dining', مطاعم: 'dining', قهوة: 'coffee', قهوه: 'coffee', cafe: 'coffee',
    grocery: 'groceries', supermarket: 'groceries', بقالة: 'groceries', تسوق: 'shopping', ملابس: 'shopping', fuel: 'auto', car: 'auto', بنزين: 'auto',
    taxi: 'transport', مواصلات: 'transport', subscription: 'subscriptions', اشتراك: 'subscriptions', اشتراكات: 'subscriptions',
    games: 'entertainment', ترفيه: 'entertainment', hotel: 'travel', سفر: 'travel', pharmacy: 'health', صحة: 'health', gym: 'health',
    bill: 'bills', utilities: 'bills', فواتير: 'bills', salon: 'personal', شخصية: 'personal', أخرى: 'other', اخرى: 'other' };
  for (const w of a.split(/\s+/)) if (syn[w]) return syn[w];
  for (const c of EXPENSE_CATEGORIES) if (a.includes(catName(c).replace(/^ال/, ''))) return c;
  return null;
}

// ───────────────────────── CSV statements ─────────────────────────
export function parseCSV(text) {
  let s = String(text).replace(/^﻿/, '');
  const first = s.split('\n')[0];
  const delim = [';', '\t', ','].reduce((a, b) => (first.split(b).length > first.split(a).length ? b : a), ',');
  const rows = []; let row = [], f = '', q = false;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (q) { if (c === '"') { if (s[i + 1] === '"') { f += '"'; i++; } else q = false; } else f += c; continue; }
    if (c === '"') q = true;
    else if (c === delim) { row.push(f); f = ''; }
    else if (c === '\n' || c === '\r') { if (c === '\r' && s[i + 1] === '\n') i++; row.push(f); f = ''; if (!(row.length === 1 && !row[0])) rows.push(row); row = []; }
    else f += c;
  }
  if (f || row.length) { row.push(f); rows.push(row); }
  return rows.map(r => r.map(x => x.trim()));
}

const COLS = {
  date: ['تاريخ العملية', 'تاريخ', 'date', 'transaction date', 'posting date', 'value date', 'booking date'],
  time: ['الوقت', 'time'],
  desc: ['الوصف', 'البيان', 'التفاصيل', 'تفاصيل العملية', 'description', 'details', 'narrative', 'particulars', 'merchant', 'التاجر'],
  debit: ['مدين', 'خصم', 'سحب', 'المبلغ المدين', 'debit', 'withdrawal', 'withdrawals', 'money out', 'paid out'],
  credit: ['دائن', 'إيداع', 'ايداع', 'المبلغ الدائن', 'credit', 'deposit', 'deposits', 'money in', 'paid in'],
  amount: ['المبلغ', 'مبلغ', 'amount', 'transaction amount', 'value'],
  balance: ['الرصيد', 'رصيد', 'balance', 'running balance'],
  ref: ['المرجع', 'رقم المرجع', 'رقم العملية', 'reference', 'ref', 'ref no', 'transaction id'],
};

export function detectColumns(rows) {
  for (let ri = 0; ri < Math.min(15, rows.length); ri++) {
    const r = rows[ri].map(x => x.toLowerCase()); const map = { header: ri }; const used = new Set();
    for (const [k, names] of Object.entries(COLS)) {
      let i = r.findIndex((x, j) => !used.has(j) && names.includes(x));
      if (i < 0) i = r.findIndex((x, j) => !used.has(j) && x && names.some(nm => x.includes(nm)));
      if (i >= 0) { map[k] = i; used.add(i); }
    }
    if (map.date !== undefined && (map.amount !== undefined || map.debit !== undefined || map.credit !== undefined)) return map;
  }
  return null;
}

function stmtAmount(s) {
  let t = normDigits(s).replace(/SAR|SR|ر\.س|ريال/g, '').trim();
  let neg = false;
  if (/-$/.test(t)) { neg = true; t = t.slice(0, -1); }
  if (/DR$/i.test(t)) { neg = true; t = t.slice(0, -2); }
  t = t.replace(/CR$/i, '');
  const v = parseHalalas(t);
  return v === null ? null : neg ? -Math.abs(v) : v;
}

export function classifyDesc(desc, direction) {
  const lower = normDigits(desc).toLowerCase();
  for (const [k, w] of KIND_RULES) if (has(lower, w)) {
    if (k === 'transferIn' && direction === 'debit') return 'transferOut';
    if (k === 'transferOut' && direction === 'credit') return 'transferIn';
    if (['purchase', 'billPayment', 'fee'].includes(k) && direction === 'credit') return 'refund';
    if (k === 'income' && direction === 'debit') return 'transferOut';
    return k;
  }
  return direction === 'debit' ? 'purchase' : 'unknown';
}

function cleanDesc(desc) {
  let s = desc;
  for (const nz of ['شراء عبر نقاط البيع', 'شراء انترنت', 'شراء إنترنت', 'عملية شراء', 'POS PURCHASE', 'POS Purchase', 'PURCHASE', 'Purchase', 'Apple Pay', 'APPLE PAY', 'mada', 'MADA', 'مدى', '-'])
    s = s.split(nz).join(' ');
  s = s.replace(/\s+/g, ' ').trim();
  return s || null;
}

export function importStatement(rows, accountId) {
  const map = detectColumns(rows);
  if (!map) return { records: [], skipped: ['لم يتم التعرف على أعمدة الكشف'], closing: null };
  const records = [], skipped = [], seen = {};
  let closing = null;
  for (let i = map.header + 1; i < rows.length; i++) {
    const r = rows[i]; const cell = k => (map[k] !== undefined && r[map[k]] ? r[map[k]].trim() : null);
    const ds = cell('date');
    if (!ds) { skipped.push(`سطر ${i + 1}: بدون تاريخ`); continue; }
    const pd = parseDate(ds + ' ' + (cell('time') || ''));
    if (!pd) { skipped.push(`سطر ${i + 1}: تاريخ غير مفهوم`); continue; }
    let v = null;
    if (cell('amount')) v = stmtAmount(cell('amount'));
    const d = cell('debit') && stmtAmount(cell('debit')); if (d) v = -Math.abs(d);
    const c = cell('credit') && stmtAmount(cell('credit')); if (c) v = Math.abs(c);
    if (!v) { skipped.push(`سطر ${i + 1}: بدون مبلغ`); continue; }
    const desc = cell('desc') || '';
    const direction = v < 0 ? 'debit' : 'credit';
    const kind = classifyDesc(desc, direction);
    const ref = cell('ref');
    const baseId = ref ? 'ref:' + ref : fnv1a(`${accountId}|${ds}|${v}|${desc}`);
    const k = seen[baseId] = (seen[baseId] ?? -1) + 1;
    const bal = cell('balance') ? stmtAmount(cell('balance')) : null;
    const isT = ['transferIn', 'transferOut', 'income'].includes(kind);
    records.push({ source: 'statement', id: `stmt:${accountId.slice(0, 8)}:${baseId}:${k}`, amount: Math.abs(v), currency: 'SAR',
      direction, kind, status: 'completed', ts: pd.ts, hasTime: pd.hasTime, merchant: isT ? null : cleanDesc(desc),
      counterparty: isT ? cleanDesc(desc) : null, cpAcct: counterpartyAccount(desc), balance: bal, ref, accountId,
      note: desc || null, confidence: kind === 'unknown' ? 0.7 : 1 });
    if (bal !== null && (!closing || pd.ts >= closing.ts)) closing = { balance: bal, ts: pd.ts };
  }
  return { records, skipped, closing };
}

// ───────────────────────── Categorizer ─────────────────────────
const DICT = [
  ['starbucks', 'coffee'], ['dr cafe', 'coffee'], ['barns', 'coffee'], ['half million', 'coffee'], ['tim hortons', 'coffee'], ['caribou', 'coffee'],
  ['costa', 'coffee'], ['dunkin', 'coffee'], ['camel step', 'coffee'], ['overdose', 'coffee'], ['kyan', 'coffee'], ['ستاربكس', 'coffee'],
  ['بارنز', 'coffee'], ['دكتور كيف', 'coffee'], ['هاف مليون', 'coffee'], ['كوفي', 'coffee'], ['كافيه', 'coffee'], ['قهوة', 'coffee'],
  ['albaik', 'dining'], ['al baik', 'dining'], ['البيك', 'dining'], ['mcdonalds', 'dining'], ['mcdonald', 'dining'], ['kfc', 'dining'],
  ['burger king', 'dining'], ['hardees', 'dining'], ['herfy', 'dining'], ['هرفي', 'dining'], ['kudu', 'dining'], ['كودو', 'dining'],
  ['shawarmer', 'dining'], ['شاورمر', 'dining'], ['maestro pizza', 'dining'], ['dominos', 'dining'], ['pizza hut', 'dining'], ['subway', 'dining'],
  ['jahez', 'dining'], ['جاهز', 'dining'], ['hungerstation', 'dining'], ['هنقرستيشن', 'dining'], ['the chefz', 'dining'], ['chefz', 'dining'],
  ['toyou', 'dining'], ['mrsool', 'dining'], ['مرسول', 'dining'], ['keeta', 'dining'], ['مطعم', 'dining'], ['restaurant', 'dining'],
  ['panda', 'groceries'], ['بنده', 'groceries'], ['tamimi', 'groceries'], ['التميمي', 'groceries'], ['danube', 'groceries'], ['الدانوب', 'groceries'],
  ['othaim', 'groceries'], ['العثيم', 'groceries'], ['lulu', 'groceries'], ['لولو', 'groceries'], ['carrefour', 'groceries'], ['كارفور', 'groceries'],
  ['nesto', 'groceries'], ['farm superstores', 'groceries'], ['manuel', 'groceries'], ['ninja', 'groceries'], ['nana', 'groceries'], ['نعناع', 'groceries'],
  ['bindawood', 'groceries'], ['بن داود', 'groceries'], ['سوبرماركت', 'groceries'], ['supermarket', 'groceries'], ['تموينات', 'groceries'], ['بقالة', 'groceries'],
  ['aldrees', 'auto'], ['الدريس', 'auto'], ['sasco', 'auto'], ['ساسكو', 'auto'], ['petromin', 'auto'], ['بترومين', 'auto'], ['naft', 'auto'],
  ['نفط', 'auto'], ['almaha', 'auto'], ['المها', 'auto'], ['محطة', 'auto'], ['محطات', 'auto'], ['petrol', 'auto'], ['najm', 'auto'], ['مغسلة', 'auto'],
  ['uber', 'transport'], ['careem', 'transport'], ['كريم', 'transport'], ['bolt', 'transport'], ['jeeny', 'transport'], ['riyadh metro', 'transport'],
  ['sapt', 'transport'], ['darb', 'transport'], ['parking', 'transport'], ['مواقف', 'transport'],
  ['netflix', 'subscriptions'], ['نتفلكس', 'subscriptions'], ['shahid', 'subscriptions'], ['شاهد', 'subscriptions'], ['spotify', 'subscriptions'],
  ['anghami', 'subscriptions'], ['osn', 'subscriptions'], ['disney', 'subscriptions'], ['apple com bill', 'subscriptions'], ['icloud', 'subscriptions'],
  ['youtube premium', 'subscriptions'], ['google one', 'subscriptions'], ['chatgpt', 'subscriptions'], ['openai', 'subscriptions'],
  ['anthropic', 'subscriptions'], ['claude ai', 'subscriptions'], ['amazon prime', 'subscriptions'], ['microsoft', 'subscriptions'], ['adobe', 'subscriptions'],
  ['starzplay', 'subscriptions'], ['playstation', 'entertainment'], ['steam', 'entertainment'], ['xbox', 'entertainment'], ['nintendo', 'entertainment'],
  ['vox cinemas', 'entertainment'], ['vox', 'entertainment'], ['muvi', 'entertainment'], ['amc', 'entertainment'], ['webook', 'entertainment'],
  ['saudia', 'travel'], ['flynas', 'travel'], ['طيران ناس', 'travel'], ['flyadeal', 'travel'], ['almosafer', 'travel'], ['المسافر', 'travel'],
  ['booking', 'travel'], ['airbnb', 'travel'], ['agoda', 'travel'], ['expedia', 'travel'], ['marriott', 'travel'], ['hilton', 'travel'],
  ['hotel', 'travel'], ['فندق', 'travel'], ['emirates', 'travel'], ['haramain', 'travel'],
  ['nahdi', 'health'], ['النهدي', 'health'], ['al dawaa', 'health'], ['الدواء', 'health'], ['whites', 'health'], ['صيدلية', 'health'],
  ['pharmacy', 'health'], ['fitness time', 'health'], ['وقت اللياقة', 'health'], ['leejam', 'health'], ['hospital', 'health'], ['مستشفى', 'health'],
  ['clinic', 'health'], ['عيادة', 'health'], ['الحبيب', 'health'],
  ['stc', 'bills'], ['mobily', 'bills'], ['موبايلي', 'bills'], ['zain', 'bills'], ['زين', 'bills'], ['salam', 'bills'], ['saudi electricity', 'bills'],
  ['الكهرباء', 'bills'], ['nwc', 'bills'], ['المياه الوطنية', 'bills'], ['sadad', 'bills'], ['absher', 'bills'], ['أبشر', 'bills'], ['ejar', 'bills'],
  ['amazon', 'shopping'], ['أمازون', 'shopping'], ['noon', 'shopping'], ['نون', 'shopping'], ['namshi', 'shopping'], ['shein', 'shopping'],
  ['jarir', 'shopping'], ['جرير', 'shopping'], ['extra', 'shopping'], ['اكسترا', 'shopping'], ['ikea', 'shopping'], ['ايكيا', 'shopping'],
  ['h m', 'shopping'], ['zara', 'shopping'], ['centrepoint', 'shopping'], ['max fashion', 'shopping'], ['nike', 'shopping'], ['adidas', 'shopping'],
  ['apple store', 'shopping'], ['saco', 'shopping'], ['ساكو', 'shopping'], ['trendyol', 'shopping'], ['aliexpress', 'shopping'],
  ['barber', 'personal'], ['حلاق', 'personal'], ['salon', 'personal'], ['صالون', 'personal'], ['laundry', 'personal'],
];
const KEYWORDS = [
  ['coffee', ['coffee', 'cafe', 'café', 'قهوة', 'كافيه', 'كوفي', 'roastery', 'محمصة']],
  ['dining', ['restaurant', 'مطعم', 'مطاعم', 'grill', 'burger', 'pizza', 'shawarma', 'شاورما', 'kitchen', 'مشويات', 'bakery', 'مخبز', 'food']],
  ['groceries', ['market', 'ماركت', 'تموينات', 'بقالة', 'hyper', 'هايبر', 'grocery']],
  ['auto', ['fuel', 'petrol', 'station', 'محطة', 'وقود', 'بنزين', 'car wash', 'tyre', 'tire', 'كفرات', 'قطع غيار']],
  ['transport', ['taxi', 'تاكسي', 'parking', 'مواقف', 'metro', 'مترو']],
  ['travel', ['hotel', 'فندق', 'airline', 'airways', 'طيران', 'resort', 'منتجع']],
  ['health', ['pharma', 'صيدلية', 'صيدليات', 'hospital', 'مستشفى', 'clinic', 'عيادة', 'medical', 'طبي', 'dental', 'أسنان', 'gym', 'نادي', 'fitness']],
  ['bills', ['electricity', 'كهرباء', 'water', 'مياه', 'telecom', 'اتصالات', 'internet', 'انترنت', 'فاتورة', 'bill', 'insurance', 'تأمين']],
  ['entertainment', ['cinema', 'سينما', 'game', 'games', 'ألعاب', 'العاب', 'tickets', 'تذاكر', 'ملاهي']],
  ['shopping', ['fashion', 'أزياء', 'mall', 'مول', 'electronics', 'إلكترونيات', 'store', 'متجر', 'shoes', 'أحذية', 'عطور', 'perfume']],
  ['personal', ['salon', 'صالون', 'barber', 'حلاق', 'spa', 'سبا', 'laundry']],
  ['subscriptions', ['subscription', 'اشتراك', 'membership', 'عضوية', 'premium', 'apple', 'itunes', 'app store']],
];

export function categorize(tx, rules, settings = {}) {
  const by = (category, source, confidence) => ({ category, source, confidence });
  if (tx.internal) return by('internalTransfer', 'kind', 1);
  switch (tx.kind) {
    case 'income': return by('salary', 'kind', 1);
    case 'cashWithdrawal': return by('cash', 'kind', 1);
    case 'cardPayment': return by('internalTransfer', 'kind', 1);
    case 'cashDeposit': return by('otherIncome', 'kind', 0.6);
  }
  if (tx.kind === 'fee' && !tx.merchant) return by('bills', 'kind', 0.8);
  const key = tx.mkey || merchantKey(tx.merchant || tx.counterparty || tx.note || '');
  if (key && rules[key]) return by(rules[key], 'learned', 1);
  if ((tx.kind === 'transferOut' || tx.kind === 'transferIn') && relation(tx.counterparty, settings.ownerNames) === 'family')
    return by(tx.kind === 'transferOut' ? 'family' : 'allowance', 'family', 0.9);
  if (tx.kind === 'transferOut') return by('transfers', 'kind', 0.9);
  if (tx.kind === 'transferIn') return by('otherIncome', 'kind', 0.9);
  const padded = ` ${key} `;
  for (const [k, c] of DICT) if (key && padded.includes(` ${k} `)) return by(c, 'dictionary', 0.95);
  const lower = normDigits(`${tx.merchant || tx.counterparty || ''} ${tx.note || ''}`).toLowerCase();
  for (const [c, w] of KEYWORDS) if (has(lower, w)) return by(c, 'keyword', 0.75);
  if (tx.kind === 'billPayment') return by('bills', 'kind', 0.8);
  if (tx.direction === 'credit' && tx.kind !== 'refund') return by('otherIncome', 'kind', 0.5);
  return by('other', 'none', 0);
}

// ───────────────────────── Ledger ─────────────────────────
export function newState() {
  return { v: 1, parserVersion: PARSER_VERSION, log: [], ops: [], accounts: [], txs: [], balances: [], budgets: {}, rules: {}, seen: {}, templates: [], ignored: [],
    settings: { externalTransfersAsSpending: false, cashAsSpending: false, ownerNames: [], rulesVersion: 2 }, fired: {} };
}

const uid = () => (globalThis.crypto?.randomUUID?.() || 'id-' + Math.random().toString(36).slice(2) + Date.now().toString(36));

function resolveAccount(state, rec) {
  if (rec.accountId) return rec.accountId;
  const act = state.accounts.filter(a => !a.archived);
  if (rec.card) { const a = act.find(a => a.cards.includes(rec.card)); if (a) return a.id; }
  if (rec.acct) { const a = act.find(a => a.numbers.includes(rec.acct)); if (a) return a.id; }
  if (rec.walletCard) {
    const w = rec.walletCard.toLowerCase();
    const a = act.find(a => a.walletNames.some(n => n && (w.includes(n.toLowerCase()) || n.toLowerCase().includes(w))));
    if (a) return a.id;
  }
  if (rec.hint) {
    const m = act.filter(a => a.senders.some(s => s.toLowerCase() === rec.hint.toLowerCase()));
    if (m.length === 1) return m[0].id;
  }
  if (rec.inst) {
    const names = { snb: ['snb', 'الأهلي', 'الاهلي', 'alahli', 'ncb'], barq: ['barq', 'برق'], d360: ['d360', 'd 360'] }[rec.inst] || [];
    const m = act.filter(a => a.institution === rec.inst || names.some(n => a.name.toLowerCase().includes(n)));
    if (m.length === 1) return m[0].id;
  }
  return null;
}

function addBalance(state, accountId, balance, ts, source) {
  if (state.balances.some(b => b.accountId === accountId && b.ts === ts && b.balance === balance)) return false;
  state.balances.push({ accountId, balance, ts, source });
  return true;
}

export const latestBalance = (state, id) => state.balances.filter(b => b.accountId === id).sort((a, b) => b.ts - a.ts)[0] || null;

function makeTx(state, r, now) {
  const review = [];
  if (!r.amount) review.push('missingAmount');
  if (!r.direction) review.push('unknownDirection');
  const currency = (r.currency || 'SAR').toUpperCase();
  let base = r.base ?? (currency === 'SAR' ? r.amount : null);
  if (base == null && r.amount) review.push('missingBaseAmount');
  if ((r.confidence ?? 1) < 0.5) review.push('lowConfidence');
  const tx = { id: uid(), amount: Math.abs(r.amount || 0), currency, base: base == null ? null : Math.abs(base),
    direction: r.direction || 'debit', kind: r.kind || 'unknown', status: r.status || 'completed', ts: r.ts ?? now, hasTime: !!r.hasTime,
    merchant: r.merchant || null, mkey: (r.merchant || r.counterparty) ? merchantKey(r.merchant || r.counterparty) : null,
    counterparty: r.counterparty || null, accountId: resolveAccount(state, r), card: r.card || null, acct: r.acct || null,
    cpAcct: r.cpAcct || null, ref: r.ref || null, note: r.note || null, sources: [{ type: r.source, id: r.id, at: now }],
    category: 'other', catSource: 'none', catConf: 0, internal: false, link: null, review, excluded: false, created: now, ai: r.ai || null };
  if (r.category) { tx.category = r.category; tx.catSource = 'user'; tx.catConf = 1; }
  return tx;
}

function dupScore(a, b, pendingUpgrade) {
  const sameOrig = a.currency === b.currency && a.amount === b.amount;
  const sameBase = a.base != null && a.base === b.base;
  if (!sameOrig && !sameBase) return null;
  if (a.accountId && b.accountId && a.accountId !== b.accountId) return null;
  if (a.card && b.card && a.card !== b.card) return null;
  if (a.ref && b.ref) return a.ref === b.ref ? 1 : null;
  let s = 0;
  const dt = Math.abs(a.ts - b.ts);
  if (a.hasTime && b.hasTime) {
    if (dt <= 15 * 60e3) s += 0.45; else if (dt <= 3 * 3600e3) s += 0.2;
    else if (pendingUpgrade && dt <= 5 * 864e5) s += 0.2; else return null;
  } else {
    if (dt > 4.5 * 864e5) return null;
    s += dt <= 36 * 3600e3 ? 0.3 : 0.15;
  }
  const na = a.merchant || a.counterparty || a.note, nb = b.merchant || b.counterparty || b.note;
  const sim = similarity(na, nb);
  if (sim >= 0.5) s += 0.4;
  else if (!(a.merchant || a.counterparty) || !(b.merchant || b.counterparty)) s += 0.1;
  else if (sim < 0.2) s -= 0.3;
  if (a.accountId && a.accountId === b.accountId) s += 0.15;
  if (a.card && a.card === b.card) s += 0.15;
  if (a.kind === b.kind) s += 0.05;
  return s;
}

function findDuplicate(state, tx) {
  const src = tx.sources[0].type;
  const scored = [];
  state.txs.forEach((c, i) => {
    if (c.direction !== tx.direction || c.kind === 'reversal' || c.status === 'reversed' || c.excluded) return;
    const up = c.status === 'pending' && tx.status === 'completed';
    if (c.sources.some(s => s.type === src) && !up) return;
    const s = dupScore(c, tx, up);
    if (s !== null) scored.push([i, s]);
  });
  if (!scored.length) return null;
  const best = scored.reduce((a, b) => (b[1] > a[1] ? b : a));
  const rivals = scored.filter(x => x[0] !== best[0] && x[1] > best[1] - 0.2);
  if (best[1] >= 0.6 && !rivals.length) return { match: best[0] };
  if (best[1] >= 0.3) return { ambiguous: state.txs[best[0]].id };
  return null;
}

function merge(state, inc, i) {
  const t = state.txs[i];
  t.sources.push(...inc.sources);
  if (t.status === 'pending' && inc.status === 'completed') { t.status = 'completed'; if (inc.base != null) t.base = inc.base; }
  if (t.base == null && inc.base != null) { t.base = inc.base; t.review = t.review.filter(r => r !== 'missingBaseAmount'); }
  if (!t.merchant && inc.merchant) { t.merchant = inc.merchant; t.mkey = inc.mkey; }
  if (!t.hasTime && inc.hasTime) { t.ts = inc.ts; t.hasTime = true; }
  for (const k of ['accountId', 'card', 'acct', 'ref', 'counterparty', 'cpAcct']) t[k] = t[k] || inc[k];
  if (t.kind === 'unknown') t.kind = inc.kind;
  if (t.catSource === 'none' || (t.catConf < 0.75 && !['user', 'learned'].includes(t.catSource))) applyCategory(state, t);
}

function applyCategory(state, t) {
  let d = categorize(t, state.rules, state.settings);
  if (t.ai && d.confidence < 0.8 && t.direction === 'debit' && !t.internal && isExpenseCat(t.ai)
      && !['transferOut', 'transferIn', 'cashWithdrawal', 'cardPayment', 'fee'].includes(t.kind))
    d = { category: t.ai, source: 'ai', confidence: 0.7 };
  t.category = d.category; t.catSource = d.source; t.catConf = d.confidence;
}

function findReversalTarget(state, tx) {
  const cands = state.txs.filter(c => c.status !== 'reversed' && c.kind !== 'reversal' && c.ts <= tx.ts + 3600e3 && tx.ts - c.ts <= 45 * 864e5
    && ((c.currency === tx.currency && c.amount === tx.amount) || (c.base != null && c.base === tx.base))
    && !(c.accountId && tx.accountId && c.accountId !== tx.accountId) && !(c.card && tx.card && c.card !== tx.card)
    && !(tx.merchant && c.merchant && similarity(c.merchant, tx.merchant) < 0.3));
  if (!cands.length) return null;
  if (!tx.merchant && new Set(cands.map(c => c.mkey)).size > 1) return null;
  return cands.sort((a, b) => b.ts - a.ts)[0];
}

function findRefundTarget(state, tx) {
  if (!tx.merchant || tx.base == null) return null;
  return state.txs.filter(c => c.direction === 'debit' && ['purchase', 'billPayment'].includes(c.kind) && c.status !== 'reversed'
    && c.ts <= tx.ts && tx.ts - c.ts <= 180 * 864e5 && (c.base || 0) >= tx.base && similarity(c.merchant, tx.merchant) >= 0.5)
    .sort((a, b) => b.ts - a.ts)[0] || null;
}

const INST_NAMES = { snb: ['snb', 'alahli', 'الأهلي', 'الاهلي', 'ncb'], barq: ['barq', 'برق'], d360: ['d360', 'd 360'] };

/** Card purchase whose merchant is one of the user's own wallets/banks (e.g. "MYSR D360", "barq"). */
function isWalletTopup(state, t) {
  if (t.kind !== 'purchase' || t.direction !== 'debit' || !t.merchant) return false;
  const raw = normDigits(t.merchant).toLowerCase();
  return state.accounts.some(a => !a.archived && a.id !== t.accountId && a.type !== 'cash' && a.type !== 'creditCard'
    && [a.name.toLowerCase(), ...(INST_NAMES[a.institution] || [])].some(n => n && n.length >= 3 && new RegExp(`(^|[^\\p{L}\\d])${n.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}($|[^\\p{L}\\d])`, 'u').test(raw)));
}

const numbersOf = (state, id) => { const a = state.accounts.find(x => x.id === id); return a ? [...a.cards, ...a.numbers] : []; };
function isPair(state, debit, credit) {
  if (!['transferIn', 'unknown', 'cardPayment', 'cashDeposit'].includes(credit.kind)) return false;
  if (credit.cpAcct && (credit.cpAcct === debit.card || numbersOf(state, debit.accountId).includes(credit.cpAcct))) return true;
  if (debit.cpAcct && numbersOf(state, credit.accountId).includes(debit.cpAcct)) return true;
  if (['transferOut', 'unknown'].includes(debit.kind)) return true;
  if (debit.kind === 'cardPayment') return state.accounts.find(a => a.id === credit.accountId)?.type === 'creditCard' || credit.kind === 'cardPayment';
  if (debit.kind === 'purchase') {
    const recv = state.accounts.find(a => a.id === credit.accountId);
    if (!recv || !debit.merchant) return false;
    const raw = normDigits(debit.merchant).toLowerCase();
    const names = [recv.name.toLowerCase(), ...(INST_NAMES[recv.institution] || [])];
    return names.some(n => n && raw.includes(n));
  }
  return false;
}

function matchInternal(state, tx) {
  const owned = new Set(state.accounts.filter(a => a.id !== tx.accountId).flatMap(a => [...a.cards, ...a.numbers]));
  if (tx.cpAcct && owned.has(tx.cpAcct) && tx.kind !== 'purchase') tx.internal = true;
  if (tx.base == null) return false;
  const opp = tx.direction === 'debit' ? 'credit' : 'debit';
  const cands = state.txs.filter(c => c.direction === opp && !c.link && c.base === tx.base && c.status !== 'reversed'
    && (!c.review.length || (c.review.length === 1 && c.review[0] === 'possibleInternal'))
    && c.accountId && tx.accountId && c.accountId !== tx.accountId
    && Math.abs(c.ts - tx.ts) <= ((c.hasTime && tx.hasTime) ? 6 * 3600e3 : 3 * 864e5)
    && (tx.direction === 'debit' ? isPair(state, tx, c) : isPair(state, c, tx)));
  const best = cands.sort((a, b) => Math.abs(a.ts - tx.ts) - Math.abs(b.ts - tx.ts))[0];
  if (best) {
    Object.assign(best, { internal: true, link: tx.id, category: 'internalTransfer', catSource: 'kind' });
    best.review = best.review.filter(r => r !== 'possibleInternal');
    Object.assign(tx, { internal: true, link: best.id, category: 'internalTransfer', catSource: 'kind' });
    return true;
  }
  if (!tx.internal && isWalletTopup(state, tx)) tx.internal = true;
  if (tx.internal) { tx.category = 'internalTransfer'; tx.catSource = 'kind'; return false; }
  if (['transferOut', 'transferIn'].includes(tx.kind) && tx.counterparty
      && state.settings.ownerNames.some(n => n && tx.counterparty.toLowerCase().includes(n.toLowerCase()))) tx.review.push('possibleInternal');
  return false;
}

/** Ingest parse outcomes / records. Mutates state. Returns a report. */
export function ingest(state, items, now = Date.now()) {
  const rep = { added: [], merged: [], dup: 0, review: [], ignored: 0, unparseable: 0, balances: 0, internal: 0 };
  const recs = [];
  for (const it of items) {
    if (it.type === 'record') recs.push(it.rec);
    else if (it.type === 'ignored') { rep.ignored++; state.ignored.push({ ts: now, reason: it.reason }); }
    else if (it.type === 'unparseable') rep.unparseable++;
    else if (it.type === 'balance') {
      const id = resolveAccount(state, { card: it.card, acct: it.acct, hint: it.hint, inst: it.inst });
      if (id && addBalance(state, id, it.balance, it.ts, 'sms')) rep.balances++;
    } else if (it.id && it.source) recs.push(it);
  }
  if (state.ignored.length > 300) state.ignored.splice(0, state.ignored.length - 300);
  recs.sort((a, b) => (a.ts ?? now) - (b.ts ?? now));
  for (const r of recs) {
    if (state.seen[r.id]) { rep.dup++; continue; }
    state.seen[r.id] = 1;
    const tx = makeTx(state, r, now);
    if (r.balance != null && tx.accountId && addBalance(state, tx.accountId, r.balance, tx.ts, r.source)) rep.balances++;

    if (tx.kind === 'reversal') {
      const o = findReversalTarget(state, tx);
      if (o) { o.status = 'reversed'; tx.link = o.id; tx.status = 'reversed'; tx.category = o.category; }
      else tx.review.push('unmatchedReversal');
      state.txs.push(tx); rep.added.push(tx.id); if (tx.review.length) rep.review.push(tx.id);
      continue;
    }
    if (!tx.review.length || (tx.review.length === 1 && tx.review[0] === 'lowConfidence')) {
      const d = findDuplicate(state, tx);
      if (d?.match !== undefined) { merge(state, tx, d.match); rep.merged.push(state.txs[d.match].id); continue; }
      if (d?.ambiguous) { tx.review.push('possibleDuplicate'); tx.link = d.ambiguous; }
    }
    if (tx.kind === 'refund') {
      const o = findRefundTarget(state, tx);
      if (o) { tx.link = o.id; tx.category = o.category; tx.catSource = o.catSource; tx.catConf = o.catConf; if (tx.base >= o.base) o.status = 'refunded'; }
    }
    if (['transferOut', 'transferIn', 'cardPayment', 'purchase', 'cashDeposit', 'unknown'].includes(tx.kind) && matchInternal(state, tx)) rep.internal++;
    if (tx.kind === 'cardPayment' && !tx.internal) {
      if (state.accounts.some(a => a.type === 'creditCard' && a.tracked && !a.archived) || tx.direction === 'credit') tx.internal = true;
      else tx.review.push('cardPaymentUntracked');
    }
    if (tx.catSource === 'none') applyCategory(state, tx);
    state.txs.push(tx); rep.added.push(tx.id); if (tx.review.length) rep.review.push(tx.id);
  }
  return rep;
}

// ───────────────────────── History (self-healing) ─────────────────────────
// state.log  = every raw input ever received (SMS text, statement rows, manual entries)
// state.ops  = every user correction, keyed by the transaction's first source id
// When PARSER_VERSION changes, transactions are rebuilt from the log and corrections are replayed.

/** Ingest and remember the raw inputs. Use this instead of ingest() for new data. */
export function record(state, items, now = Date.now()) {
  state.log ||= [];
  // Recovery: a message that was ingested before raw text was kept, received again (e.g. pasted) →
  // store its text and rebuild, so the old transaction is re-read with the current rules.
  const loggedSms = new Set(state.log.filter(e => e.k === 'sms').map(e => smsSourceId(e.text)));
  let recovered = 0;
  for (const it of items) {
    if (it.src?.k !== 'sms') continue;
    const id = smsSourceId(it.src.text);
    if (state.seen[id] && !loggedSms.has(id)) {
      state.log = state.log.filter(e => !(e.k === 'tx' && e.tx.sources.some(x => x.id === id)));
      state.log.push(it.src); loggedSms.add(id); recovered++;
    }
  }
  if (recovered) {
    items = items.filter(it => !(it.src?.k === 'sms' && loggedSms.has(smsSourceId(it.src.text)) && state.seen[smsSourceId(it.src.text)]));
    rebuild(state, now);
    refreshCategories(state);
  }
  for (const it of items) {
    if (it.src) state.log.push(it.src);
    else if (it.type === 'record') state.log.push({ k: 'rec', rec: it.rec });
    else if (it.id && it.source) state.log.push({ k: 'rec', rec: it });
  }
  const rep = ingest(state, items, now);
  rep.recovered = recovered;
  return rep;
}

function applyOp(state, t, op) {
  switch (op.op) {
    case 'cat': recategorize(state, t.id, op.category, op.learn); break;
    case 'resolve': resolve(state, t.id, op.action, op.data || {}); break;
    case 'exclude': t.excluded = !!op.value; break;
    case 'delete': deleteTx(state, t.id); break;
  }
}

/** A user correction. It is applied now and replayed after every rebuild. */
export function userOp(state, id, op) {
  const t = state.txs.find(x => x.id === id);
  if (!t) return;
  const src = t.sources[0]?.id;
  applyOp(state, t, op);
  if (src) (state.ops ||= []).push({ ...op, src });
}

function legacyFixes(state) {
  for (const t of state.txs) {
    if (['user', 'learned'].includes(t.catSource) || t.internal) continue;
    if (isWalletTopup(state, t)) Object.assign(t, { internal: true, category: 'internalTransfer', catSource: 'kind' });
  }
  // Old wallet "add money" messages were read as a second purchase: same card + amount within 3 minutes of a top-up.
  for (const t of state.txs) {
    if (t.internal || t.merchant || t.kind !== 'purchase' || ['user', 'learned'].includes(t.catSource)) continue;
    const twin = state.txs.find(o => o !== t && o.internal && o.direction === 'debit' && o.base === t.base && o.card && o.card === t.card && Math.abs(o.ts - t.ts) <= 3 * 60e3);
    if (twin) Object.assign(t, { internal: true, category: 'internalTransfer', catSource: 'kind', link: twin.id });
  }
}

/** Re-process the whole history with the current parser and replay the user's corrections. */
export function rebuild(state, now = Date.now()) {
  const log = state.log || [];
  state.txs = []; state.seen = {}; state.ignored = [];
  state.balances = state.balances.filter(b => b.source === 'manual');
  for (const e of log) if (e.k === 'tx') { const t = JSON.parse(JSON.stringify(e.tx)); state.txs.push(t); for (const s of t.sources) state.seen[s.id] = 1; }
  const items = log.filter(e => e.k !== 'tx').map(e => (e.k === 'sms' ? parseSMS(e.text, e.sender, e.ts, state.templates, e.ai) : { type: 'record', rec: e.rec }));
  ingest(state, items, now);
  legacyFixes(state);
  for (const op of state.ops || []) {
    const t = state.txs.find(x => x.sources.some(s => s.id === op.src));
    if (t) applyOp(state, t, op);
  }
  state.parserVersion = PARSER_VERSION;
}

/** Source id an SMS log entry produces (must match parseSMS). */
const smsSourceId = text => 'sms:' + fnv1a(normDigits(text).trim());

/** Safety invariant: every current transaction is reproducible from the log. Transactions whose
 *  sources are not covered (received before history was kept) are stored verbatim. */
function ensureLogCoversTxs(state) {
  state.log ||= [];
  state.ops ||= [];
  const covered = new Set();
  for (const e of state.log) {
    if (e.k === 'sms') covered.add(smsSourceId(e.text));
    else if (e.k === 'rec') covered.add(e.rec.id);
    else if (e.k === 'tx') for (const s of e.tx.sources) covered.add(s.id);
  }
  const legacy = state.txs.filter(t => !t.sources.some(s => covered.has(s.id))).map(t => ({ k: 'tx', tx: JSON.parse(JSON.stringify(t)) }));
  if (legacy.length) state.log.unshift(...legacy);
  return legacy.length > 0;
}

/** Bring saved data up to date. Returns true if it changed. Never drops a transaction. */
export function upgrade(state) {
  let changed = migrate(state);
  if (ensureLogCoversTxs(state)) changed = true;
  if (state.parserVersion !== PARSER_VERSION) {
    const before = state.txs.length;
    const snapshot = JSON.stringify({ txs: state.txs, balances: state.balances, seen: state.seen, ignored: state.ignored });
    rebuild(state);
    // Merging can reduce the count slightly; a large drop means something is wrong → keep the old data.
    if (state.txs.length < before * 0.8) Object.assign(state, JSON.parse(snapshot));
    state.parserVersion = PARSER_VERSION;
    changed = true;
  }
  return changed;
}

/** Re-check all transactions with the current rules (button in settings). */
export function reprocess(state) {
  ensureLogCoversTxs(state);
  const before = state.txs.length;
  const snapshot = JSON.stringify({ txs: state.txs, balances: state.balances, seen: state.seen, ignored: state.ignored });
  rebuild(state);
  if (state.txs.length < before * 0.8) { Object.assign(state, JSON.parse(snapshot)); return false; }
  refreshCategories(state);
  return true;
}

/** One-time rule migrations for saved data. Returns true if anything changed. */
export function migrate(state) {
  const s = state.settings;
  if ((s.rulesVersion || 1) < 2) { s.externalTransfersAsSpending = false; s.rulesVersion = 2; return true; }
  return false;
}

export function refreshCategories(state) {
  let n = 0;
  for (const t of state.txs) {
    if (['user', 'learned'].includes(t.catSource) || t.internal) continue;
    const before = t.category;
    applyCategory(state, t);
    if (t.category !== before) n++;
  }
  return n;
}

export function recategorize(state, id, category, learn = true) {
  const t = state.txs.find(x => x.id === id); if (!t) return;
  Object.assign(t, { category, catSource: 'user', catConf: 1 });
  if (category === 'internalTransfer') t.internal = true;
  if (!learn || !t.mkey) return;
  state.rules[t.mkey] = category;
  for (const o of state.txs) if (o.mkey === t.mkey && o.catSource !== 'user' && !o.internal) Object.assign(o, { category, catSource: 'learned', catConf: 1 });
}

export function deleteTx(state, id) {
  const t = state.txs.find(x => x.id === id); if (!t) return;
  for (const o of state.txs) if (o.link === id) {
    o.link = null;
    if (t.kind === 'reversal') o.status = 'completed';
    if (t.internal && o.internal && !o.cpAcct) { o.internal = false; applyCategory(state, o); }
  }
  state.txs = state.txs.filter(x => x.id !== id);
}

/** action: confirm{amount?,base?,direction?} | merge | internal | cardExpense | keepExcluded | delete */
export function resolve(state, id, action, data = {}) {
  const t = state.txs.find(x => x.id === id); if (!t) return;
  switch (action) {
    case 'confirm':
      if (data.amount) { t.amount = data.amount; if (t.currency === 'SAR') t.base = data.amount; }
      if (data.base) t.base = data.base;
      if (data.direction) t.direction = data.direction;
      if (!t.amount || t.base == null) return;
      if (t.review.includes('possibleDuplicate')) t.link = null;
      t.review = [];
      if (t.catSource === 'none') applyCategory(state, t);
      break;
    case 'merge': {
      const i = state.txs.findIndex(x => x.id === t.link); if (i < 0) return;
      t.review = []; merge(state, t, i); state.txs = state.txs.filter(x => x.id !== id); break;
    }
    case 'internal': Object.assign(t, { internal: true, category: 'internalTransfer', catSource: 'user', review: [] }); break;
    case 'cardExpense': Object.assign(t, { kind: 'billPayment', internal: false, review: [], category: 'bills', catSource: 'user' }); break;
    case 'keepExcluded': Object.assign(t, { review: [], excluded: true }); break;
    case 'delete': deleteTx(state, id); break;
  }
}

// ───────────────────────── Accounting rules ─────────────────────────
/** The ONLY place that decides how a transaction affects totals. */
export function effect(state, t) {
  if (t.excluded || t.status === 'reversed' || t.kind === 'reversal') return { type: 'excluded' };
  if (t.review.length) return { type: 'unconfirmed', amount: t.base || 0 };
  if (t.base == null) return { type: 'unconfirmed', amount: 0 };
  const a = t.base;
  if (t.status === 'pending') return { type: 'pending', amount: a };
  if (t.internal || t.category === 'internalTransfer' || t.kind === 'cardPayment') return { type: 'internal' };
  const userCat = ['user', 'learned'].includes(t.catSource);
  if (t.direction === 'debit') {
    if (t.kind === 'cashWithdrawal') return state.settings.cashAsSpending ? { type: 'expense', amount: a, category: 'cash' } : { type: 'cash', amount: a };
    if (t.kind === 'transferOut') {
      // Family transfers and transfers the user categorised are spending; other transfers are shown but not counted (setting).
      if (t.category === 'family' || (userCat && isExpenseCat(t.category)) || state.settings.externalTransfersAsSpending)
        return { type: 'expense', amount: a, category: isExpenseCat(t.category) ? t.category : 'transfers' };
      return { type: 'transferOut', amount: a };
    }
    return { type: 'expense', amount: a, category: isExpenseCat(t.category) ? t.category : 'other' };
  }
  if (t.kind === 'refund') return { type: 'refund', amount: a, category: isExpenseCat(t.category) ? t.category : 'other' };
  if (t.kind === 'income') return { type: 'income', amount: a, category: isIncomeCat(t.category) ? t.category : 'salary' };
  if ((userCat || t.catSource === 'family') && isIncomeCat(t.category)) return { type: 'income', amount: a, category: t.category };
  if (userCat && isExpenseCat(t.category)) return { type: 'refund', amount: a, category: t.category };
  return { type: 'transferIn', amount: a };
}

// ───────────────────────── Periods ─────────────────────────
export function period(kind, ts) {
  const p = riyadhParts(ts);
  if (kind === 'day') { const s = riyadhTs(p.y, p.m, p.d, 0); return [s, s + 864e5]; }
  if (kind === 'week') { const s = riyadhTs(p.y, p.m, p.d - p.wd, 0); return [s, s + 7 * 864e5]; } // week starts Sunday
  if (kind === 'month') return [riyadhTs(p.y, p.m, 1, 0), riyadhTs(p.y, p.m + 1, 1, 0)];
  return [riyadhTs(p.y, 1, 1, 0), riyadhTs(p.y + 1, 1, 1, 0)];
}
export const prevPeriod = (kind, ts) => period(kind, period(kind, ts)[0] - 1);
export function lastDays(n, now) { const s = startOfDay(now); return [s - (n - 1) * 864e5, s + 864e5]; }

export function summary(state, [start, end], now = Date.now(), filter = {}) {
  const s = { start, end, spending: 0, gross: 0, refunds: 0, income: 0, transfersIn: 0, transfersOut: 0, cash: 0, pending: 0, pendingCount: 0,
    unconfirmed: 0, unconfirmedCount: 0, internalCount: 0, count: 0, expenseCount: 0, byCategory: [], byMerchant: [], dailyAvg: 0 };
  const cat = {}, mer = {};
  for (const t of state.txs) {
    if (t.ts < start || t.ts >= end) continue;
    if (filter.accountId && t.accountId !== filter.accountId) continue;
    if (filter.mkey && !(t.mkey || '').includes(filter.mkey)) continue;
    const e = effect(state, t);
    if (filter.category && !((e.type === 'expense' || e.type === 'refund') && e.category === filter.category)) continue;
    const name = t.merchant || t.counterparty || catName(t.category);
    const key = t.mkey || name;
    switch (e.type) {
      case 'expense':
        s.gross += e.amount; s.count++; s.expenseCount++;
        (cat[e.category] ??= { category: e.category, amount: 0, count: 0 }).amount += e.amount; cat[e.category].count++;
        (mer[key] ??= { key, name, amount: 0, count: 0 }).amount += e.amount; mer[key].count++;
        break;
      case 'refund':
        s.refunds += e.amount; s.count++;
        (cat[e.category] ??= { category: e.category, amount: 0, count: 0 }).amount -= e.amount;
        if (mer[key]) mer[key].amount -= e.amount;
        break;
      case 'income': s.income += e.amount; s.count++; break;
      case 'transferIn': s.transfersIn += e.amount; s.count++; break;
      case 'transferOut': s.transfersOut += e.amount; s.count++; break;
      case 'cash': s.cash += e.amount; s.count++; break;
      case 'internal': s.internalCount++; break;
      case 'pending': if (t.direction === 'debit') s.pending += e.amount; s.pendingCount++; break;
      case 'unconfirmed': s.unconfirmed += e.amount; s.unconfirmedCount++; break;
    }
  }
  s.spending = s.gross - s.refunds;
  s.net = s.income - s.spending;
  s.byCategory = Object.values(cat).filter(c => c.amount !== 0).sort((a, b) => b.amount - a.amount);
  s.byMerchant = Object.values(mer).filter(m => m.amount > 0).sort((a, b) => b.amount - a.amount);
  const days = Math.max(1, Math.ceil((Math.min(end, Math.max(start, now)) - start) / 864e5));
  s.dailyAvg = Math.round(s.spending / days);
  return s;
}

export function dashboard(state, now = Date.now()) {
  const month = period('month', now);
  const prev = prevPeriod('month', now);
  const prevToDate = [prev[0], Math.min(prev[1], prev[0] + (now - month[0]))];
  const m = summary(state, month, now), p = summary(state, prevToDate, now);
  const balances = state.accounts.filter(a => !a.archived).map(a => ({ account: a, latest: latestBalance(state, a.id) }));
  const total = balances.reduce((acc, b) => (b.latest ? acc + (b.account.type === 'creditCard' ? -Math.abs(b.latest.balance) : b.latest.balance) : acc), 0);
  return { today: summary(state, period('day', now), now), week: summary(state, period('week', now), now), month: m,
    year: summary(state, period('year', now), now), prevToDate: p, balances, total,
    reviewCount: state.txs.filter(t => t.review.length).length, change: p.spending ? (m.spending - p.spending) / p.spending : null };
}

export function monthlySeries(state, n, now = Date.now()) {
  const out = []; let cur = period('month', now);
  for (let i = 0; i < n; i++) { out.unshift(summary(state, cur, now)); cur = period('month', cur[0] - 1); }
  return out;
}

// ───────────────────────── Budgets ─────────────────────────
export const THRESHOLDS = [50, 75, 90, 100];
export function budgetStatus(state, now = Date.now()) {
  const m = summary(state, period('month', now), now);
  return Object.entries(state.budgets).filter(([, l]) => l > 0).map(([category, limit]) => {
    const spent = m.byCategory.find(c => c.category === category)?.amount || 0;
    const ratio = spent / limit;
    const crossed = THRESHOLDS.filter(t => ratio * 100 >= t).pop() ?? null;
    return { category, limit, spent, remaining: limit - spent, ratio, crossed };
  }).sort((a, b) => b.ratio - a.ratio);
}

export function suggestBudgets(state, now = Date.now()) {
  const months = []; let cur = prevPeriod('month', now);
  for (let i = 0; i < 3; i++) { months.push(summary(state, cur, now)); cur = prevPeriod('month', cur[0]); }
  const out = {};
  for (const c of EXPENSE_CATEGORIES) {
    if (c === 'transfers' || c === 'cash') continue;
    const vals = months.map(m => m.byCategory.find(x => x.category === c)?.amount || 0).sort((a, b) => a - b);
    if (vals[1] > 0) out[c] = Math.ceil(vals[1] / 5000) * 5000;
  }
  return out;
}

// ───────────────────────── Recurring ─────────────────────────
const CADENCE = { weekly: [7, 1.5, 'أسبوعي'], monthly: [30.44, 4, 'شهري'], quarterly: [91.3, 8, 'ربع سنوي'], yearly: [365.25, 12, 'سنوي'] };
export function recurring(state, now = Date.now()) {
  const groups = {};
  for (const t of state.txs) if (t.mkey && effect(state, t).type === 'expense') (groups[t.mkey] ??= []).push(t);
  const out = [];
  for (const [key, txs] of Object.entries(groups)) {
    const clusters = [];
    for (const t of txs.sort((a, b) => a.ts - b.ts)) {
      const c = clusters.find(c => { const ref = c[c.length - 1].base; return ref > 0 && Math.abs(t.base - ref) / ref <= 0.07; });
      c ? c.push(t) : clusters.push([t]);
    }
    const known = DICT.some(([k, c]) => c === 'subscriptions' && ` ${key} `.includes(` ${k} `));
    for (const c of clusters) {
      if (c.length < (known ? 2 : 3)) continue;
      const gaps = c.slice(1).map((t, i) => (t.ts - c[i].ts) / 864e5);
      const med = [...gaps].sort((a, b) => a - b)[Math.floor(gaps.length / 2)];
      const cad = Object.entries(CADENCE).find(([, [d, tol]]) => Math.abs(med - d) <= tol);
      if (!cad) continue;
      const [cname, [days, tol, label]] = cad;
      const regularity = gaps.filter(g => Math.abs(g - days) <= tol * 1.5).length / gaps.length;
      if (regularity < 0.6) continue;
      const last = c[c.length - 1];
      const step = ts => { const p = riyadhParts(ts);
        if (cname === 'weekly') return ts + 7 * 864e5;
        const add = cname === 'monthly' ? 1 : cname === 'quarterly' ? 3 : 12;
        return riyadhTs(p.y, p.m + add, p.d, p.h, p.min); };
      let next = step(last.ts);
      if ((now - next) / 864e5 > days * 1.5) continue;
      while (next < startOfDay(now)) next = step(next);
      const recent = c.slice(-3);
      out.push({ key, name: last.merchant || key, category: last.category, cadence: cname, label, next,
        expected: Math.round(recent.reduce((s, t) => s + t.base, 0) / recent.length), count: c.length,
        confidence: Math.min(1, (0.4 + 0.15 * c.length) * regularity + (known ? 0.2 : 0)) });
    }
  }
  return out.sort((a, b) => a.next - b.next);
}
export const monthlyCost = list => Math.round(list.reduce((s, r) => s + r.expected * ({ weekly: 52 / 12, monthly: 1, quarterly: 1 / 3, yearly: 1 / 12 }[r.cadence]), 0));

// ───────────────────────── Anomalies & alerts ─────────────────────────
export function anomaly(state, t) {
  const e = effect(state, t);
  if (e.type !== 'expense') return null;
  const hist = state.txs.filter(o => o.id !== t.id && o.ts < t.ts).map(o => [o, effect(state, o)]).filter(([, x]) => x.type === 'expense');
  const robust = v => { const s = [...v].sort((a, b) => a - b), med = s[Math.floor(s.length / 2)];
    const dev = s.map(x => Math.abs(x - med)).sort((a, b) => a - b); return [med, dev[Math.floor(dev.length / 2)]]; };
  const mh = hist.filter(([o]) => o.mkey && o.mkey === t.mkey).map(([, x]) => x.amount);
  if (mh.length >= 4) { const [med, mad] = robust(mh); return e.amount > med + Math.max(mad * 5, med * 2) ? { reason: `أعلى بكثير من المعتاد لدى ${t.merchant}`, typical: med } : null; }
  const ch = hist.filter(([, x]) => x.category === e.category).map(([, x]) => x.amount);
  if (ch.length >= 8) { const [med, mad] = robust(ch); if (e.amount > med + Math.max(mad * 8, med * 4) && e.amount >= 20000) return { reason: `مصروف كبير غير معتاد في ${catName(e.category)}`, typical: med }; }
  else if (!mh.length && e.amount >= 200000) return { reason: 'مبلغ كبير لدى جهة جديدة', typical: null };
  return null;
}

export function alerts(state, now = Date.now(), newIds = []) {
  const out = [];
  for (const id of newIds) {
    const t = state.txs.find(x => x.id === id); if (!t) continue;
    if (t.review.includes('possibleDuplicate')) out.push({ id: 'dup:' + id, title: 'عملية قد تكون مكررة', body: `${sar(t.base ?? t.amount)} – ${t.merchant || ''}` });
    else if (t.review.length) out.push({ id: 'rev:' + id, title: 'عملية تحتاج مراجعة', body: t.review.map(r => REVIEW_TEXT[r]).join('، ') });
    const an = anomaly(state, t);
    if (an) out.push({ id: 'unusual:' + id, title: 'عملية غير معتادة', body: `${an.reason}: ${sar(t.base)}` });
  }
  const mk = (() => { const p = riyadhParts(now); return `${p.y}-${p.m}`; })();
  for (const b of budgetStatus(state, now)) if (b.crossed) out.push({ id: `budget:${mk}:${b.category}:${b.crossed}`, title: 'تنبيه الميزانية',
    body: b.crossed >= 100 ? `تجاوزت ميزانية ${catName(b.category)}: ${sar(b.spent)} من ${sar(b.limit)}` : `استهلكت ${b.crossed}% من ميزانية ${catName(b.category)}. المتبقي ${sar(b.remaining)}` });
  for (const r of recurring(state, now)) if (r.confidence >= 0.5 && r.next - now <= 2 * 864e5)
    out.push({ id: `upcoming:${r.key}:${fmtDate(r.next, false)}`, title: `خصم قادم: ${r.name}`, body: `${sar(r.expected)} بتاريخ ${fmtDate(r.next, false)}` });
  for (const a of state.accounts.filter(a => !a.archived)) {
    const lb = latestBalance(state, a.id);
    if (a.lowBalance && lb && lb.balance < a.lowBalance) out.push({ id: `low:${a.id}:${lb.ts}`, title: 'رصيد منخفض', body: `${a.name}: ${sar(lb.balance)}` });
    const last = Math.max(lb?.ts || 0, ...state.txs.filter(t => t.accountId === a.id).map(t => t.created));
    if (last && now - last >= 7 * 864e5) out.push({ id: `stale:${a.id}:${Math.floor(now / (7 * 864e5))}`, title: 'حساب لم يُحدّث', body: `لا بيانات جديدة من ${a.name} منذ ${Math.floor((now - last) / 864e5)} يوم` });
  }
  return out.filter(a => !state.fired[a.id]);
}

// ───────────────────────── Formatting ─────────────────────────
export function sar(h, decimals = true) {
  const neg = h < 0; h = Math.abs(Math.round(h));
  const whole = Math.floor(h / 100).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  return `${neg ? '−' : ''}${whole}${decimals ? '.' + String(h % 100).padStart(2, '0') : ''} ر.س`;
}

// ───────────────────────── Assistant ─────────────────────────
const normAr = s => ' ' + normDigits(s).toLowerCase().replace(/[أإآ]/g, 'ا').replace(/ة/g, 'ه').replace(/ى/g, 'ي').replace(/[ؤ]/g, 'و').replace(/[ئ]/g, 'ي')
  .replace(/[ً-ٟـ]/g, '').replace(/[؟?]/g, ' ').split(/\s+/).filter(Boolean).join(' ') + ' ';
const CAT_SYN = [
  ['coffee', ['قهوه', 'كوفي', 'كافيه', 'coffee', 'cafe']], ['dining', ['مطاعم', 'مطعم', 'اكل', 'توصيل', 'restaurant', 'dining', 'food']],
  ['groceries', ['بقاله', 'سوبرماركت', 'مقاضي', 'groceries', 'grocery']], ['shopping', ['تسوق', 'ملابس', 'shopping', 'clothes']],
  ['auto', ['بنزين', 'وقود', 'سياره', 'fuel', 'petrol']], ['transport', ['مواصلات', 'اوبر', 'كريم', 'تاكسي', 'transport', 'taxi', 'uber']],
  ['subscriptions', ['اشتراكات', 'اشتراك', 'subscriptions', 'subscription']], ['entertainment', ['ترفيه', 'العاب', 'entertainment', 'games']],
  ['travel', ['سفر', 'فنادق', 'فندق', 'طيران', 'travel', 'hotel']], ['health', ['صحه', 'رياضه', 'صيدليه', 'نادي', 'health', 'gym', 'pharmacy']],
  ['bills', ['فواتير', 'فاتوره', 'كهرباء', 'bills']], ['transfers', ['تحويلات', 'حوالات', 'transfers']], ['cash', ['سحب نقدي', 'كاش', 'cash']],
  ['personal', ['شخصيه', 'personal']],
];

export function parseQuestion(state, question) {
  const q = normAr(question);
  const hasW = w => w.some(x => q.includes(x));
  let per = 'thisMonth', days = null;
  const m = /(?:اخر|خلال|last|past)\s*(\d+)\s*(?:يوم|ايام|days?)/.exec(q);
  if (m) { per = 'lastDays'; days = Math.max(1, Math.min(3660, +m[1])); }
  else if (hasW(['اخر اسبوع', 'last 7', 'past week'])) { per = 'lastDays'; days = 7; }
  else if (hasW(['اخر شهر', 'past month', 'last 30'])) { per = 'lastDays'; days = 30; }
  else if (hasW([' امس ', 'البارحه', 'yesterday'])) per = 'yesterday';
  else if (hasW([' اليوم ', 'today'])) per = 'today';
  else if (hasW(['الاسبوع الماضي', 'last week'])) per = 'lastWeek';
  else if (hasW(['الاسبوع', 'اسبوع', 'this week', 'week'])) per = 'thisWeek';
  else if (hasW(['الشهر الماضي', 'last month'])) per = 'lastMonth';
  else if (hasW(['السنه الماضيه', 'العام الماضي', 'last year'])) per = 'lastYear';
  else if (hasW(['السنه', 'العام', 'this year', 'year'])) per = 'thisYear';
  const category = CAT_SYN.find(([, w]) => hasW(w))?.[0] || null;
  const merch = [...new Set(state.txs.map(t => t.mkey).filter(k => k && k.length >= 3))].filter(k => q.includes(normAr(k))).sort((a, b) => b.length - a.length)[0] || null;
  let intent = 'unknown';
  if (hasW(['تقليل', 'اقلل', 'اخفض', 'reduce', 'cut'])) intent = 'tips';
  else if (hasW(['راتب', 'salary']) && hasW(['يتبقي', 'باقي', 'متبقي', 'بقي', 'left', 'remain'])) intent = 'salary';
  else if (hasW(['توفير', 'اوفر', 'ادخر', 'ادخار', 'save', 'saving'])) intent = 'savings';
  else if (hasW(['استنزف', 'اكثر شي', 'اكثر تصنيف', 'اعلي تصنيف', 'اكبر مصروف', 'most', 'biggest'])) intent = 'top';
  else if (hasW(['متاجر', 'merchants', 'stores'])) intent = 'merchants';
  else if (hasW(['رصيد', 'balance'])) intent = 'balance';
  else if (hasW(['دخل', 'income'])) intent = 'income';
  else if (merch && !category) intent = 'merchant';
  else if (category) intent = 'category';
  else if (hasW(['صرف', 'صرفت', 'مصروف', 'مصاريف', 'انفقت', 'دفعت', 'spent', 'spend', 'expenses'])) intent = 'total';
  return { intent, category, merchant: merch, period: per, days };
}

const PER_LABEL = { today: 'اليوم', yesterday: 'أمس', thisWeek: 'هذا الأسبوع', lastWeek: 'الأسبوع الماضي', thisMonth: 'هذا الشهر',
  lastMonth: 'الشهر الماضي', thisYear: 'هذه السنة', lastYear: 'السنة الماضية' };

function qInterval(q, now) {
  switch (q.period) {
    case 'today': return period('day', now); case 'yesterday': return prevPeriod('day', now);
    case 'thisWeek': return period('week', now); case 'lastWeek': return prevPeriod('week', now);
    case 'lastMonth': return prevPeriod('month', now); case 'thisYear': return period('year', now);
    case 'lastYear': return prevPeriod('year', now); case 'lastDays': return lastDays(q.days, now);
    default: return period('month', now);
  }
}

function completeMonths(state, n, now) {
  const first = Math.min(...state.txs.map(t => t.ts), now);
  const out = []; let cur = prevPeriod('month', now);
  for (let i = 0; i < n; i++) { if (cur[1] > first) out.push(summary(state, cur, now)); cur = prevPeriod('month', cur[0]); }
  return out;
}

export function answer(state, question, now = Date.now()) {
  const q = typeof question === 'string' ? parseQuestion(state, question) : question;
  const iv = qInterval(q, now);
  const label = q.period === 'lastDays' ? `آخر ${q.days} أيام` : PER_LABEL[q.period];
  const notes = s => [s.pendingCount ? `لا يشمل ${s.pendingCount} عمليات معلقة بقيمة ${sar(s.pending)}.` : null,
    s.unconfirmedCount ? `${s.unconfirmedCount} عمليات بقيمة ${sar(s.unconfirmed)} تنتظر مراجعتك ولم تُحتسب.` : null].filter(Boolean);
  const res = (text, value, s = null) => ({ text, value, notes: s ? notes(s) : [], query: q });

  switch (q.intent) {
    case 'total': {
      const s = summary(state, iv, now);
      let t = `صرفت ${sar(s.spending)} ${label} في ${s.expenseCount} عملية.`;
      if (s.refunds) t += ` (بعد خصم مستردات ${sar(s.refunds)})`;
      if (s.byCategory[0]) t += `\nأعلى تصنيف: ${catName(s.byCategory[0].category)} بـ ${sar(s.byCategory[0].amount)}.`;
      return res(t, s.spending, s);
    }
    case 'category': {
      const s = summary(state, iv, now, { category: q.category });
      let t = `صرفت على ${catName(q.category)} ${sar(s.spending)} ${label} في ${s.count} عملية.`;
      if (s.byMerchant[0]) t += `\nأكثر جهة: ${s.byMerchant[0].name} بـ ${sar(s.byMerchant[0].amount)}.`;
      if (q.category === 'subscriptions') {
        const r = recurring(state, now);
        if (r.length) t += `\nالمدفوعات المتكررة (${r.length}) بتكلفة شهرية ${sar(monthlyCost(r))}:` + r.slice(0, 10).map(x => `\n• ${x.name}: ${sar(x.expected)} ${x.label}، القادم ${fmtDate(x.next, false)}`).join('');
      }
      return res(t, s.spending, s);
    }
    case 'merchant': {
      const s = summary(state, iv, now, { mkey: q.merchant });
      return res(`صرفت لدى ${s.byMerchant[0]?.name || q.merchant} ${sar(s.spending)} ${label} في ${s.count} عملية.`, s.spending, s);
    }
    case 'top': {
      const s = summary(state, iv, now);
      const top = s.byCategory[0];
      if (!top || s.spending <= 0) return res(`لا توجد مصروفات مسجلة ${label}.`, 0, s);
      let t = `أكثر ما استنزف أموالك ${label}: ${catName(top.category)} بـ ${sar(top.amount)} (${Math.round(top.amount / s.spending * 100)}% من الإنفاق).`;
      t += s.byCategory.slice(1, 5).map(c => `\n• ${catName(c.category)}: ${sar(c.amount)}`).join('');
      if (s.byMerchant[0]) t += `\nأعلى جهة: ${s.byMerchant[0].name} بـ ${sar(s.byMerchant[0].amount)} في ${s.byMerchant[0].count} عملية.`;
      return res(t, top.amount, s);
    }
    case 'merchants': {
      const s = summary(state, iv, now);
      if (!s.byMerchant.length) return res(`لا توجد مصروفات مسجلة ${label}.`, 0, s);
      return res(`أكثر الجهات ${label}:` + s.byMerchant.slice(0, 10).map((m, i) => `\n${i + 1}. ${m.name}: ${sar(m.amount)} (${m.count})`).join(''), s.byMerchant[0].amount, s);
    }
    case 'income': {
      const s = summary(state, iv, now);
      let t = `دخلك ${label}: ${sar(s.income)}.`;
      if (s.transfersIn) t += `\nتحويلات واردة من آخرين (ليست دخلاً): ${sar(s.transfersIn)}.`;
      return res(t + `\nصافي التدفق: ${sar(s.net)}.`, s.income, s);
    }
    case 'balance': {
      const d = dashboard(state, now);
      return res(`إجمالي أرصدتك: ${sar(d.total)}.` + d.balances.map(b => `\n• ${b.account.name}: ${b.latest ? `${sar(b.latest.balance)} (${fmtDate(b.latest.ts, false)})` : 'لا يوجد رصيد'}`).join(''), d.total);
    }
    case 'salary': {
      const sal = state.txs.filter(t => { const e = effect(state, t); return e.type === 'income' && (e.category === 'salary' || e.category === 'allowance') && t.ts <= now; }).sort((a, b) => b.ts - a.ts)[0];
      if (!sal) return res('لا يوجد راتب مسجل بعد.', null);
      const s = summary(state, [sal.ts, now + 1], now);
      const left = sal.base - s.spending;
      const nextP = riyadhParts(sal.ts); const next = riyadhTs(nextP.y, nextP.m + 1, nextP.d);
      const daysLeft = Math.max(1, Math.ceil((next - now) / 864e5));
      let t = `آخر راتب: ${sar(sal.base)} بتاريخ ${fmtDate(sal.ts, false)}.\nصرفت منذ ذلك: ${sar(s.spending)}.\nالمتبقي: ${sar(left)}.`;
      if (left > 0) t += `\nالمتاح يومياً حتى الراتب القادم (~${daysLeft} يوم): ${sar(Math.floor(left / daysLeft))}.`;
      return res(t, left, s);
    }
    case 'savings': {
      const ms = completeMonths(state, 3, now);
      if (!ms.length) return res('أحتاج شهراً مكتملاً من البيانات على الأقل.', null);
      const inc = Math.round(ms.reduce((a, m) => a + m.income, 0) / ms.length), sp = Math.round(ms.reduce((a, m) => a + m.spending, 0) / ms.length);
      if (!inc) return res(`متوسط إنفاقك الشهري ${sar(sp)}، لكن لا يوجد دخل مسجل.`, null);
      const cap = inc - sp;
      return res(`بناءً على آخر ${ms.length} أشهر مكتملة:\nمتوسط الدخل ${sar(inc)}، متوسط الإنفاق ${sar(sp)}.\n` +
        (cap > 0 ? `يمكنك توفير نحو ${sar(cap)} شهرياً (${Math.round(cap / inc * 100)}% من الدخل).` : `إنفاقك يتجاوز دخلك بـ ${sar(-cap)} شهرياً.`), cap);
    }
    case 'tips': {
      const ms = completeMonths(state, 3, now);
      if (!ms.length) return res('أحتاج شهراً مكتملاً من البيانات على الأقل لاقتراح تخفيضات.', null);
      const mon = period('month', now); const cur = summary(state, mon, now);
      const elapsed = Math.max(0.1, (now - mon[0]) / (mon[1] - mon[0]));
      const avg = {}; for (const m of ms) for (const c of m.byCategory) avg[c.category] = (avg[c.category] || 0) + c.amount / ms.length;
      const lines = []; let pot = 0;
      for (const c of cur.byCategory) {
        if (!isExpenseCat(c.category) || c.category === 'transfers') continue;
        const proj = Math.round(c.amount / elapsed), base = avg[c.category] || 0;
        if (base > 0 && proj > base * 1.2 && proj - base >= 10000) { lines.push(`• ${catName(c.category)}: متوقع ${sar(proj, false)} هذا الشهر مقابل متوسط ${sar(base, false)}.`); pot += proj - base; }
      }
      for (const c of ['dining', 'coffee', 'shopping', 'entertainment']) if ((avg[c] || 0) >= 20000) {
        const cut = Math.round(avg[c] * 0.2); lines.push(`• تخفيض ${catName(c)} 20% يوفّر ${sar(cut, false)} شهرياً.`); pot += cut;
      }
      const r = recurring(state, now);
      if (r.length) lines.push(`• ${r.length} مدفوعات متكررة بـ ${sar(monthlyCost(r))} شهرياً: ${r.slice(0, 5).map(x => x.name).join('، ')}.`);
      if (ms[0].byMerchant[0]) lines.push(`• أعلى جهة الشهر الماضي: ${ms[0].byMerchant[0].name} بـ ${sar(ms[0].byMerchant[0].amount)}.`);
      return res(lines.length ? 'أين يمكنك تقليل مصاريفك:\n' + lines.join('\n') + `\nالتوفير المحتمل: ${sar(pot, false)} شهرياً.` : 'إنفاقك ضمن معدلاته المعتادة.', pot);
    }
    default:
      return res('لم أفهم السؤال. جرّب: «كم صرفت اليوم؟» أو «كم صرفت على القهوة هذا الشهر؟» أو «كم يتبقى من راتبي؟»', null);
  }
}

// ───────────────────────── Export ─────────────────────────
export function exportCSV(state, [start, end]) {
  const head = ['التاريخ', 'الجهة', 'التصنيف', 'المبلغ', 'العملة', 'بالريال', 'الأثر', 'الحالة', 'الحساب', 'المصدر'];
  const eff = { expense: 'مصروف', refund: 'مسترد', income: 'دخل', transferIn: 'تحويل وارد', transferOut: 'تحويل صادر غير محتسب', cash: 'سحب نقدي', internal: 'تحويل داخلي', pending: 'معلقة', unconfirmed: 'قيد المراجعة', excluded: 'مستبعدة' };
  const st = { pending: 'معلقة', completed: 'مكتملة', reversed: 'ملغاة', refunded: 'مستردة' };
  const q = v => (/[",\n]/.test(String(v)) ? `"${String(v).replace(/"/g, '""')}"` : String(v));
  const rows = state.txs.filter(t => t.ts >= start && t.ts < end).sort((a, b) => a.ts - b.ts).map(t => [fmtDate(t.ts, t.hasTime), t.merchant || t.counterparty || '',
    catName(t.category), (t.amount / 100).toFixed(2), t.currency, ((t.direction === 'debit' ? -1 : 1) * (t.base || 0) / 100).toFixed(2),
    eff[effect(state, t).type], st[t.status], state.accounts.find(a => a.id === t.accountId)?.name || '', t.sources.map(s => s.type).join('+')]);
  return '﻿' + [head, ...rows].map(r => r.map(q).join(',')).join('\r\n');
}
