import SwiftUI
import Combine
import UserNotifications
import Translation
import UniformTypeIdentifiers

struct Expense: Codable, Identifiable {
    var id = UUID(); var cents: Int; var category: String; var memo: String; var date: Date
}
struct Todo: Codable, Identifiable {
    var id = UUID(); var title: String; var date: Date; var done = false; var remind = true
}
struct Review: Codable, Identifiable {
    var id = UUID(); var title: String; var content: String; var created = Date()
    var step = 0; var due: Date; var lastReviewed: Date? = nil
    static let intervals = [1, 2, 4, 7, 15, 30]
    var finished: Bool { step >= Self.intervals.count }
}
struct Note: Codable, Identifiable {
    var id = UUID(); var title: String; var text: String; var updated = Date()
}
struct FocusRecord: Codable, Identifiable {
    var id = UUID(); var date = Date(); var minutes: Int
}
struct AppData: Codable {
    var expenses: [Expense] = []; var todos: [Todo] = []; var reviews: [Review] = []
    var notes: [Note] = []; var focus: [FocusRecord] = []
    var timerEnd: Date? = nil; var timerRemaining = 25 * 60
    var timerMinutes = 25; var timerIsBreak = false
}

@MainActor final class Store: ObservableObject {
    @Published var data = AppData()
    @Published var error: String? = nil
    @Published var notice = "尚未开启提醒"
    private var scheduling: Task<Void, Never>?
    var canSave = true
    private let url = URL.documentsDirectory.appending(path: "zhixu-v1.json")
    init() {
        if FileManager.default.fileExists(atPath: url.path) {
            do { data = try JSONDecoder().decode(AppData.self, from: Data(contentsOf: url)) }
            catch { canSave = false; self.error = "本地数据读取失败，请勿继续覆盖：\(error.localizedDescription)" }
        }
    }
    func save() {
        guard canSave else { error = "原数据读取失败，已阻止覆盖。请从有效备份恢复。"; return }
        do {
            try JSONEncoder().encode(data).write(to: url, options: [.atomic, .completeFileProtection])
        } catch { self.error = "保存失败：\(error.localizedDescription)" }
        reschedule()
    }
    func enableNotifications() async {
        do {
            let ok = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            notice = ok ? "已允许提醒；请检查专注模式及静音设置" : "提醒未开启，请到系统设置中允许通知"
            reschedule()
        } catch { notice = error.localizedDescription }
    }
    func reschedule() {
        guard canSave else { return }
        scheduling?.cancel()
        let snapshot = data
        scheduling = Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let pending = await center.pendingNotificationRequests()
            guard !Task.isCancelled else { return }
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier))
            var upcoming: [(String, String, Date)] = []
            for t in snapshot.todos where !t.done && t.remind && t.date > Date() {
                upcoming.append(("todo-\(t.id)", "待办：\(t.title)", t.date))
            }
            for r in snapshot.reviews where !r.finished {
                // Overdue reviews remain visible and receive one reminder tomorrow.
                let date = r.due > Date() ? r.due : Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 9), matchingPolicy: .nextTime)!
                upcoming.append(("review-\(r.id)", "该复习了：\(r.title)", date))
            }
            upcoming.sort { $0.2 < $1.2 }
            if let end = snapshot.timerEnd, end > Date() {
                upcoming.insert(("focus", snapshot.timerIsBreak ? "休息结束，可以开始学习了" : "本次专注结束，休息一下吧", end), at: 0)
            }
            for item in upcoming.prefix(60) {
                guard !Task.isCancelled else { return }
                let content = UNMutableNotificationContent()
                content.title = "知序"; content.body = item.1; content.sound = .default
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, item.2.timeIntervalSinceNow), repeats: false)
                do { try await center.add(UNNotificationRequest(identifier: item.0, content: content, trigger: trigger)) }
                catch { notice = "提醒安排失败：\(error.localizedDescription)" }
            }
        }
    }
    func grade(_ id: UUID, remembered: Bool) {
        guard let i = data.reviews.firstIndex(where: { $0.id == id }) else { return }
        data.reviews[i].lastReviewed = Date()
        if remembered { data.reviews[i].step += 1 } else { data.reviews[i].step = 0 }
        let step = data.reviews[i].step
        if step < Review.intervals.count {
            // Intervals are measured from actual review time, not the original learning date.
            data.reviews[i].due = Calendar.current.date(byAdding: .day, value: Review.intervals[step], to: Date())!
        }
        save()
    }
    func finishTimerIfNeeded() {
        guard let end = data.timerEnd, end <= Date() else { return }
        if !data.timerIsBreak { data.focus.append(FocusRecord(date: end, minutes: data.timerMinutes)) }
        data.timerEnd = nil; data.timerRemaining = data.timerMinutes * 60; save()
    }
}
final class Notifications: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
@main struct ZhixuApp: App {
    @StateObject private var store = Store()
    private let notifications = Notifications()
    init() { UNUserNotificationCenter.current().delegate = notifications }
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store).tint(.purple)
                .alert("提示", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
                    Button("知道了") { store.error = nil }
                } message: { Text(store.error ?? "") }
        }
    }
}
struct RootView: View {
    @EnvironmentObject var store: Store
    @Environment(\.scenePhase) private var scene
    var body: some View {
        TabView {
            TodayView().tabItem { Label("今天", systemImage: "sun.max") }
            FocusView().tabItem { Label("专注", systemImage: "timer") }
            ReviewsView().tabItem { Label("复习", systemImage: "brain.head.profile") }
            MoneyView().tabItem { Label("花销", systemImage: "creditcard") }
            ToolsView().tabItem { Label("工具", systemImage: "square.grid.2x2") }
        }.onChange(of: scene) { _, value in
            if value == .active { store.finishTimerIfNeeded(); store.reschedule() }
        }
    }
}
struct TodayView: View {
    @EnvironmentObject var store: Store
    @State private var selected = Date()
    @State private var adding = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("把今天的一小步，变成未来的底气。")
                        .font(.title3.bold()).padding(.vertical, 8)
                    LabeledContent("今日专注", value: "\(store.data.focus.filter { Calendar.current.isDateInToday($0.date) }.reduce(0) { $0 + $1.minutes }) 分钟")
                    LabeledContent("到期复习", value: "\(store.data.reviews.filter { !$0.finished && $0.due <= Date() }.count) 项")
                }
                Section("每日待办") {
                    DatePicker("查看日期", selection: $selected, displayedComponents: .date)
                    ForEach(store.data.todos.filter { Calendar.current.isDate($0.date, inSameDayAs: selected) }.sorted { $0.date < $1.date }) { task in
                        HStack {
                            Button {
                                if let i = store.data.todos.firstIndex(where: { $0.id == task.id }) { store.data.todos[i].done.toggle(); store.save() }
                            } label: { Image(systemName: task.done ? "checkmark.circle.fill" : "circle").font(.title2) }.buttonStyle(.borderless)
                            VStack(alignment: .leading) {
                                Text(task.title).strikethrough(task.done)
                                Text(task.date, style: .time).font(.caption).foregroundStyle(.secondary)
                            }
                        }.swipeActions { Button("删除", role: .destructive) { store.data.todos.removeAll { $0.id == task.id }; store.save() } }
                    }
                    if !store.data.todos.contains(where: { Calendar.current.isDate($0.date, inSameDayAs: selected) }) { Text("这一天还没有待办，点右上角添加。 ").foregroundStyle(.secondary) }
                }
            }.navigationTitle("知序 · 今天")
                .toolbar { Button("添加", systemImage: "plus") { adding = true } }
                .sheet(isPresented: $adding) { TodoEditor(initialDate: selected) }
        }
    }
}
struct TodoEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State private var title = ""
    @State private var date: Date
    @State private var remind = true
    init(initialDate: Date) { _date = State(initialValue: initialDate) }
    var body: some View {
        NavigationStack { Form {
            TextField("例如：完成 5 道数学题", text: $title)
            DatePicker("计划时间", selection: $date)
            Toggle("到时提醒", isOn: $remind)
        }.navigationTitle("新增待办").toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存") {
                store.data.todos.append(Todo(title: title.trimmingCharacters(in: .whitespacesAndNewlines), date: date, remind: remind)); store.save(); dismiss()
            }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        } }
    }
}
struct FocusView: View {
    @EnvironmentObject var store: Store
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    var seconds: Int { store.data.timerEnd.map { max(0, Int(ceil($0.timeIntervalSince(now)))) } ?? store.data.timerRemaining }
    var body: some View {
        NavigationStack { ScrollView { VStack(spacing: 28) {
            Text(store.data.timerIsBreak ? "给大脑一点留白" : "这一刻，只做一件事").font(.title3).foregroundStyle(.secondary)
            ZStack {
                Circle().stroke(.purple.opacity(0.12), lineWidth: 14)
                Circle().trim(from: 0, to: min(1, CGFloat(seconds) / CGFloat(max(1, store.data.timerMinutes * 60))))
                    .stroke(.purple, style: StrokeStyle(lineWidth: 14, lineCap: .round)).rotationEffect(.degrees(-90))
                Text(String(format: "%02d:%02d", seconds / 60, seconds % 60)).font(.system(size: 62, weight: .light, design: .rounded)).monospacedDigit()
            }.frame(width: 260, height: 260).padding(.vertical, 10)
            HStack {
                ForEach([5, 25, 45, 60], id: \.self) { m in Button("\(m)分") {
                    store.data.timerMinutes = m; store.data.timerRemaining = m * 60; store.save()
                }.buttonStyle(.bordered).disabled(store.data.timerEnd != nil) }
            }
            Toggle("休息模式（不计入专注统计）", isOn: $store.data.timerIsBreak).disabled(store.data.timerEnd != nil)
            HStack(spacing: 20) {
                Button(store.data.timerEnd == nil ? "开始 / 继续" : "暂停") {
                    if store.data.timerEnd != nil { store.data.timerRemaining = seconds; store.data.timerEnd = nil }
                    else { store.data.timerEnd = Date().addingTimeInterval(Double(store.data.timerRemaining)) }
                    store.save()
                }.buttonStyle(.borderedProminent)
                Button("重置") { store.data.timerEnd = nil; store.data.timerRemaining = store.data.timerMinutes * 60; store.save() }.buttonStyle(.bordered)
            }
            Text("切到后台后仍按结束时间计时；完成提醒需允许通知。完成一轮后，可选择 5 分钟休息模式。 ").font(.footnote).foregroundStyle(.secondary)
            Text("累计专注 \(store.data.focus.reduce(0) { $0 + $1.minutes }) 分钟").font(.headline)
        }.padding(24) }.navigationTitle("番茄专注") }
        .onReceive(tick) { value in now = value; store.finishTimerIfNeeded() }
    }
}
struct ReviewsView: View {
    @EnvironmentObject var store: Store
    @State private var adding = false
    var body: some View {
        NavigationStack { List {
            Section { Text("默认间隔：1、2、4、7、15、30 天。每次按实际复习时间安排下一次；忘记则回到第 1 天。间隔是学习辅助，不是对个人记忆的精确预测。 ").font(.footnote).foregroundStyle(.secondary) }
            ForEach(store.data.reviews.sorted { $0.due < $1.due }) { review in
                NavigationLink { ReviewDetail(id: review.id) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(review.title).font(.headline)
                        Text(review.finished ? "本轮完成" : "第 \(review.step + 1)/6 轮 · \(review.due.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(!review.finished && review.due <= Date() ? .orange : .secondary)
                    }
                }.swipeActions { Button("删除", role: .destructive) { store.data.reviews.removeAll { $0.id == review.id }; store.save() } }
            }
            if store.data.reviews.isEmpty { Text("把今天学到的英语、数学或 Python 加进来。 ").foregroundStyle(.secondary) }
        }.navigationTitle("间隔复习").toolbar { Button("添加", systemImage: "plus") { adding = true } }
            .sheet(isPresented: $adding) { ReviewEditor() }
        }
    }
}
struct ReviewEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State private var title = ""; @State private var content = ""
    @State private var due = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
    var body: some View {
        NavigationStack { Form {
            TextField("知识点 / 自测问题", text: $title)
            Section("答案或学习笔记") { TextEditor(text: $content).frame(minHeight: 180) }
            DatePicker("首次复习", selection: $due)
        }.navigationTitle("新增复习").toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存") {
                store.data.reviews.append(Review(title: title, content: content, due: due)); store.save(); dismiss()
            }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        } }
    }
}
struct ReviewDetail: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let id: UUID
    @State private var reveal = false
    var body: some View {
        Group {
            if let r = store.data.reviews.first(where: { $0.id == id }) {
                List {
                    Section("先回忆，再看答案") { Text(r.title).font(.title3.bold()) }
                    Section {
                        Button(reveal ? "隐藏答案" : "显示答案") { reveal.toggle() }
                        if reveal { Text(r.content.isEmpty ? "尚未填写答案" : r.content).textSelection(.enabled) }
                    }
                    if !r.finished {
                        Section("自测结果") {
                            Button("记住了 → 下一轮") { store.grade(id, remembered: true); dismiss() }
                            Button("忘记了 → 明天重新复习") { store.grade(id, remembered: false); dismiss() }
                        }
                    } else { Text("本轮已完成。可删除后重新创建，或自行定期抽测。 ") }
                }
            } else { Text("该复习已删除") }
        }.navigationTitle("主动回忆")
    }
}
struct MoneyView: View {
    @EnvironmentObject var store: Store
    @State private var adding = false
    var monthTotal: Int { store.data.expenses.filter { Calendar.current.isDate($0.date, equalTo: Date(), toGranularity: .month) }.reduce(0) { $0 + $1.cents } }
    var body: some View {
        NavigationStack { List {
            Section("本月花销") { Text(Double(monthTotal) / 100, format: .currency(code: "CNY")).font(.largeTitle.bold()) }
            Section("分类统计 · 本月") {
                ForEach(["餐饮", "交通", "学习", "生活", "娱乐", "其他"], id: \.self) { c in
                    let amount = store.data.expenses.filter { $0.category == c && Calendar.current.isDate($0.date, equalTo: Date(), toGranularity: .month) }.reduce(0) { $0 + $1.cents }
                    LabeledContent(c, value: (Double(amount) / 100).formatted(.currency(code: "CNY")))
                }
            }
            Section("所有记录") {
                ForEach(store.data.expenses.sorted { $0.date > $1.date }) { e in
                    HStack {
                        VStack(alignment: .leading) { Text(e.memo.isEmpty ? e.category : e.memo); Text("\(e.category) · \(e.date.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary) }
                        Spacer(); Text(Double(e.cents) / 100, format: .currency(code: "CNY"))
                    }.swipeActions { Button("删除", role: .destructive) { store.data.expenses.removeAll { $0.id == e.id }; store.save() } }
                }
            }
        }.navigationTitle("我的花销").toolbar { Button("记一笔", systemImage: "plus") { adding = true } }
            .sheet(isPresented: $adding) { ExpenseEditor() }
        }
    }
}
struct ExpenseEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State private var amount = ""; @State private var category = "餐饮"; @State private var memo = ""; @State private var date = Date()
    var cents: Int? {
        let normalized = amount.replacingOccurrences(of: "，", with: ".").replacingOccurrences(of: ",", with: ".")
        guard normalized.range(of: #"^\d{1,8}(\.\d{1,2})?$"#, options: .regularExpression) != nil,
              let d = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")), d > 0 else { return nil }
        return NSDecimalNumber(decimal: d * 100).intValue
    }
    var body: some View {
        NavigationStack { Form {
            TextField("金额（元，最多两位小数）", text: $amount).keyboardType(.decimalPad)
            Picker("分类", selection: $category) { ForEach(["餐饮", "交通", "学习", "生活", "娱乐", "其他"], id: \.self) { Text($0) } }
            TextField("备注", text: $memo); DatePicker("日期", selection: $date, displayedComponents: .date)
        }.navigationTitle("记一笔").toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存") {
                guard let value = cents else { return }
                store.data.expenses.append(Expense(cents: value, category: category, memo: memo, date: date)); store.save(); dismiss()
            }.disabled(cents == nil) }
        } }
    }
}
struct ToolsView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        NavigationStack { List {
            Section("学习工具") {
                NavigationLink { NotesView() } label: { Label("记事本", systemImage: "note.text") }
                NavigationLink { TranslateView() } label: { Label("翻译", systemImage: "character.bubble") }
            }
            Section("提醒") {
                Button("开启 / 检查通知权限") { Task { await store.enableNotifications() } }
                Text(store.notice).font(.footnote).foregroundStyle(.secondary)
                Text("待办和复习按最近时间安排，最多 60 条待发通知。打开应用会刷新提醒；待办、复习过多时请定期开启应用。 ").font(.footnote).foregroundStyle(.secondary)
            }
            Section("数据") { NavigationLink("备份与恢复") { BackupView() } }
            Section { Text("知序 0.1 · 原生 iPhone 工程\n数据仅保存在本机，不含登录、云同步或广告。卸载前请导出备份。 ").font(.footnote).foregroundStyle(.secondary) }
        }.navigationTitle("学习工具") }
    }
}
struct NotesView: View {
    @EnvironmentObject var store: Store
    @State private var query = ""
    @State private var adding = false
    var body: some View {
        List {
            ForEach(store.data.notes.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.text.localizedCaseInsensitiveContains(query) }.sorted { $0.updated > $1.updated }) { n in
                NavigationLink { NoteEditor(existing: n) } label: {
                    VStack(alignment: .leading) { Text(n.title).font(.headline); Text(n.text).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }.swipeActions { Button("删除", role: .destructive) { store.data.notes.removeAll { $0.id == n.id }; store.save() } }
            }
        }.navigationTitle("记事本").searchable(text: $query, prompt: "搜索标题和正文")
            .toolbar { Button("新建", systemImage: "square.and.pencil") { adding = true } }
            .sheet(isPresented: $adding) { NavigationStack { NoteEditor(existing: nil) } }
    }
}
struct NoteEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let existing: Note?
    @State private var title: String; @State private var text: String
    init(existing: Note?) { self.existing = existing; _title = State(initialValue: existing?.title ?? ""); _text = State(initialValue: existing?.text ?? "") }
    var body: some View {
        Form {
            TextField("标题", text: $title)
            TextEditor(text: $text).frame(minHeight: 320)
            Text("修改后请点保存。 ").font(.caption).foregroundStyle(.secondary)
        }.navigationTitle(existing == nil ? "新建笔记" : "编辑笔记").toolbar {
            Button("保存") {
                let note = Note(id: existing?.id ?? UUID(), title: title.isEmpty ? "未命名笔记" : title, text: text)
                if let i = store.data.notes.firstIndex(where: { $0.id == note.id }) { store.data.notes[i] = note }
                else { store.data.notes.append(note) }
                store.save(); dismiss()
            }
        }
    }
}
struct TranslateView: View {
    @EnvironmentObject var store: Store
    @State private var text = ""
    @State private var show = false
    var body: some View {
        Form {
            Section("输入需要翻译的文本") { TextEditor(text: $text).frame(minHeight: 200) }
            Button("打开系统翻译") { show = true }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("将原文加入复习") {
                store.data.reviews.append(Review(title: String(text.prefix(80)), content: text, due: Calendar.current.date(byAdding: .day, value: 1, to: Date())!)); store.save()
            }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Text("使用苹果系统翻译面板，可选择语言及复制译文。首次使用可能需要下载语言包；设备可用语言以系统为准。 ").font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("翻译").translationPresentation(isPresented: $show, text: text)
    }
}
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
struct BackupView: View {
    @EnvironmentObject var store: Store
    @State private var exporting = false; @State private var importing = false; @State private var confirm = false
    @State private var candidate: AppData?
    @State private var document = BackupDocument(data: Data())
    var body: some View {
        Form {
            Button("导出完整备份（JSON）") {
                do { document = BackupDocument(data: try JSONEncoder().encode(store.data)); exporting = true }
                catch { store.error = error.localizedDescription }
            }
            Button("从备份恢复") { importing = true }
            Text("恢复会替换当前数据，请先导出当前备份。备份包含花销和笔记等个人信息，请妥善保管。 ").font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("备份与恢复")
            .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "知序备份") { result in
                if case .failure(let error) = result { store.error = error.localizedDescription }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get(); let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let bytes = try Data(contentsOf: url)
                    guard bytes.count <= 20_000_000 else { throw CocoaError(.fileReadTooLarge) }
                    let imported = try JSONDecoder().decode(AppData.self, from: bytes)
                    guard imported.timerMinutes >= 1, imported.timerMinutes <= 180,
                          imported.timerRemaining >= 0, imported.timerRemaining <= 10800,
                          imported.reviews.allSatisfy({ (0...6).contains($0.step) }),
                          imported.expenses.allSatisfy({ $0.cents > 0 && $0.cents <= 9_999_999_999 }),
                          Set(imported.todos.map(\.id)).count == imported.todos.count,
                          Set(imported.notes.map(\.id)).count == imported.notes.count,
                          Set(imported.reviews.map(\.id)).count == imported.reviews.count,
                          Set(imported.expenses.map(\.id)).count == imported.expenses.count else { throw CocoaError(.fileReadCorruptFile) }
                    candidate = imported; confirm = true
                } catch { store.error = "无法导入：\(error.localizedDescription)" }
            }
            .confirmationDialog("用备份替换全部当前数据？", isPresented: $confirm, titleVisibility: .visible) {
                Button("替换并恢复", role: .destructive) {
                    if var value = candidate { value.timerEnd = nil; store.canSave = true; store.data = value; store.save() }
                    candidate = nil
                }
                Button("取消", role: .cancel) { candidate = nil }
            }
    }
}
