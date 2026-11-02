// M9ROFI_APP — uninstaller. Deletes all مصروفي data and this script from Scriptable.
const fm = (() => { try { return FileManager.iCloud(); } catch (e) { return FileManager.local(); } })();
const dir = fm.joinPath(fm.documentsDirectory(), 'm9rofi');
try { if (fm.fileExists(dir)) fm.remove(dir); } catch (e) {}
try { const lf = FileManager.local(); const ld = lf.joinPath(lf.documentsDirectory(), 'm9rofi'); if (lf.fileExists(ld)) lf.remove(ld); } catch (e) {}
try { const me = fm.joinPath(fm.documentsDirectory(), Script.name() + '.js'); if (fm.fileExists(me)) fm.remove(me); } catch (e) {}
if (config.runsInWidget) { const w = new ListWidget(); w.addText('تم حذف مصروفي'); Script.setWidget(w); }
else if (args.shortcutParameter == null) { const a = new Alert(); a.title = 'تم حذف مصروفي'; a.message = 'حُذفت كل البيانات والسكربت. احذف الودجت والأتمتة من جوالك.'; a.addAction('تم'); await a.present(); }
Script.complete();
