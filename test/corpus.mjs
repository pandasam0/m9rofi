// Every real message the user has shared (Oct 31 2026), with sender. Used by tests and by the audit script.
export const CORPUS = [
  ['SNB-AlAhli', 'شراء انترنت\nبـSAR 150\nمن 2002*\nمن barq\nمدى-ابل *3098\nفي 17:05 31/10/26'],
  ['barqapp', 'شراء إنترنت\nفيزاSAR 89.99\nرصيد60.01\nلدىAPPLE\n2026-10-31 17:13'],
  ['barqapp', 'شراء نقاط بيع\nفيزاSAR 30.00\nرصيد106.78\nلدىQatrat\n2026-10-31 18:28'],
  ['SNB-AlAhli', 'شراء-POS\nبـSAR 1\nمن Shahrazad\nمدى-ابل*3098\nفي 19:13 31/10/26'],
  ['barqapp', 'حوالة صادرة محلية\nمبلغ1.00SAR\nرسوم0.00SAR\nلحساب2002\n2026-10-31 19:24'],
  ['SNB-AlAhli', 'حوالة واردة محلية ب SAR 1\nمن KHALIL SAMMAN 0032*\n31/10/26 19:26'],
  ['SNB-AlAhli', 'حوالة واردة داخلية بSAR 1000\nمن9705* رامي سمان\n31/10/26 19:51'],
  ['SNB-AlAhli', 'حوالة صادرة داخلية بSAR 250\nل2405* رناد سمان\n31/10/26 20:00'],
  ['SNB-AlAhli', 'حوالة صادرة داخلية بSAR 250\nل6602* عبدالقادر سمان\n31/10/26 20:01'],
  ['SNB-AlAhli', 'شراء انترنت\nبـSAR 250\nمن 2002*\nمن MYSR D360\nمدى-ابل *3098\nفي 20:06 31/10/26'],
  ['D360Bank', 'اضافة باستخدام آبل باى\nمبلغ:SAR 250\nبطاقة:*3098 - mada\nإلى:*9631\nفي:20:06:23 31/10/2026'],
  ['D360Bank', 'حوالة صادرة داخلية\nمن : *9631\nمبلغ: SAR 250.00\nإلى: ELHAM SAMMAN\nرقم الحساب: *0529\nفي: 31-10-2026 20:06'],
];

export function userState(E) {
  const s = E.newState();
  s.accounts = [
    { id: 'snb', name: 'البنك الأهلي', institution: 'snb', type: 'current', cards: ['3098'], numbers: ['2002'], walletNames: [], senders: [], tracked: true },
    { id: 'barq', name: 'Barq', institution: 'barq', type: 'wallet', cards: [], numbers: ['0032'], walletNames: [], senders: [], tracked: true },
    { id: 'd360', name: 'D360', institution: 'other', type: 'current', cards: [], numbers: ['9631'], walletNames: [], senders: [], tracked: true },
  ];
  s.settings.ownerNames = ['خليل سمان', 'KHALIL SAMMAN'];
  return s;
}
