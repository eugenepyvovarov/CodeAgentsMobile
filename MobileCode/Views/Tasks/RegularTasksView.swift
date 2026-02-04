//
//  RegularTasksView.swift
//  CodeAgentsMobile
//
//  Purpose: Manage scheduled agent tasks
//

import SwiftUI
import SwiftData

struct RegularTasksView: View {
    @StateObject private var projectContext = ProjectContext.shared
    @StateObject private var claudeService = ClaudeCodeService.shared
    @Environment(\.modelContext) private var modelContext
    @AppStorage(ClaudeProviderConfigurationStore.configurationKey) private var claudeProviderConfigurationData = Data()
    @Query(
        sort: [SortDescriptor(\AgentScheduledTask.createdAt, order: .reverse)]
    ) private var allTasks: [AgentScheduledTask]
    @StateObject private var syncReporter = TaskSyncReporter()

    @State private var providerMismatch: ClaudeProviderMismatch?
    @State private var showingProviderSettings = false
    @State private var showingNewTask = false
    @State private var editingTask: AgentScheduledTask?

    var body: some View {
        let isLocked = providerMismatch != nil
        NavigationStack {
            Group {
                if projectContext.activeProject == nil {
                    ContentUnavailableView {
                        Label("No Active Agent", systemImage: "person.crop.circle.badge.xmark")
                    } description: {
                        Text("Select an agent to schedule regular tasks.")
                    }
                } else if tasks.isEmpty {
                    VStack(spacing: 16) {
                        ContentUnavailableView {
                            Label("No Tasks Yet", systemImage: "clock.badge.checkmark")
                        } description: {
                            Text("Create a task to send a prompt on a schedule.")
                        } actions: {
                            PrimaryGlassButton(action: { showingNewTask = true }) {
                                Label("Add Task", systemImage: "plus")
                            }
                            .disabled(isLocked)
                        }
                    }
                    .padding(.horizontal, 16)
                } else {
                    List {
                        Section("Tasks") {
                            ForEach(tasks) { task in
                                RegularTaskRow(task: task,
                                               isEnabled: binding(for: task)) {
                                    editingTask = task
                                }
                                .disabled(isLocked)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    if !isLocked {
                                        Button(role: .destructive) {
                                            Task { await deleteTask(task) }
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                            .onDelete(perform: deleteTasks)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Regular Tasks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    ConnectionStatusView()
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingNewTask = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(isLocked)
                }
            }
        }
        .modifier(
            TaskTopOverlayModifier(
                providerMismatch: providerMismatch,
                syncState: syncReporter.state,
                lastSuccess: syncReporter.lastSuccess,
                showSyncPill: shouldShowStatusPill,
                onClearChat: { clearChatAndResetProviderMarker() },
                onChangeProvider: { showingProviderSettings = true }
                )
        )
        .onAppear {
            refreshProviderMismatch()
        }
        .sheet(isPresented: $showingNewTask) {
            RegularTaskEditorView(syncReporter: syncReporter)
        }
        .sheet(item: $editingTask) { task in
            RegularTaskEditorView(task: task, syncReporter: syncReporter)
        }
        .task(id: projectContext.activeProject?.id) {
            refreshProviderMismatch()
            await refreshTasks()
        }
        .onChange(of: projectContext.activeProject?.id) { _, _ in
            refreshProviderMismatch()
        }
        .onChange(of: claudeProviderConfigurationData) { _, _ in
            refreshProviderMismatch()
        }
        .sheet(isPresented: $showingProviderSettings) {
            NavigationStack {
                ClaudeProviderSettingsView()
            }
        }
    }

    private var tasks: [AgentScheduledTask] {
        guard let project = projectContext.activeProject else { return [] }
        let filtered = allTasks.filter { $0.projectId == project.id }
        return filtered.sorted { lhs, rhs in
            if lhs.isEnabled != rhs.isEnabled {
                return lhs.isEnabled && !rhs.isEnabled
            }
            let lhsNext = lhs.nextRunAt ?? .distantFuture
            let rhsNext = rhs.nextRunAt ?? .distantFuture
            if lhsNext != rhsNext {
                return lhsNext < rhsNext
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    private func binding(for task: AgentScheduledTask) -> Binding<Bool> {
        Binding(
            get: { task.isEnabled },
            set: { newValue in
                guard providerMismatch == nil else { return }
                let previousValue = task.isEnabled
                task.isEnabled = newValue
                task.markUpdated()
                Task {
                    await syncTask(task, previousValue: previousValue)
                }
            }
        )
    }

    private var shouldShowStatusPill: Bool {
        switch syncReporter.state {
        case .syncing, .error:
            return true
        case .idle:
            return false
        }
    }

    private func deleteTasks(at offsets: IndexSet) {
        guard providerMismatch == nil else { return }
        let tasksToDelete = offsets.map { tasks[$0] }
        Task {
            for task in tasksToDelete {
                await deleteTask(task)
            }
        }
    }

    private func refreshTasks() async {
        guard let project = projectContext.activeProject else { return }
        syncReporter.markSyncing()

        do {
            do {
                _ = try await ProxyAgentIdentityService.shared.ensureProxyAgentId(for: project, modelContext: modelContext)
            } catch {
                SSHLogger.log(
                    "Failed to ensure proxy agent id for tasks refresh (projectId=\(project.id)): \(error)",
                    level: .warning
                )
            }
            let remoteTasks = try await ProxyTaskService.shared.fetchTasks(for: project)
            applyRemoteTasks(remoteTasks, project: project)
            syncReporter.markSuccess()
        } catch {
            syncReporter.markError(error.localizedDescription)
        }
    }

    private func applyRemoteTasks(_ remoteTasks: [ProxyTaskRecord], project: RemoteProject) {
        var localByRemoteId: [String: AgentScheduledTask] = [:]
        for task in tasks {
            if let remoteId = task.remoteId {
                localByRemoteId[remoteId] = task
            }
        }

        for remote in remoteTasks {
            if let local = localByRemoteId[remote.id] {
                updateLocalTask(local, from: remote)
            } else if let schedule = remote.schedule, let prompt = remote.prompt {
                let newTask = AgentScheduledTask(
                    projectId: project.id,
                    title: remote.title ?? "",
                    prompt: prompt,
                    isEnabled: remote.isEnabled ?? true,
                    timeZoneId: remote.timeZoneId ?? TimeZone.current.identifier,
                    frequency: schedule.frequency,
                    interval: schedule.interval,
                    weekdayMask: schedule.weekdayMask,
                    monthlyMode: schedule.monthlyMode,
                    dayOfMonth: schedule.dayOfMonth,
                    ordinalWeek: schedule.ordinalWeek,
                    ordinalWeekday: schedule.ordinalWeekday,
                    monthOfYear: schedule.monthOfYear,
                    timeOfDayMinutes: schedule.timeOfDayMinutes,
                    nextRunAt: remote.nextRunAt,
                    lastRunAt: remote.lastRunAt,
                    remoteId: remote.id
                )
                modelContext.insert(newTask)
            }
        }
    }

    private func updateLocalTask(_ task: AgentScheduledTask, from remote: ProxyTaskRecord) {
        if let title = remote.title {
            task.title = title
        }
        if let prompt = remote.prompt {
            task.prompt = prompt
        }
        if let enabled = remote.isEnabled {
            task.isEnabled = enabled
        }
        if let timeZoneId = remote.timeZoneId {
            task.timeZoneId = timeZoneId
        }
        if let schedule = remote.schedule {
            task.frequency = schedule.frequency
            task.interval = schedule.interval
            task.weekdayMask = schedule.weekdayMask
            task.monthlyMode = schedule.monthlyMode
            task.dayOfMonth = schedule.dayOfMonth
            task.ordinalWeek = schedule.ordinalWeek
            task.ordinalWeekday = schedule.ordinalWeekday
            task.monthOfYear = schedule.monthOfYear
            task.timeOfDayMinutes = schedule.timeOfDayMinutes
        }
        task.nextRunAt = remote.nextRunAt
        task.lastRunAt = remote.lastRunAt
        task.remoteId = remote.id
        task.markUpdated()
    }

    private func syncTask(_ task: AgentScheduledTask, previousValue: Bool) async {
        guard providerMismatch == nil else { return }
        guard let project = projectContext.activeProject else { return }
        syncReporter.markSyncing()

        do {
            do {
                _ = try await ProxyAgentIdentityService.shared.ensureProxyAgentId(for: project, modelContext: modelContext)
            } catch {
                SSHLogger.log("Failed to ensure proxy agent id for task sync (projectId=\(project.id)): \(error)", level: .warning)
            }
            let record = try await ProxyTaskService.shared.upsertTask(task, project: project)
            applySyncRecord(record, to: task)
            syncReporter.markSuccess()
        } catch {
            task.isEnabled = previousValue
            task.markUpdated()
            syncReporter.markError(error.localizedDescription)
        }
    }

    private func deleteTask(_ task: AgentScheduledTask) async {
        guard providerMismatch == nil else { return }
        guard let project = projectContext.activeProject else { return }
        syncReporter.markSyncing()

        do {
            try await ProxyTaskService.shared.deleteTask(task, project: project)
            modelContext.delete(task)
            syncReporter.markSuccess()
        } catch {
            syncReporter.markError(error.localizedDescription)
        }
    }

    private func applySyncRecord(_ record: ProxyTaskRecord, to task: AgentScheduledTask) {
        task.remoteId = record.id
        if let nextRun = record.nextRunAt {
            task.nextRunAt = nextRun
        }
        if let lastRun = record.lastRunAt {
            task.lastRunAt = lastRun
        }
        task.markUpdated()
    }

    private func refreshProviderMismatch() {
        providerMismatch = ClaudeProviderMismatchGuard.mismatch(for: projectContext.activeProject)
    }

    private func clearChatAndResetProviderMarker() {
        guard let project = projectContext.activeProject else { return }

        Task { @MainActor in
            project.lastSuccessfulClaudeProviderRawValue = nil
            project.activeStreamingMessageId = nil
            claudeService.clearSessions()

            do {
                let projectId: UUID? = project.id
                let descriptor = FetchDescriptor<Message>(
                    predicate: #Predicate { message in
                        message.projectId == projectId
                    }
                )
                let fetched = try modelContext.fetch(descriptor)
                for message in fetched {
                    modelContext.delete(message)
                }
            } catch {
                SSHLogger.log("Failed to clear messages for project \(project.id): \(error)", level: .warning)
            }

            if claudeService.isProxyChatEnabled {
                do {
                    try await claudeService.resetProxyConversation(project: project)
                } catch {
                    SSHLogger.log("Failed to reset proxy conversation for project \(project.id): \(error)", level: .warning)
                }
            }

            do {
                try modelContext.save()
            } catch {
                SSHLogger.log("Failed to persist chat reset for project \(project.id): \(error)", level: .warning)
            }

            refreshProviderMismatch()
            NotificationCenter.default.post(
                name: .projectChatDidReset,
                object: nil,
                userInfo: ["projectId": project.id]
            )
        }
    }
}

private struct RegularTaskRow: View {
    let task: AgentScheduledTask
    @Binding var isEnabled: Bool
    let onEdit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayTitle)
                        .font(.headline)
                        .lineLimit(1)

                    Text(TaskScheduleFormatter.summary(for: task))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    let preview = TaskScheduleFormatter.promptPreview(task.prompt)
                    if !preview.isEmpty {
                        Text(preview)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    if !task.isEnabled {
                        Text("Disabled")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .opacity(task.isEnabled ? 1 : 0.7)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            Toggle("", isOn: $isEnabled)
                .labelsHidden()
        }
        .padding(.vertical, 2)
    }

    private var displayTitle: String {
        let trimmed = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        let preview = TaskScheduleFormatter.promptPreview(task.prompt)
        return preview.isEmpty ? "Untitled Task" : preview
    }
}

private struct TaskSyncStatusPillView: View {
    let state: TaskSyncState
    let lastSuccess: Date?

    var body: some View {
        let content = HStack(spacing: 8) {
            if status.showsProgress {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .scaleEffect(0.85)
                    .tint(status.tint)
            } else {
                Image(systemName: status.icon)
                    .font(.caption)
                    .foregroundColor(status.tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(status.lines.indices, id: \.self) { index in
                    Text(status.lines[index])
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)

        Group {
            if #available(iOS 26.0, *) {
                content
                    .glassEffect(.regular.tint(status.tint.opacity(0.16)), in: .capsule)
            } else {
                content
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(status.tint.opacity(0.25), lineWidth: 0.6)
                    )
            }
        }
    }

    private var status: StatusPresentation {
        switch state {
        case .syncing:
            return StatusPresentation(lines: ["Syncing tasks..."],
                                      icon: "arrow.triangle.2.circlepath",
                                      tint: .accentColor,
                                      showsProgress: true)
        case .error(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            let lines = trimmed.isEmpty ? ["Sync failed"] : ["Sync failed", trimmed]
            return StatusPresentation(lines: lines,
                                      icon: "exclamationmark.triangle",
                                      tint: .orange,
                                      showsProgress: false)
        case .idle:
            if let lastSuccess {
                let dateString = StatusPresentation.dateFormatter.string(from: lastSuccess)
                return StatusPresentation(lines: ["Last synced \(dateString)"],
                                          icon: "checkmark.circle",
                                          tint: .green,
                                          showsProgress: false)
            }
            return StatusPresentation(lines: ["Not synced yet"],
                                      icon: "clock.badge.checkmark",
                                      tint: .secondary,
                                      showsProgress: false)
        }
    }

    private struct StatusPresentation {
        let lines: [String]
        let icon: String
        let tint: Color
        let showsProgress: Bool

        static let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            return formatter
        }()
    }
}

private struct TaskTopOverlayModifier: ViewModifier {
    let providerMismatch: ClaudeProviderMismatch?
    let syncState: TaskSyncState
    let lastSuccess: Date?
    let showSyncPill: Bool
    let onClearChat: () -> Void
    let onChangeProvider: () -> Void

    private var isVisible: Bool {
        providerMismatch != nil || showSyncPill
    }

    func body(content: Content) -> some View {
        Group {
            if #available(iOS 26.0, *) {
                content
                    .safeAreaBar(edge: .top) {
                        overlayContent
                    }
            } else {
                if isVisible {
                    content
                        .toolbarBackground(.hidden, for: .navigationBar)
                        .safeAreaInset(edge: .top, spacing: 0) {
                            overlayInset
                        }
                } else {
                    content
                }
            }
        }
    }

    @ViewBuilder
    private var overlayContent: some View {
        if isVisible {
            VStack(spacing: 6) {
                if let providerMismatch {
                    ClaudeProviderResetBannerView(
                        mismatch: providerMismatch,
                        onClearChat: onClearChat,
                        onChangeProvider: onChangeProvider
                    )
                }
                if showSyncPill {
                    TaskSyncStatusPillView(state: syncState, lastSuccess: lastSuccess)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var overlayInset: some View {
        if isVisible {
            VStack(spacing: 6) {
                if let providerMismatch {
                    ClaudeProviderResetBannerView(
                        mismatch: providerMismatch,
                        onClearChat: onClearChat,
                        onChangeProvider: onChangeProvider
                    )
                }
                if showSyncPill {
                    TaskSyncStatusPillView(state: syncState, lastSuccess: lastSuccess)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 4)
        }
    }
}

#Preview {
    let container = try? ModelContainer(
        for: AgentScheduledTask.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )

    return NavigationStack {
        RegularTasksView()
    }
    .modelContainer(container!)
}
