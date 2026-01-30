//
//  RegularTaskEditorView.swift
//  CodeAgentsMobile
//
//  Purpose: Create and edit scheduled agent tasks
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct RegularTaskEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @StateObject private var projectContext = ProjectContext.shared

    let task: AgentScheduledTask?
    private let syncReporter: TaskSyncReporter?

    @State private var title: String
    @State private var promptBody: String
    @State private var isEnabled: Bool
    @State private var frequency: TaskFrequency
    @State private var interval: Int
    @State private var weekdayMask: Int
    @State private var monthlyMode: TaskMonthlyMode
    @State private var dayOfMonth: Int
    @State private var ordinalWeek: WeekdayOrdinal
    @State private var ordinalWeekday: Weekday
    @State private var monthOfYear: Int
    @State private var timeOfDay: Date
    @State private var timeZoneId: String

    @State private var selectedSkillName: String?
    @State private var selectedSkillSlug: String?
    @State private var attachments: [ChatComposerAttachment]
    @State private var showingSkillPicker = false
    @State private var showingProjectFilePicker = false
    @State private var showingLocalFileImporter = false
    @State private var isUploadingAttachments = false

    @State private var isSaving = false
    @State private var showDeleteAlert = false
    @State private var showError = false
    @State private var errorMessage = ""

    init(task: AgentScheduledTask? = nil, syncReporter: TaskSyncReporter? = nil) {
        self.task = task
        self.syncReporter = syncReporter
        let calendar = Calendar.current
        let zoneId = task?.timeZoneId ?? TimeZone.current.identifier
        let minutes = task?.timeOfDayMinutes ?? AgentScheduledTask.defaultTimeOfDayMinutes(calendar: calendar)
        let timeDate = TaskScheduleFormatter.date(for: minutes, timeZoneId: zoneId, calendar: calendar)

        let initialFrequency = task?.frequency ?? .daily
        var initialInterval = task?.interval ?? 1
        initialInterval = max(1, initialInterval)
        switch initialFrequency {
        case .minutely:
            initialInterval = min(initialInterval, 60)
        case .hourly:
            initialInterval = min(initialInterval, 24)
        case .daily, .weekly, .monthly, .yearly:
            break
        }

        let composed = ComposedPromptParser.parse(task?.prompt ?? "")
        let initialSkillName = composed.skillName ?? composed.skillSlug.map { SkillNameFormatter.displayName(from: $0) }

        _title = State(initialValue: task?.title ?? "")
        _promptBody = State(initialValue: composed.message)
        _isEnabled = State(initialValue: task?.isEnabled ?? true)
        _frequency = State(initialValue: initialFrequency)
        _interval = State(initialValue: initialInterval)
        _weekdayMask = State(initialValue: task?.weekdayMask ?? WeekdayMask.mask(for: Weekday.current(in: calendar)))
        _monthlyMode = State(initialValue: task?.monthlyMode ?? .dayOfMonth)
        _dayOfMonth = State(initialValue: task?.dayOfMonth ?? calendar.component(.day, from: Date()))
        _ordinalWeek = State(initialValue: task?.ordinalWeek ?? .first)
        _ordinalWeekday = State(initialValue: task?.ordinalWeekday ?? Weekday.current(in: calendar))
        _monthOfYear = State(initialValue: task?.monthOfYear ?? calendar.component(.month, from: Date()))
        _timeOfDay = State(initialValue: timeDate)
        _timeZoneId = State(initialValue: zoneId)
        _selectedSkillName = State(initialValue: initialSkillName)
        _selectedSkillSlug = State(initialValue: composed.skillSlug)
        _attachments = State(
            initialValue: composed.fileReferences.map { reference in
                ChatComposerAttachment.projectFile(
                    displayName: RegularTaskEditorView.attachmentDisplayName(for: reference),
                    relativePath: reference
                )
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    GlassInfoCard(title: isEnabled ? "Schedule Preview" : "Schedule Preview (Disabled)",
                                  subtitle: scheduleSummary,
                                  systemImage: isEnabled ? "clock.badge.checkmark" : "clock.badge.xmark")
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                        .listRowBackground(Color.clear)
                }

                Section("Task") {
                    TextField("Title (optional)", text: $title)
                        .textInputAutocapitalization(.words)

                    TaskPromptAttachmentComposer(
                        selectedSkillName: selectedSkillDisplayName,
                        attachments: attachments,
                        isAddEnabled: projectContext.activeProject != nil && !isSaving && !isUploadingAttachments,
                        onAddSkill: {
                            showingSkillPicker = true
                        },
                        onAddProjectFile: {
                            showingProjectFilePicker = true
                        },
                        onAddLocalFile: {
                            showingLocalFileImporter = true
                        },
                        onClearSkill: {
                            selectedSkillName = nil
                            selectedSkillSlug = nil
                        },
                        onRemoveAttachment: { attachmentId in
                            attachments.removeAll(where: { $0.id == attachmentId })
                        }
                    )

                    ZStack(alignment: .topLeading) {
                        if promptBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Write the message the agent should receive on schedule.")
                                .foregroundColor(.secondary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                        }

                        TextEditor(text: $promptBody)
                            .frame(minHeight: 140)
                    }
                }

                Section("Schedule") {
                    Picker("Frequency", selection: $frequency) {
                        ForEach(TaskFrequency.allCases, id: \.self) { frequency in
                            Text(frequency.displayName).tag(frequency)
                        }
                    }
                    .pickerStyle(.menu)

                    Stepper(value: $interval, in: intervalRange) {
                        HStack {
                            Text("Every")
                            Spacer()
                            Text("\(interval) \(interval == 1 ? frequency.unitName : frequency.unitName + "s")")
                                .foregroundColor(.secondary)
                        }
                    }

                    if usesTimeOfDay {
                        DatePicker("Time", selection: $timeOfDay, displayedComponents: .hourAndMinute)
                    } else {
                        Text("Runs on clock boundaries in the selected time zone.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Time Zone")
                        Spacer()
                        Text(timeZoneDisplayName)
                            .foregroundColor(.secondary)
                    }
                }

                if frequency == .weekly {
                    Section("Repeat On") {
                        WeekdayPicker(mask: $weekdayMask)
                    }
                }

                if frequency == .monthly {
                    monthlySection
                }

                if frequency == .yearly {
                    yearlySection
                }

                Section {
                    Toggle("Enabled", isOn: $isEnabled)
                }

                if task != nil {
                    Section {
                        Button("Delete Task", role: .destructive) {
                            showDeleteAlert = true
                        }
                    }
                }
            }
            .navigationTitle(task == nil ? "New Task" : "Edit Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveTask()
                    }
                    .disabled(isSaveDisabled || isSaving || isUploadingAttachments)
                }
            }
            .alert("Delete Task?", isPresented: $showDeleteAlert) {
                Button("Delete", role: .destructive) {
                    deleteTask()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This will remove the task from the schedule.")
            }
            .alert("Error", isPresented: $showError) {
                Button("OK") { }
            } message: {
                Text(errorMessage)
            }
            .sheet(isPresented: $showingSkillPicker) {
                if let projectId = projectContext.activeProject?.id {
                    ChatSkillPickerSheet(
                        projectId: projectId,
                        selectedSkillSlug: selectedSkillSlug,
                        onSelect: { skill in
                            if let skill {
                                selectedSkillName = SkillNameFormatter.displayName(from: skill.name)
                                selectedSkillSlug = skill.slug
                            } else {
                                selectedSkillName = nil
                                selectedSkillSlug = nil
                            }
                        }
                    )
                } else {
                    NavigationStack {
                        ContentUnavailableView {
                            Label("No Active Agent", systemImage: "person.crop.circle.badge.xmark")
                        } description: {
                            Text("Select an agent before choosing skills.")
                        }
                        .navigationTitle("Select Skill")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showingSkillPicker = false }
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showingProjectFilePicker) {
                ChatProjectFilePickerSheet(onSelect: { attachment in
                    addAttachment(attachment)
                })
            }
            .fileImporter(
                isPresented: $showingLocalFileImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    importLocalFiles(urls)
                case .failure(let error):
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
            .overlay {
                if isUploadingAttachments {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Uploading attachments...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(20)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(radius: 10)
                }
            }
            .onChange(of: projectContext.activeProject?.id) { _, _ in
                selectedSkillName = nil
                selectedSkillSlug = nil
                attachments = []
            }
            .onChange(of: frequency) { _, _ in
                clampInterval()
            }
        }
    }

    private var scheduleSummary: String {
        TaskScheduleFormatter.summary(for: previewTask)
    }

    private var previewTask: AgentScheduledTask {
        AgentScheduledTask(projectId: projectContext.activeProject?.id ?? UUID(),
                           title: title,
                           prompt: promptBody.isEmpty ? "Untitled" : promptBody,
                           isEnabled: isEnabled,
                           timeZoneId: timeZoneId,
                           frequency: frequency,
                           interval: interval,
                           weekdayMask: weekdayMask,
                           monthlyMode: monthlyMode,
                           dayOfMonth: dayOfMonth,
                           ordinalWeek: ordinalWeek,
                           ordinalWeekday: ordinalWeekday,
                           monthOfYear: monthOfYear,
                           timeOfDayMinutes: usesTimeOfDay ? TaskScheduleFormatter.minutes(from: timeOfDay, timeZoneId: timeZoneId) : 0)
    }

    private var usesTimeOfDay: Bool {
        switch frequency {
        case .minutely, .hourly:
            return false
        case .daily, .weekly, .monthly, .yearly:
            return true
        }
    }

    private var intervalRange: ClosedRange<Int> {
        switch frequency {
        case .minutely:
            return 1...60
        case .hourly:
            return 1...24
        case .daily, .weekly, .monthly, .yearly:
            return 1...365
        }
    }

    private func clampInterval() {
        interval = min(max(interval, intervalRange.lowerBound), intervalRange.upperBound)
    }

    private var monthlySection: some View {
        Section("Monthly Schedule") {
            Picker("Repeat By", selection: $monthlyMode) {
                ForEach(TaskMonthlyMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if monthlyMode == .dayOfMonth {
                Picker("Day", selection: $dayOfMonth) {
                    ForEach(1...31, id: \.self) { day in
                        Text("\(day)").tag(day)
                    }
                }
                .pickerStyle(.menu)
            } else {
                Picker("Ordinal", selection: $ordinalWeek) {
                    ForEach(WeekdayOrdinal.allCases, id: \.self) { ordinal in
                        Text(ordinal.displayName).tag(ordinal)
                    }
                }
                .pickerStyle(.menu)

                Picker("Weekday", selection: $ordinalWeekday) {
                    ForEach(Weekday.allCases) { weekday in
                        Text(weekdayDisplayName(weekday)).tag(weekday)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    private var yearlySection: some View {
        Section("Yearly Schedule") {
            Picker("Month", selection: $monthOfYear) {
                ForEach(1...12, id: \.self) { month in
                    Text(monthName(for: month)).tag(month)
                }
            }
            .pickerStyle(.menu)

            Picker("Repeat By", selection: $monthlyMode) {
                ForEach(TaskMonthlyMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if monthlyMode == .dayOfMonth {
                Picker("Day", selection: $dayOfMonth) {
                    ForEach(1...31, id: \.self) { day in
                        Text("\(day)").tag(day)
                    }
                }
                .pickerStyle(.menu)
            } else {
                Picker("Ordinal", selection: $ordinalWeek) {
                    ForEach(WeekdayOrdinal.allCases, id: \.self) { ordinal in
                        Text(ordinal.displayName).tag(ordinal)
                    }
                }
                .pickerStyle(.menu)

                Picker("Weekday", selection: $ordinalWeekday) {
                    ForEach(Weekday.allCases) { weekday in
                        Text(weekdayDisplayName(weekday)).tag(weekday)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    private var timeZoneDisplayName: String {
        if let zone = TimeZone(identifier: timeZoneId) {
            return zone.localizedName(for: .standard, locale: .current) ?? zone.identifier
        }
        return timeZoneId
    }

    private var selectedSkillDisplayName: String? {
        let trimmedName = selectedSkillName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedName, !trimmedName.isEmpty {
            return trimmedName
        }
        let trimmedSlug = selectedSkillSlug?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedSlug, !trimmedSlug.isEmpty {
            return SkillNameFormatter.displayName(from: trimmedSlug)
        }
        return nil
    }

    private var isSaveDisabled: Bool {
        let trimmedBody = promptBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBody.isEmpty {
            return false
        }
        if selectedSkillDisplayName != nil {
            return false
        }
        if !attachments.isEmpty {
            return false
        }
        return true
    }

    private func saveTask() {
        guard !isSaving else { return }

        Task {
            await performSave()
        }
    }

    private func deleteTask() {
        Task {
            await performDelete()
        }
    }

    @MainActor
    private func performSave() async {
        guard let project = projectContext.activeProject else {
            errorMessage = "No active agent selected."
            showError = true
            return
        }

        isSaving = true
        defer { isSaving = false }

        let promptBodySnapshot = promptBody
        let skillNameSnapshot = selectedSkillName
        let skillSlugSnapshot = selectedSkillSlug
        let attachmentsSnapshot = attachments

        let hasLocalFiles = attachmentsSnapshot.contains { attachment in
            if case .localFile = attachment { return true }
            return false
        }

        var references = attachmentsSnapshot.compactMap { $0.relativeReferencePath }
        if hasLocalFiles {
            isUploadingAttachments = true
            defer { isUploadingAttachments = false }

            do {
                references = try await Task.detached(priority: .userInitiated) {
                    try await ChatAttachmentUploadService.shared.resolveFileReferences(
                        for: attachmentsSnapshot,
                        in: project
                    )
                }.value
            } catch {
                errorMessage = error.localizedDescription
                showError = true
                return
            }
        }

        let compiledPrompt = ChatSkillPromptBuilder.build(
            message: promptBodySnapshot,
            skillName: skillNameSnapshot,
            skillSlug: skillSlugSnapshot,
            fileReferences: references
        )

        var sanitizedInterval = max(1, interval)
        switch frequency {
        case .minutely:
            sanitizedInterval = min(sanitizedInterval, 60)
        case .hourly:
            sanitizedInterval = min(sanitizedInterval, 24)
        case .daily, .weekly, .monthly, .yearly:
            break
        }
        let sanitizedDay = min(max(1, dayOfMonth), 31)
        let sanitizedMonth = min(max(1, monthOfYear), 12)
        let minutes = usesTimeOfDay ? TaskScheduleFormatter.minutes(from: timeOfDay, timeZoneId: timeZoneId) : 0
        let resolvedWeekdayMask = weekdayMask == 0
            ? WeekdayMask.mask(for: Weekday.current(in: Calendar.current))
            : weekdayMask

        let localTask: AgentScheduledTask
        if let task {
            task.title = title
            task.prompt = compiledPrompt
            task.isEnabled = isEnabled
            task.timeZoneId = timeZoneId
            task.frequency = frequency
            task.interval = sanitizedInterval
            task.weekdayMask = resolvedWeekdayMask
            task.monthlyMode = monthlyMode
            task.dayOfMonth = sanitizedDay
            task.ordinalWeek = ordinalWeek
            task.ordinalWeekday = ordinalWeekday
            task.monthOfYear = sanitizedMonth
            task.timeOfDayMinutes = minutes
            task.markUpdated()
            localTask = task
        } else {
            let newTask = AgentScheduledTask(projectId: project.id,
                                             title: title,
                                             prompt: compiledPrompt,
                                             isEnabled: isEnabled,
                                             timeZoneId: timeZoneId,
                                             frequency: frequency,
                                             interval: sanitizedInterval,
                                             weekdayMask: resolvedWeekdayMask,
                                             monthlyMode: monthlyMode,
                                             dayOfMonth: sanitizedDay,
                                             ordinalWeek: ordinalWeek,
                                             ordinalWeekday: ordinalWeekday,
                                             monthOfYear: sanitizedMonth,
                                             timeOfDayMinutes: minutes)
            modelContext.insert(newTask)
            localTask = newTask
        }

        syncReporter?.markSyncing()

        do {
            try? await ProxyAgentIdentityService.shared.ensureProxyAgentId(for: project, modelContext: modelContext)
            let record = try await ProxyTaskService.shared.upsertTask(localTask, project: project)
            applySyncRecord(record, to: localTask)
            syncReporter?.markSuccess()
            cleanupStagedLocalFiles(in: attachmentsSnapshot)
            dismiss()
        } catch {
            syncReporter?.markError(error.localizedDescription)
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    @MainActor
    private func performDelete() async {
        guard let task else { return }
        guard let project = projectContext.activeProject else {
            errorMessage = "No active agent selected."
            showError = true
            return
        }

        syncReporter?.markSyncing()

        do {
            try await ProxyTaskService.shared.deleteTask(task, project: project)
            modelContext.delete(task)
            syncReporter?.markSuccess()
            dismiss()
        } catch {
            syncReporter?.markError(error.localizedDescription)
            errorMessage = error.localizedDescription
            showError = true
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

    private func weekdayDisplayName(_ weekday: Weekday) -> String {
        let calendar = Calendar.current
        let symbols = calendar.weekdaySymbols
        return symbols[weekday.rawValue - 1]
    }

    private func monthName(for month: Int) -> String {
        let calendar = Calendar.current
        let symbols = calendar.monthSymbols
        return symbols[max(1, min(month, 12)) - 1]
    }

    // MARK: - Attachments

    private func addAttachment(_ attachment: ChatComposerAttachment) {
        switch attachment {
        case .projectFile(_, _, let relativePath):
            if attachments.contains(where: { $0.relativeReferencePath == relativePath }) {
                return
            }
        case .localFile(_, let displayName, _):
            if attachments.contains(where: { $0.displayName == displayName }) {
                return
            }
        }

        attachments.append(attachment)
    }

    private func importLocalFiles(_ urls: [URL]) {
        do {
            for url in urls {
                let stagedURL = try stageLocalFile(url)
                addAttachment(.localFile(displayName: url.lastPathComponent, localURL: stagedURL))
            }
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func stageLocalFile(_ url: URL) throws -> URL {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let fileManager = FileManager.default
        let stagingDir = fileManager.temporaryDirectory.appendingPathComponent("task-attachments", isDirectory: true)
        try fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        let destination = stagingDir.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: url, to: destination)
        return destination
    }

    private func cleanupStagedLocalFiles(in attachments: [ChatComposerAttachment]) {
        let fileManager = FileManager.default
        for attachment in attachments {
            if case .localFile(_, _, let localURL) = attachment {
                try? fileManager.removeItem(at: localURL)
            }
        }
    }

    private static func attachmentDisplayName(for reference: String) -> String {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "File" }

        let lastComponent = (trimmed as NSString).lastPathComponent
        if trimmed.hasPrefix(".claude/attachments/") {
            if let dashIndex = lastComponent.firstIndex(of: "-") {
                let prefixLength = lastComponent.distance(from: lastComponent.startIndex, to: dashIndex)
                if prefixLength == 8 {
                    let nameStart = lastComponent.index(after: dashIndex)
                    let withoutPrefix = String(lastComponent[nameStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !withoutPrefix.isEmpty {
                        return withoutPrefix
                    }
                }
            }
        }

        return lastComponent.isEmpty ? trimmed : lastComponent
    }
}

private struct TaskPromptAttachmentComposer: View {
    let selectedSkillName: String?
    let attachments: [ChatComposerAttachment]
    let isAddEnabled: Bool
    let onAddSkill: () -> Void
    let onAddProjectFile: () -> Void
    let onAddLocalFile: () -> Void
    let onClearSkill: () -> Void
    let onRemoveAttachment: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if selectedSkillName != nil || !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if let selectedSkillName {
                            TaskComposerChip(systemImage: "sparkles",
                                             title: selectedSkillName,
                                             onRemove: onClearSkill)
                        }

                        ForEach(attachments) { attachment in
                            TaskComposerChip(systemImage: "doc",
                                             title: attachment.displayName) {
                                onRemoveAttachment(attachment.id)
                            }
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                Menu {
                    Button(action: onAddSkill) {
                        Label("Skill", systemImage: "sparkles")
                    }
                    Button(action: onAddProjectFile) {
                        Label("Project File", systemImage: "folder")
                    }
                    Button(action: onAddLocalFile) {
                        Label("Local File", systemImage: "doc")
                    }
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.title3)
                        .foregroundColor(isAddEnabled ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(!isAddEnabled)
                .accessibilityLabel("Add")

                Text("Add skill or file")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()
            }
        }
    }
}

private struct TaskComposerChip: View {
    let systemImage: String
    let title: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundColor(.accentColor)

            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(Color(.tertiarySystemBackground))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
    }
}

private struct WeekdayPicker: View {
    @Binding var mask: Int
    private let calendar = Calendar.current

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 7)
        let grid = LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Weekday.ordered(using: calendar)) { weekday in
                WeekdayChip(title: weekdayLabel(for: weekday),
                            isSelected: WeekdayMask.contains(mask, weekday: weekday)) {
                    toggle(weekday)
                }
            }
        }

        Group {
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: 8) {
                    grid
                }
            } else {
                grid
            }
        }
    }

    private func toggle(_ weekday: Weekday) {
        let updatedMask = WeekdayMask.toggle(mask, weekday: weekday)
        let selected = WeekdayMask.selected(in: updatedMask, calendar: calendar)
        guard !selected.isEmpty else { return }
        mask = updatedMask
    }

    private func weekdayLabel(for weekday: Weekday) -> String {
        let symbols = calendar.shortWeekdaySymbols
        let name = symbols[weekday.rawValue - 1]
        return String(name.prefix(2))
    }
}

private struct WeekdayChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let content = Text(title)
            .font(.footnote.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)

        Button(action: action) {
            if #available(iOS 26.0, *) {
                content
                    .glassEffect(
                        isSelected
                            ? .regular.tint(Color.accentColor.opacity(0.25)).interactive()
                            : .regular.interactive(),
                        in: .rect(cornerRadius: 10)
                    )
            } else {
                content
                    .background(backgroundMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color(.separator).opacity(0.4), lineWidth: 0.5)
                    )
            }
        }
        .buttonStyle(.plain)
    }

    private var backgroundMaterial: some ShapeStyle {
        if isSelected {
            return Color.accentColor.opacity(0.2)
        }
        return Color(.secondarySystemBackground)
    }
}

#Preview {
    let container = try? ModelContainer(
        for: AgentScheduledTask.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )

    return NavigationStack {
        RegularTaskEditorView()
    }
    .modelContainer(container!)
}
