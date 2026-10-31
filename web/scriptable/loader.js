// مصروفي — انسخ هذا كاملاً في Scriptable مرة واحدة فقط. التحديثات تنزل تلقائياً.
const SRC = "https://pandasam0.github.io/m9rofi/scriptable.js";
const fm = (() => { try { return FileManager.iCloud(); } catch (e) { return FileManager.local(); } })();
const dir = fm.joinPath(fm.documentsDirectory(), "m9rofi");
if (!fm.fileExists(dir)) fm.createDirectory(dir, true);
const cache = fm.joinPath(dir, "app.js");
const background = (args.shortcutParameter != null && args.shortcutParameter !== "") || config.runsInWidget;
let code = null;
if (fm.fileExists(cache)) { try { if (!fm.isFileDownloaded(cache)) await fm.downloadFileFromiCloud(cache); } catch (e) {} code = fm.readString(cache); }
if (!code || !background) {
  try {
    const req = new Request(SRC); req.timeoutInterval = 10;
    const fresh = await req.loadString();
    if (fresh && fresh.startsWith("// M9ROFI_APP")) { code = fresh; fm.writeString(cache, fresh); }
  } catch (e) {}
}
if (!code) throw new Error("أول تشغيل يحتاج إنترنت لتنزيل مصروفي.");
await new (Object.getPrototypeOf(async function () {}).constructor)(code)();
