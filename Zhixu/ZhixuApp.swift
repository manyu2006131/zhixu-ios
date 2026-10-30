import SwiftUI
import Combine
import UserNotifications
import Translation
import UniformTypeIdentifiers

struct Expense: Codable, Identifiable {
    var id = UUID(); var cents: Int; var category: String; var memo: String; var date: Date
}
struct Todo: Codable, Identifiable {
    var id = UUID(); var title: String; var date: Date; var done = false; var remind = true; var completedAt: Date? = nil
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
    var extras = Extras()
    init() {}
    enum CodingKeys: String, CodingKey { case expenses, todos, reviews, notes, focus, timerEnd, timerRemaining, timerMinutes, timerIsBreak, extras }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        expenses = try c.decode([Expense].self, forKey: .expenses)
        todos = try c.decode([Todo].self, forKey: .todos)
        reviews = try c.decode([Review].self, forKey: .reviews)
        notes = try c.decode([Note].self, forKey: .notes)
        focus = try c.decode([FocusRecord].self, forKey: .focus)
        timerEnd = try c.decodeIfPresent(Date.self, forKey: .timerEnd)
        timerRemaining = try c.decode(Int.self, forKey: .timerRemaining)
        timerMinutes = try c.decode(Int.self, forKey: .timerMinutes)
        timerIsBreak = try c.decode(Bool.self, forKey: .timerIsBreak)
        extras = try c.decodeIfPresent(Extras.self, forKey: .extras) ?? Extras()
    }
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
            let backupDue = snapshot.extras.lastBackup.addingTimeInterval(7 * 86400)
            upcoming.append(("backup", "本周备份提醒：到工具页导出学习数据", max(backupDue, Date().addingTimeInterval(60))))
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
            RootView().environmentObject(store).tint(Color(red: 0.65, green: 0.51, blue: 0.98)).preferredColorScheme(.dark)
                .alert("提示", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
                    Button("知道了") { store.error = nil }
                } message: { Text(store.error ?? "") }
        }
    }
}
struct RootView: View {
    @EnvironmentObject var store: Store
    @Environment(\.scenePhase) private var scene
    @State private var tab = 0
    var body: some View {
        TabView(selection: $tab) {
            TodayView(selectedTab: $tab).tag(0).tabItem { Label("今天", systemImage: "sun.max") }
            FocusView().tag(1).tabItem { Label("专注", systemImage: "timer") }
            ReviewsView().tag(2).tabItem { Label("复习", systemImage: "brain.head.profile") }
            MoneyView().tag(3).tabItem { Label("花销", systemImage: "creditcard") }
            ToolsView().tag(4).tabItem { Label("工具", systemImage: "square.grid.2x2") }
        }.task { store.finishTimerIfNeeded(); store.reschedule() }.onChange(of: scene) { _, value in
            if value == .active { store.finishTimerIfNeeded(); store.reschedule() }
        }
    }
}
struct TodayView: View {
    @EnvironmentObject var store: Store
    @Binding var selectedTab: Int
    @State private var selected = Date()
    @State private var adding = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    WitchHero()
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                    HStack {
                        Metric(title: "今日专注", value: "\(store.data.focus.filter { Calendar.current.isDateInToday($0.date) }.reduce(0) { $0 + $1.minutes }) 分钟")
                        Spacer()
                        Metric(title: "待复习", value: "\(store.data.reviews.filter { !$0.finished && $0.due <= Date() }.count) 项")
                    }.padding(.vertical, 8)
                    Button {
                        if store.data.timerEnd == nil {
                            store.data.timerIsBreak = false
                            store.data.timerMinutes = 25; store.data.timerRemaining = 1500
                            store.data.timerEnd = Date().addingTimeInterval(1500); store.save()
                        }
                        selectedTab = 1
                    } label: { Label("学习一键开始 · 25 分钟", systemImage: "play.fill").font(.headline).frame(maxWidth: .infinity).padding(8) }
                    .buttonStyle(.borderedProminent)
                }
                Section("今日最低任务 · 小步也算前进") {
                    MiniTaskRows()
                    NavigationLink("管理每日最低任务") { EntriesView(kind: .minimum) }
                }
                Section("每日待办") {
                    DatePicker("查看日期", selection: $selected, displayedComponents: .date)
                    ForEach(store.data.todos.filter { Calendar.current.isDate($0.date, inSameDayAs: selected) }.sorted { $0.date < $1.date }) { task in
                        HStack {
                            Button {
                                if let i = store.data.todos.firstIndex(where: { $0.id == task.id }) {
                                    store.data.todos[i].done.toggle()
                                    store.data.todos[i].completedAt = store.data.todos[i].done ? Date() : nil
                                    store.save()
                                }
                            } label: { Image(systemName: task.done ? "checkmark.circle.fill" : "circle").font(.title2) }.buttonStyle(.borderless)
                            VStack(alignment: .leading) {
                                Text(task.title).strikethrough(task.done)
                                Text(task.date, style: .time).font(.caption).foregroundStyle(.secondary)
                            }
                        }.swipeActions { Button("删除", role: .destructive) { store.data.todos.removeAll { $0.id == task.id }; store.save() } }
                    }
                    if !store.data.todos.contains(where: { Calendar.current.isDate($0.date, inSameDayAs: selected) }) { Text("留一点空白，写下今天要完成的小事。 ").foregroundStyle(.secondary) }
                }
                Section("旅途中的小工具") {
                    NavigationLink { EntriesView(kind: .exam) } label: { Label("考试倒计时", systemImage: "calendar.badge.clock") }
                    NavigationLink { WeeklyView() } label: { Label("本周学习手账", systemImage: "chart.bar.xaxis") }
                    NavigationLink { EntriesView(kind: .inbox) } label: { Label("随手收集箱", systemImage: "tray") }
                }
            }.scrollContentBackground(.hidden).background(MagicBackground())
                .navigationTitle("知序 · 魔女手账")
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
            Toggle("休息模式（不计入专注统计）", isOn: $store.data.timerIsBreak).disabled(store.data.timerEnd != nil || store.data.timerRemaining != store.data.timerMinutes * 60).onChange(of: store.data.timerIsBreak) { _, _ in store.save() }
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
            Section("本月花销") {
                Text(Double(monthTotal) / 100, format: .currency(code: "CNY")).font(.largeTitle.bold())
                if store.data.extras.budgetCents > 0 {
                    ProgressView(value: min(1, Double(monthTotal) / Double(store.data.extras.budgetCents)))
                    Text("剩余预算 ¥\(Double(store.data.extras.budgetCents - monthTotal) / 100, specifier: "%.2f")").font(.caption)
                }
                NavigationLink("预算与攒钱进度") { BudgetView() }
            }
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
            Section {
                HStack(spacing: 16) {
                    Image("Witch").resizable().scaledToFill().frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 18))
                    VStack(alignment: .leading, spacing: 5) { Text("旅行，学习，成为更好的自己").font(.headline); Text("知序 0.2 · 魔女的工具箱").font(.caption).foregroundStyle(.secondary) }
                }.padding(.vertical, 8)
            }
            Section("学习魔法") {
                NavigationLink { NotesView() } label: { Label("记事本", systemImage: "note.text") }
                NavigationLink { TranslateView() } label: { Label("翻译", systemImage: "character.bubble") }
                NavigationLink { EntriesView(kind: .mistake) } label: { Label("错题本", systemImage: "pencil.and.outline") }
                NavigationLink { EntriesView(kind: .word) } label: { Label("英语生词卡", systemImage: "character.book.closed") }
                NavigationLink { EntriesView(kind: .progress) } label: { Label("学习进度条", systemImage: "chart.bar.fill") }
                NavigationLink { EntriesView(kind: .minimum) } label: { Label("每日最低任务", systemImage: "checkmark.seal") }
                NavigationLink { SplitterView() } label: { Label("任务拆分器", systemImage: "list.bullet.indent") }
                NavigationLink { BacklogView() } label: { Label("复习积压整理", systemImage: "tray.full") }
                NavigationLink { WeeklyView() } label: { Label("学习周报", systemImage: "chart.bar.xaxis") }
            }
            Section("生活手账") {
                ForEach([EntryKind.workout, .body, .exam, .inbox, .resource], id: \.self) { kind in
                    NavigationLink { EntriesView(kind: kind) } label: { Label(kind.rawValue, systemImage: kind.icon) }
                }
                NavigationLink { BudgetView() } label: { Label("预算与攒钱进度", systemImage: "banknote") }
                NavigationLink { CalculatorView() } label: { Label("快速计算器", systemImage: "plus.forwardslash.minus") }
            }
            Section("提醒与备份") {
                Button("开启 / 检查通知权限") { Task { await store.enableNotifications() } }
                Text(store.notice).font(.footnote).foregroundStyle(.secondary)
                NavigationLink("备份与恢复") { BackupView() }
                Text("上次备份：\(store.data.extras.lastBackup.formatted(date: .abbreviated, time: .shortened))。每 7 天提醒导出一次；请定期打开应用刷新最多 60 条提醒。首次显示安装时间。 ").font(.footnote).foregroundStyle(.secondary)
            }
        }.scrollContentBackground(.hidden).background(MagicBackground()).navigationTitle("魔女工具箱") }
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
                switch result {
                case .failure(let error): store.error = error.localizedDescription
                case .success: store.data.extras.lastBackup = Date(); store.save()
                }
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
                          imported.extras.savings.isFinite, imported.extras.savingsGoal.isFinite,
                          imported.extras.savings >= 0, imported.extras.savingsGoal > 0,
                          imported.extras.entries.count <= 50000,
                          imported.extras.entries.allSatisfy({ $0.amount.isFinite && $0.goal.isFinite && $0.amount >= 0 && $0.goal >= 0 }),
                          Set(imported.extras.entries.map(\.id)).count == imported.extras.entries.count,
                          (0...9_999_999_999).contains(imported.extras.budgetCents),
                          imported.focus.allSatisfy({ (1...180).contains($0.minutes) }),
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

