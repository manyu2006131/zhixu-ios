"""Compile production model definitions with Foundation and exercise data compatibility."""
from pathlib import Path
import subprocess, tempfile
root=Path(__file__).resolve().parent.parent
source=(root/'Zhixu/ZhixuApp.swift').read_text()
models=source[source.index('struct Expense:'):source.index('@MainActor final class Store:')]
# EntryKind contains UI-only icon/hint computed properties, which still return Strings.
extras=source[source.index('enum EntryKind:'):source.index('func dayKey(')]
tests=r'''
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
let encoder = JSONEncoder()
let decoder = JSONDecoder()
var original = AppData()
original.expenses = [Expense(cents: 1234, category: "学习", memo: "书", date: Date())]
original.todos = [Todo(title: "数学", date: Date())]
original.reviews = [Review(title: "负号", content: "先去括号", due: Date())]
original.notes = [Note(title: "笔记", text: "中文与 emoji ✨")]
original.focus = [FocusRecord(minutes: 25)]
let bytes = try encoder.encode(original)
var legacy = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
legacy.removeValue(forKey: "extras")
var todos = legacy["todos"] as! [[String: Any]]
todos[0].removeValue(forKey: "completedAt"); legacy["todos"] = todos
let old = try decoder.decode(AppData.self, from: JSONSerialization.data(withJSONObject: legacy))
check(old.expenses[0].cents == 1234, "old expense changed")
check(old.notes[0].text == original.notes[0].text, "unicode changed")
check(old.extras.entries.isEmpty, "migration must start with empty tools")
check(old.todos[0].completedAt == nil, "legacy completion date invented")
var upgraded = old
upgraded.extras.entries = EntryKind.allCases.map { JournalEntry(kind: $0, title: $0.rawValue, detail: "测试", amount: 1, goal: 10) }
upgraded.extras.budgetCents = 200000
upgraded.extras.entries[0].reviewID = upgraded.reviews[0].id
upgraded.timerEnd = Date().addingTimeInterval(120)
let recovered = try decoder.decode(AppData.self, from: encoder.encode(upgraded))
check(recovered.extras.entries.count == 9, "tools lost in roundtrip")
check(recovered.extras.entries[0].reviewID == recovered.reviews[0].id, "review linkage lost")
check(recovered.timerEnd != nil, "active timer lost")
check(recovered.expenses[0].cents == 1234, "money precision changed")
check(Review.intervals == [1,2,4,7,15,30], "review intervals changed")
do { _ = try decoder.decode(AppData.self, from: Data("{bad}".utf8)); fatalError("bad file accepted") } catch {}
print("PASS: legacy migration, unicode, all tool types, review linkage, active timer, money precision, corrupt JSON")
'''
with tempfile.TemporaryDirectory() as d:
    file=Path(d)/'main.swift';file.write_text('import Foundation\n'+models+extras+tests)
    subprocess.run(['swift',str(file)],check=True)