// MARK: - Magic journal design
struct MagicBackground: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.10, green: 0.08, blue: 0.19), Color(red: 0.06, green: 0.07, blue: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
    }
}
struct WitchHero: View {
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Image("Witch").resizable().scaledToFill().frame(height: 270).clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 6) {
                Label("THE WITCH'S STUDY JOURNAL", systemImage: "sparkles").font(.system(size: 10, weight: .semibold, design: .rounded)).tracking(1.2)
                Text("下一站，更好的自己").font(.title2.bold())
                Text("把知识装进行囊，让每一小步都算数。").font(.caption).foregroundStyle(.white.opacity(0.8))
            }.foregroundStyle(.white).padding(20)
        }.frame(height: 270).clipShape(RoundedRectangle(cornerRadius: 24)).accessibilityElement(children: .combine)
    }
}
struct Metric: View {
    var title: String; var value: String
    var body: some View { VStack(alignment: .leading, spacing: 6) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.title3.bold().monospacedDigit()) } }
}

enum EntryKind: String, Codable, CaseIterable {
    case mistake = "错题本", word = "英语生词卡", progress = "学习进度条", minimum = "每日最低任务"
    case workout = "健身训练卡", body = "体重与腰围", exam = "考试倒计时", inbox = "随手收集箱", resource = "资料收藏夹"
    var icon: String {
        switch self {
        case .mistake: "pencil.and.outline"
        case .word: "character.book.closed"
        case .progress: "chart.bar.fill"
        case .minimum: "checkmark.seal"
        case .workout: "figure.strengthtraining.traditional"
        case .body: "figure.stand"
        case .exam: "calendar.badge.clock"
        case .inbox: "tray"
        case .resource: "bookmark"
        }
    }
    var hint: String {
        switch self {
        case .mistake: "题目写在标题，解法和易错点写在正文；保存后自动进入间隔复习。"
        case .word: "单词写在标题，释义和例句写在正文；保存后自动生成复习卡。"
        case .progress: "用已完成量和总量记录教材、课程或章节进度。"
        case .minimum: "给自己设一个容易开始的最低任务，每天独立打卡。"
        case .workout: "记录动作、组数、时长、重量和动作提示，每次训练可打卡。"
        case .body: "按日期记录体重（公斤）与腰围（厘米），只与自己比较。"
        case .exam: "记录考试日期，倒计时按自然日计算；提醒可加入待办。"
        case .inbox: "先抓住灵感，之后一键转成待办或笔记。"
        case .resource: "保存教材和课程链接，只接受 https/http 地址。"
        }
    }
}
struct JournalEntry: Codable, Identifiable {
    var id = UUID()
    var kind: EntryKind
    var title: String
    var detail = ""
    var amount: Double = 0
    var goal: Double = 0
    var date = Date()
    var checks: [String] = []
    var reviewID: UUID? = nil
}
struct Extras: Codable {
    var entries: [JournalEntry] = []
    var budgetCents = 0
    var savings: Double = 0
    var savingsGoal: Double = 30000
    var lastBackup = Date()
}
func dayKey(_ date: Date = Date()) -> String {
    let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
    return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
}
@MainActor extension Store {
    func check(_ id: UUID) {
        guard let i = data.extras.entries.firstIndex(where: { $0.id == id }) else { return }
        let key = dayKey()
        if data.extras.entries[i].checks.contains(key) { data.extras.entries[i].checks.removeAll { $0 == key } }
        else { data.extras.entries[i].checks.append(key) }
        save()
    }
    func put(_ entry: JournalEntry) {
        var entry = entry
        if entry.kind == .mistake || entry.kind == .word {
            let prefix = entry.kind == .mistake ? "错题 · " : "单词 · "
            if let id = entry.reviewID, let i = data.reviews.firstIndex(where: { $0.id == id }) {
                data.reviews[i].title = prefix + entry.title; data.reviews[i].content = entry.detail
            } else {
                let review = Review(title: prefix + entry.title, content: entry.detail, due: Calendar.current.date(byAdding: .day, value: 1, to: Date())!)
                entry.reviewID = review.id; data.reviews.append(review)
            }
        }
        if let i = data.extras.entries.firstIndex(where: { $0.id == entry.id }) { data.extras.entries[i] = entry }
        else { data.extras.entries.append(entry) }
        save()
    }
}
struct MiniTaskRows: View {
    @EnvironmentObject var store: Store
    var body: some View {
        let items = store.data.extras.entries.filter { $0.kind == .minimum }
        if items.isEmpty { Text("例如：3 道数学题、5 个单词、读 1 页 Python。 ").font(.footnote).foregroundStyle(.secondary) }
        ForEach(items) { e in
            Button { store.check(e.id) } label: {
                Label(e.title, systemImage: e.checks.contains(dayKey()) ? "checkmark.circle.fill" : "circle")
            }
        }
    }
}
struct EntriesView: View {
    @EnvironmentObject var store: Store
    let kind: EntryKind
    @State private var adding = false
    @State private var query = ""
    var items: [JournalEntry] {
        store.data.extras.entries.filter { $0.kind == kind && (query.isEmpty || ($0.title + $0.detail).localizedCaseInsensitiveContains(query)) }.sorted { kind == .exam ? $0.date < $1.date : $0.date > $1.date }
    }
    var body: some View {
        List {
            Section { Text(kind.hint).font(.footnote).foregroundStyle(.secondary) }
            if kind == .body, let latest = items.first {
                Section("最近记录") {
                    Metric(title: latest.date.formatted(date: .abbreviated, time: .omitted), value: String(format: "%.1f kg · %.1f cm", latest.amount, latest.goal))
                    if items.count > 1, let first = items.last { Text("与首条记录相比：体重 \(latest.amount - first.amount, specifier: "%+.1f") kg，腰围 \(latest.goal - first.goal, specifier: "%+.1f") cm").font(.caption) }
                }
            }
            if items.isEmpty { ContentUnavailableView("还没有记录", systemImage: kind.icon, description: Text("点右上角添加第一条。")) }
            ForEach(items) { entry in
                Section {
                    NavigationLink { EntryDetail(id: entry.id) } label: { EntrySummary(entry: entry) }
                    if kind == .minimum || kind == .workout {
                        Button(entry.checks.contains(dayKey()) ? "今天已完成 · 点此撤销" : "今天完成了") { store.check(entry.id) }
                    }
                }.swipeActions {
                    Button("删除", role: .destructive) {
                        store.data.extras.entries.removeAll { $0.id == entry.id }
                        // Keep linked learning cards: deleting a journal entry must not silently erase its review history.
                        store.save()
                    }
                }
            }
        }.scrollContentBackground(.hidden).background(MagicBackground()).navigationTitle(kind.rawValue)
            .searchable(text: $query, prompt: "搜索记录")
            .toolbar { Button("添加", systemImage: "plus") { adding = true } }
            .sheet(isPresented: $adding) { NavigationStack { EntryEditor(entry: JournalEntry(kind: kind, title: "")) } }
    }
}
struct EntrySummary: View {
    let entry: JournalEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.title.isEmpty ? entry.kind.rawValue : entry.title).font(.headline)
            if entry.kind == .progress {
                ProgressView(value: min(1, entry.amount / max(1, entry.goal)))
                Text("\(entry.amount, specifier: "%.0f") / \(entry.goal, specifier: "%.0f") · \(min(100, entry.amount / max(1, entry.goal) * 100), specifier: "%.0f")%").font(.caption).foregroundStyle(.secondary)
            } else if entry.kind == .exam {
                let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: Calendar.current.startOfDay(for: entry.date)).day ?? 0
                Text(days > 0 ? "还有 \(days) 天" : days == 0 ? "就是今天" : "已过去 \(-days) 天").foregroundStyle(.purple).font(.title3.bold())
                Text(entry.date, style: .date).font(.caption).foregroundStyle(.secondary)
            } else if entry.kind == .body {
                Text("\(entry.amount, specifier: "%.1f") kg · 腰围 \(entry.goal, specifier: "%.1f") cm").font(.subheadline)
                Text(entry.date, style: .date).font(.caption).foregroundStyle(.secondary)
            } else if entry.kind == .word || entry.kind == .mistake {
                Text("主动回忆 · 点开后揭示答案").font(.caption).foregroundStyle(.secondary)
            } else {
                Text(entry.detail).lineLimit(2).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
    }
}
struct EntryDetail: View {
    @EnvironmentObject var store: Store
    let id: UUID
    @State private var editing = false
    @State private var reveal = false
    @State private var message: String?
    var entry: JournalEntry? { store.data.extras.entries.first { $0.id == id } }
    var body: some View {
        Group {
            if let e = entry {
                List {
                    Section { EntrySummary(entry: e) }
                    if e.kind == .word || e.kind == .mistake {
                        Section("先回忆，再看答案") {
                            Button(reveal ? "隐藏答案" : "显示完整答案") { reveal.toggle() }
                            if reveal { Text(e.detail).textSelection(.enabled) }
                            if let reviewID = e.reviewID, store.data.reviews.contains(where: { $0.id == reviewID }) {
                                NavigationLink("去自测并安排下次复习") { ReviewDetail(id: reviewID) }
                            } else { Button("重新加入复习") { store.put(e) } }
                        }
                    } else {
                        Section("内容") { Text(e.detail.isEmpty ? "尚未填写正文" : e.detail).textSelection(.enabled) }
                    }
                    if e.kind == .progress {
                        Button("完成下一单位") { var value = e; value.amount = min(e.goal, e.amount + 1); store.put(value) }.disabled(e.amount >= e.goal)
                    }
                    if e.kind == .minimum || e.kind == .workout {
                        Button(e.checks.contains(dayKey()) ? "撤销今天打卡" : "今天完成了") { store.check(id) }
                        Text("累计完成 \(e.checks.count) 天").font(.caption)
                    }
                    if e.kind == .resource, let url = URL(string: e.detail.trimmingCharacters(in: .whitespacesAndNewlines)), ["https", "http"].contains(url.scheme?.lowercased() ?? "") { Link("打开资料", destination: url) }
                    if e.kind == .inbox || e.kind == .exam {
                        Button("转成待办") {
                            store.data.todos.append(Todo(title: e.title + (e.detail.isEmpty ? "" : " · " + e.detail), date: e.kind == .exam ? e.date : Date(), remind: e.kind == .exam))
                            store.save(); message = "已添加到待办"
                        }
                        Button("保存为笔记") { store.data.notes.append(Note(title: e.title, text: e.detail)); store.save(); message = "已添加到笔记" }
                    }
                    if let message { Text(message).foregroundStyle(.secondary) }
                }.scrollContentBackground(.hidden).background(MagicBackground())
                .toolbar { Button("编辑") { editing = true } }
                .sheet(isPresented: $editing) { NavigationStack { EntryEditor(entry: e) } }
            } else { ContentUnavailableView("记录已删除", systemImage: "tray") }
        }.navigationTitle(entry?.kind.rawValue ?? "记录")
    }
}
struct EntryEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State var entry: JournalEntry
    @State private var amount = ""
    @State private var goal = ""
    var numeric: Bool { entry.kind == .progress || entry.kind == .body }
    var valid: Bool {
        guard !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if numeric {
            guard let a = Double(amount), let g = Double(goal), a.isFinite, g.isFinite, a >= 0, g > 0 else { return false }
            if entry.kind == .progress { return a <= g }
            return a > 0 && a <= 1000 && g <= 1000
        }
        if entry.kind == .resource {
            guard let url = URL(string: entry.detail.trimmingCharacters(in: .whitespacesAndNewlines)), let host = url.host, !host.isEmpty else { return false }
            return ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        }
        return true
    }
    var body: some View {
        Form {
            Section { TextField(entry.kind == .word ? "单词 / 短语" : "标题", text: $entry.title) }
            Section(entry.kind == .resource ? "资料链接（https://…）" : entry.kind == .workout ? "动作、组数、重量、时长与提示" : "正文 / 答案 / 释义和例句") {
                TextEditor(text: $entry.detail).frame(minHeight: 160)
            }
            if numeric {
                TextField(entry.kind == .body ? "体重（kg）" : "已完成量", text: $amount).keyboardType(.decimalPad)
                TextField(entry.kind == .body ? "腰围（cm）" : "总量", text: $goal).keyboardType(.decimalPad)
                if !valid { Text(entry.kind == .body ? "请输入有效体重与腰围。" : "完成量需在 0 与总量之间，总量须大于 0。").font(.caption).foregroundStyle(.secondary) }
            }
            if entry.kind == .body || entry.kind == .exam { DatePicker(entry.kind == .exam ? "考试日期与时间" : "记录时间", selection: $entry.date) }
            Text(entry.kind.hint).font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("编辑 · " + entry.kind.rawValue)
        .onAppear { amount = String(entry.amount); goal = entry.goal > 0 ? String(entry.goal) : "" }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存") {
                entry.title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if numeric { entry.amount = Double(amount) ?? 0; entry.goal = Double(goal) ?? 0 }
                store.put(entry); dismiss()
            }.disabled(!valid) }
        }
    }
}
struct SplitterView: View {
    @EnvironmentObject var store: Store
    @State private var project = ""
    @State private var steps = ""
    @State private var date = Date()
    @State private var added = false
    var lines: [String] { steps.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
    var body: some View {
        Form {
            TextField("目标，例如：学完 Python 第 2 章", text: $project)
            Section("写下最小行动，每行一步") { TextEditor(text: $steps).frame(minHeight: 200) }
            Text("例如：打开教材 → 读 2 页 → 运行示例 → 独立写 1 题。请一行写一步；将按所选时间、每隔 30 分钟创建待办，可再去待办页调整。 ").font(.footnote).foregroundStyle(.secondary)
            DatePicker("开始时间", selection: $date)
            Button("生成 \(lines.count) 项待办") {
                for (index, line) in lines.prefix(50).enumerated() {
                    store.data.todos.append(Todo(title: (project.isEmpty ? "" : project + " · ") + line, date: date.addingTimeInterval(Double(index * 1800))))
                }
                store.save(); added = true
            }.disabled(lines.isEmpty || lines.count > 50)
        }.navigationTitle("任务拆分器").alert("已加入待办", isPresented: $added) { Button("知道了") { steps = "" } }
    }
}
struct BacklogView: View {
    @EnvironmentObject var store: Store
    @State private var days = 3
    @State private var confirm = false
    var backlog: [Review] { store.data.reviews.filter { !$0.finished && $0.due <= Date() }.sorted { $0.due < $1.due } }
    var body: some View {
        List {
            Section {
                Text("积压 \(backlog.count) 项。先保留自测记录，再将到期项目平均分配到接下来的几天。此操作只调整时间，不会标为已掌握。 ").font(.footnote)
                Stepper("分摊到 \(days) 天", value: $days, in: 1...14)
                Button("整理到期复习") { confirm = true }.disabled(backlog.isEmpty)
            }
            ForEach(backlog) { r in NavigationLink(r.title) { ReviewDetail(id: r.id) } }
        }.navigationTitle("复习积压整理")
        .confirmationDialog("重新安排全部 \(backlog.count) 项到期复习？", isPresented: $confirm, titleVisibility: .visible) {
            Button("确认分摊") {
                let ids = backlog.map(\.id)
                for (offset, id) in ids.enumerated() {
                    guard let i = store.data.reviews.firstIndex(where: { $0.id == id }) else { continue }
                    let day = Calendar.current.date(byAdding: .day, value: offset % days + 1, to: Calendar.current.startOfDay(for: Date()))!
                    store.data.reviews[i].due = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
                }
                store.save()
            }
        }
    }
}
struct WeeklyView: View {
    @EnvironmentObject var store: Store
    var start: Date { Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date()))! }
    var focus: [FocusRecord] { store.data.focus.filter { $0.date >= start && $0.date <= Date() } }
    var summary: String {
        "知序 · 最近七天学习周报\n专注：\(focus.reduce(0) { $0 + $1.minutes }) 分钟 / \(focus.count) 轮\n完成待办：\(store.data.todos.filter { ($0.completedAt ?? .distantPast) >= start && $0.done }.count) 项\n待复习：\(store.data.reviews.filter { !$0.finished && $0.due <= Date() }.count) 项\n下一步：先完成今天的最低任务，再做一轮专注。"
    }
    var body: some View {
        List {
            Section("最近 7 天") { Text(summary).textSelection(.enabled) }
            Section("每日专注") {
                ForEach(0..<7, id: \.self) { offset in
                    let date = Calendar.current.date(byAdding: .day, value: offset, to: start)!
                    let total = focus.filter { Calendar.current.isDate($0.date, inSameDayAs: date) }.reduce(0) { $0 + $1.minutes }
                    VStack(alignment: .leading) {
                        HStack { Text(date, format: .dateTime.month().day()); Spacer(); Text("\(total) 分钟") }.font(.caption)
                        ProgressView(value: min(1, Double(total) / 120))
                    }.padding(.vertical, 4)
                }
                Text("条形图以 120 分钟为显示刻度，超过时仍显示真实分钟数。旧版已完成但无完成日期的待办不计入本周。 ").font(.caption).foregroundStyle(.secondary)
            }
            Section("本周主动回忆") {
                LabeledContent("最近复习过的知识点", value: "\(store.data.reviews.filter { ($0.lastReviewed ?? .distantPast) >= start }.count) 项")
                Text("统计知识点数量；同一卡片复习多次仍按一项计。 ").font(.caption).foregroundStyle(.secondary)
            }
            ShareLink("分享学习周报", item: summary)
        }.navigationTitle("学习周报")
    }
}
struct BudgetView: View {
    @EnvironmentObject var store: Store
    @State private var budget = ""
    @State private var saved = ""
    @State private var target = ""
    @State private var done = false
    var valid: Bool {
        guard let b = Double(budget), let s = Double(saved), let t = Double(target) else { return false }
        return b.isFinite && s.isFinite && t.isFinite && b >= 0 && b <= 99_999_999 && s >= 0 && s <= 99_999_999 && t > 0 && t <= 99_999_999
    }
    var body: some View {
        Form {
            Section("本月预算（人民币）") { TextField("预算，0 表示不设置", text: $budget).keyboardType(.decimalPad) }
            Section("攒钱目标") {
                TextField("当前已攒金额", text: $saved).keyboardType(.decimalPad)
                TextField("目标金额", text: $target).keyboardType(.decimalPad)
                ProgressView(value: min(1, store.data.extras.savings / max(1, store.data.extras.savingsGoal)))
                Text("已攒 ¥\(store.data.extras.savings, specifier: "%.2f") / ¥\(store.data.extras.savingsGoal, specifier: "%.2f")").font(.caption)
                Text("金额手动更新；记账不会自动改变储蓄。预算按每个自然月统计支出。 ").font(.footnote).foregroundStyle(.secondary)
            }
            Button("保存设置") {
                guard valid, let b = Double(budget), let s = Double(saved), let t = Double(target) else { return }
                store.data.extras.budgetCents = Int((b * 100).rounded()); store.data.extras.savings = s; store.data.extras.savingsGoal = t
                store.save(); done = true
            }.disabled(!valid)
        }.navigationTitle("预算与攒钱")
            .onAppear { budget = String(Double(store.data.extras.budgetCents) / 100); saved = String(store.data.extras.savings); target = String(store.data.extras.savingsGoal) }
            .alert("设置已保存", isPresented: $done) { Button("知道了") {} }
    }
}
struct CalculatorView: View {
    @State private var left = ""
    @State private var right = ""
    @State private var operation = "+"
    var result: String {
        guard let a = Double(left), let b = Double(right), a.isFinite, b.isFinite else { return "请输入两个数" }
        if operation == "÷" && b == 0 { return "除数不能为 0" }
        let value: Double
        switch operation { case "−": value = a - b; case "×": value = a * b; case "÷": value = a / b; default: value = a + b }
        return value.isFinite ? value.formatted(.number.precision(.significantDigits(1...12))) : "超出计算范围"
    }
    var body: some View {
        Form {
            TextField("第一个数（支持负数和小数）", text: $left).keyboardType(.numbersAndPunctuation)
            Picker("运算", selection: $operation) { ForEach(["+", "−", "×", "÷"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
            TextField("第二个数", text: $right).keyboardType(.numbersAndPunctuation)
            Section("结果") { Text(result).font(.title2.monospacedDigit()).textSelection(.enabled) }
            Button("清空") { left = ""; right = "" }
        }.navigationTitle("快速计算器")
    }
}
