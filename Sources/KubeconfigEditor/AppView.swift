import SwiftUI
import AppKit
import KubeconfigEditorCore

enum WorkspaceSection: String, CaseIterable {
    case contexts = "Contexts"
    case clusters = "Clusters"
    case users = "Users"
}

struct AppView: View {
    @StateObject private var viewModel = KubeConfigViewModel()
    @StateObject private var updater = ReleaseUpdater()
    @AppStorage("kce.autoValidateYAML") private var autoValidateYAML = true
    @State private var didTryDefaultLoad = false
    @State private var section: WorkspaceSection = .contexts

    @State private var showImportSheet = false
    @State private var importRawText = ""
    @State private var importPreviewText = ""
    @State private var importPrefix = ""
    @State private var importReplaceHost = ""
    @State private var importMessage = ""
    @State private var showCreateMenuDialog = false
    @State private var showBulkDeleteDialog = false
    @State private var showVersionsSheet = false
    @State private var savedVersions: [KubeConfigViewModel.SavedVersion] = []
    @State private var selectedContextIDs: Set<UUID> = []
    @State private var selectedClusterIDs: Set<UUID> = []
    @State private var selectedUserIDs: Set<UUID> = []
    @State private var showContextMergeSheet = false
    @State private var contextMergeRawText = ""
    @State private var contextMergeImportedContextName = ""
    @State private var contextMergePreview: ContextMergePreview?
    @State private var contextMergeSelectedChangeIDs: Set<String> = []
    @State private var contextMergeMessage = ""
    @State private var contextMergeTargetContextID: UUID?
    @State private var exportPanelDefaultName = "kubeconfig-export.yaml"
    @State private var pendingRemoveTarget: RemoveTarget?
    @State private var showRemoveConfirmSheet = false
    @State private var showUpdatesSheet = false
    @State private var showAwsEksQuickAddSheet = false
    @State private var listSearchText = ""
    @State private var listSortAscending = true
    @State private var isStartingUpdateInstall = false
    @State private var isLoadingVersionHistory = false
    @State private var awsEksContextName = ""
    @State private var awsEksClusterArn = ""
    @State private var awsEksEndpoint = ""
    @State private var awsEksCertificateAuthorityData = ""
    @State private var awsEksRegion = "eu-central-1"
    @State private var awsEksProfile = ""
    @State private var awsEksMessage = ""

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(
                    min: 300,
                    ideal: sidebarIdealWidth,
                    max: 560
                )
        } detail: {
            VStack(spacing: 0) {
                sectionActionBar
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.thinMaterial)
                Divider()
                detail
                    .id(detailIdentity)
            }
        }
        .frame(minWidth: 1200, minHeight: 760)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("Section", selection: $section) {
                    Text("Contexts").tag(WorkspaceSection.contexts)
                    Text("Clusters").tag(WorkspaceSection.clusters)
                    Text("Users").tag(WorkspaceSection.users)
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
            }

        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(viewModel.currentPath?.path ?? "Файл не открыт")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(viewModel.validationMessage)
                    .foregroundStyle(viewModel.validationMessage.contains("error") ? .red : .secondary)
                Text(viewModel.hasUnsavedChanges ? "Unsaved changes" : "Saved")
                    .foregroundStyle(viewModel.hasUnsavedChanges ? .orange : .secondary)
                Text(viewModel.statusMessage)
            }
            .font(.caption)
            .padding(10)
            .background(.thinMaterial)
        }
        .overlay(alignment: .bottomTrailing) {
            if updater.hasNewerAvailableUpdate, let update = updater.availableUpdate {
                UpdateToast(
                    version: update.version,
                    isInstalling: updater.isUpdateInProgress || isStartingUpdateInstall,
                    status: updater.installStatus,
                    onUpdate: { requestUpdateInstall() },
                    onLater: { updater.dismissUpdate() }
                )
                .padding(.trailing, 14)
                .padding(.bottom, 58)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .onAppear {
            guard !didTryDefaultLoad else { return }
            didTryDefaultLoad = true
            viewModel.setBackgroundValidation(autoValidateYAML)
            viewModel.loadDefaultKubeconfigIfExists()
            ensureSelectionForCurrentSection()
            updater.checkForUpdatesIfNeeded()
        }
        .onChange(of: autoValidateYAML) { enabled in
            viewModel.setBackgroundValidation(enabled)
        }
        .onReceive(NotificationCenter.default.publisher(for: AppMenuCommand.newConfig)) { _ in
            viewModel.newEmpty()
            section = .contexts
            selectedContextIDs = viewModel.contexts.first.map { [$0.id] } ?? []
            selectedClusterIDs = []
            selectedUserIDs = []
            syncEnumSelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: AppMenuCommand.open)) { _ in
            openFile()
        }
        .onReceive(NotificationCenter.default.publisher(for: AppMenuCommand.save)) { _ in
            save()
        }
        .onReceive(NotificationCenter.default.publisher(for: AppMenuCommand.saveAs)) { _ in
            saveAs()
        }
        .onReceive(NotificationCenter.default.publisher(for: AppMenuCommand.setCurrentAndSave)) { _ in
            makeCurrentAndSave()
        }
        .onReceive(NotificationCenter.default.publisher(for: AppMenuCommand.export)) { _ in
            exportSelectedContexts()
        }
        .onReceive(NotificationCenter.default.publisher(for: AppMenuCommand.import)) { _ in
            showImportSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: AppMenuCommand.updates)) { _ in
            showUpdatesSheet = true
        }
        .onChange(of: section) { _ in
            ensureSelectionForCurrentSection()
        }
        .onChange(of: viewModel.contexts) { _ in
            cleanupSelections()
            viewModel.registerEdit(reason: "contexts-change")
        }
        .onChange(of: viewModel.clusters) { _ in
            cleanupSelections()
            viewModel.registerEdit(reason: "clusters-change")
        }
        .onChange(of: viewModel.users) { _ in
            cleanupSelections()
            viewModel.registerEdit(reason: "users-change")
        }
        .onChange(of: viewModel.currentContext) { _ in
            viewModel.registerEdit(reason: "current-context-change")
        }
        .sheet(isPresented: $showImportSheet) {
            ImportSnippetSheet(
                rawText: $importRawText,
                previewText: $importPreviewText,
                prefix: $importPrefix,
                replaceHost: $importReplaceHost,
                message: $importMessage,
                onPreview: {
                    do {
                        importPreviewText = try viewModel.normalizeImportText(
                            importRawText,
                            serverHostReplacement: importReplaceHost,
                            namePrefix: importPrefix
                        )
                        importMessage = "Preview готов. Можно править YAML в нижнем окне перед merge."
                    } catch {
                        importMessage = "Ошибка preview: \(error.localizedDescription)"
                    }
                },
                onMerge: {
                    do {
                        let input = importPreviewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? importRawText : importPreviewText
                        try viewModel.mergeImportText(input)
                        adoptSelectionFromViewModel()
                        importMessage = "Импорт выполнен"
                        showImportSheet = false
                    } catch {
                        importMessage = "Ошибка merge: \(error.localizedDescription)"
                    }
                },
                onClose: {
                    showImportSheet = false
                }
            )
            .frame(minWidth: 980, minHeight: 700)
        }
        .confirmationDialog("Удалить выбранные", isPresented: $showBulkDeleteDialog, titleVisibility: .visible) {
            Button("Удалить только выбранные", role: .destructive) {
                deleteSelectedBulk(cascade: false)
            }
            Button("Удалить каскадно", role: .destructive) {
                deleteSelectedBulk(cascade: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Каскад удалит связанные сущности, которые больше нигде не используются.")
        }
        .confirmationDialog("Create or Import", isPresented: $showCreateMenuDialog, titleVisibility: .visible) {
            Button("New Context") {
                viewModel.addContext()
                section = .contexts
                adoptSelectionFromViewModel()
            }
            Button("New Cluster") {
                viewModel.addCluster()
                section = .clusters
                adoptSelectionFromViewModel()
            }
            Button("New User") {
                viewModel.addUser()
                section = .users
                adoptSelectionFromViewModel()
            }
            Divider()
            Button("Import as New Entries...") {
                showImportSheet = true
            }
            Button("Quick Add AWS EKS...") {
                showAwsEksQuickAddSheet = true
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showVersionsSheet) {
            VersionsSheet(
                versions: savedVersions,
                onRollback: { version in
                    do {
                        try viewModel.rollbackToVersion(version)
                        adoptSelectionFromViewModel()
                        showVersionsSheet = false
                    } catch {
                        viewModel.statusMessage = "Ошибка отката версии: \(error.localizedDescription)"
                    }
                },
                onClose: { showVersionsSheet = false }
            )
            .frame(minWidth: 700, minHeight: 520)
        }
        .sheet(isPresented: $showContextMergeSheet) {
            ContextMergeSheet(
                rawText: $contextMergeRawText,
                importedContextName: $contextMergeImportedContextName,
                preview: $contextMergePreview,
                selectedChangeIDs: $contextMergeSelectedChangeIDs,
                message: $contextMergeMessage,
                onAnalyze: { analyzeContextMergePreview() },
                onApplySelected: { applyContextMergeSelection() }
            )
            .frame(minWidth: 1100, minHeight: 740)
        }
        .sheet(isPresented: $showRemoveConfirmSheet) {
            RemoveConfirmSheet(
                title: removeSheetTitle(),
                message: "Cascade удалит связанные элементы, которые больше нигде не используются.",
                onCascade: { performRemoveConfirmed(cascade: true) },
                onYes: { performRemoveConfirmed(cascade: false) },
                onNo: { showRemoveConfirmSheet = false }
            )
            .frame(minWidth: 520, minHeight: 200)
        }
        .sheet(isPresented: $showUpdatesSheet) {
            UpdatesSheet(
                updater: updater,
                onUpdate: { requestUpdateInstall() },
                onClose: { showUpdatesSheet = false }
            )
            .frame(minWidth: 520, minHeight: 300)
        }
        .sheet(isPresented: $showAwsEksQuickAddSheet) {
            AwsEksQuickAddSheet(
                contextName: $awsEksContextName,
                clusterArn: $awsEksClusterArn,
                endpoint: $awsEksEndpoint,
                certificateAuthorityData: $awsEksCertificateAuthorityData,
                region: $awsEksRegion,
                awsProfile: $awsEksProfile,
                message: $awsEksMessage,
                onAdd: { addAwsEksQuickContext() },
                onClose: { showAwsEksQuickAddSheet = false }
            )
            .frame(minWidth: 880, minHeight: 620)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("Search by name", text: $listSearchText)
                    .textFieldStyle(.roundedBorder)
                Button {
                    listSortAscending.toggle()
                } label: {
                    Image(systemName: listSortAscending ? "arrow.up" : "arrow.down")
                }
                .help(listSortAscending ? "Сортировка A-Z" : "Сортировка Z-A")
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            Button {
                showCreateMenuDialog = true
            } label: {
                Label("Add / Import", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(GlassPrimaryPillButtonStyle())
            .controlSize(.regular)
            .padding(.horizontal, 10)

            List {
                switch section {
                case .contexts:
                    Section("Contexts") {
                        ForEach(displayedContexts) { context in
                            sidebarButton(
                                title: context.name,
                                warning: viewModel.contextWarning(context),
                                includeInExport: context.includeInExport,
                                isSelected: selectedContextIDs.contains(context.id),
                                isCurrent: viewModel.currentContext == context.name
                            ) {
                                handleContextClick(context.id)
                            } onSetCurrent: {
                                activateContextFromSidebar(context.id)
                            } onToggleExport: {
                                viewModel.toggleContextExport(context.id)
                            } onDelete: {
                                openRemoveDialog(.context(context.id))
                            }
                        }
                    }
                case .clusters:
                    Section("Clusters") {
                        ForEach(displayedClusters) { cluster in
                            sidebarButton(
                                title: cluster.name,
                                warning: viewModel.clusterWarning(cluster),
                                includeInExport: cluster.includeInExport,
                                isSelected: selectedClusterIDs.contains(cluster.id)
                            ) {
                                handleClusterClick(cluster.id)
                            } onToggleExport: {
                                viewModel.toggleClusterExport(cluster.id)
                            } onDelete: {
                                openRemoveDialog(.cluster(cluster.id))
                            }
                        }
                    }
                case .users:
                    Section("Users") {
                        ForEach(displayedUsers) { user in
                            sidebarButton(
                                title: user.name,
                                warning: viewModel.userWarning(user),
                                includeInExport: user.includeInExport,
                                isSelected: selectedUserIDs.contains(user.id)
                            ) {
                                handleUserClick(user.id)
                            } onToggleExport: {
                                viewModel.toggleUserExport(user.id)
                            } onDelete: {
                                openRemoveDialog(.user(user.id))
                            }
                        }
                    }
                }
            }
        }
    }

    private var displayedContexts: [NamedItem] {
        sortedAndFiltered(viewModel.contexts)
    }

    private var displayedClusters: [NamedItem] {
        sortedAndFiltered(viewModel.clusters)
    }

    private var displayedUsers: [NamedItem] {
        sortedAndFiltered(viewModel.users)
    }

    private var sidebarIdealWidth: CGFloat {
        let names = viewModel.contexts.map(\.name) + viewModel.clusters.map(\.name) + viewModel.users.map(\.name)
        guard let longestName = names.max(by: { $0.count < $1.count }) else {
            return 340
        }

        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let textWidth = (longestName as NSString).size(withAttributes: [.font: font]).width

        // Text + "(hidden)" suffix reserve + eye button + paddings.
        return min(max(textWidth + 180, 340), 560)
    }

    private func sortedAndFiltered(_ items: [NamedItem]) -> [NamedItem] {
        let filtered: [NamedItem]
        let query = listSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            filtered = items
        } else {
            filtered = items.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }

        return filtered.sorted { lhs, rhs in
            if listSortAscending {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedDescending
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .contexts:
            contextDetail
        case .clusters:
            clusterDetail
        case .users:
            userDetail
        }
    }

    @ViewBuilder
    private var sectionActionBar: some View {
        HStack(spacing: 10) {
            Button("Open File...") { openFile() }
            Button("Save") { save() }
            Button("Save As...") { saveAs() }

            Divider().frame(height: 20)

            switch section {
            case .contexts:
                Button("Merge") { openContextMergeSheetAction() }
                    .help("Merge into selected context")
                    .disabled(currentMergeTargetContextID() == nil)
                Button("Set Current") { makeCurrentAndSave() }
                    .help("Set as current context and save")
                    .disabled(currentMergeTargetContextID() == nil)
                if selectedContextIDs.count >= 1 {
                    Button("Export") { exportSelectedContexts() }
                        .help("Export selected contexts")
                }
                if selectedContextIDs.count > 1 {
                    Button("Удалить выбранное") { requestDeleteSelectedBulk() }
                        .tint(.red)
                }
            case .clusters:
                EmptyView()
            case .users:
                EmptyView()
            }

            Spacer()

            Menu("History") {
                Button("Undo Last Change") { viewModel.undoLastChange() }
                    .disabled(!viewModel.canUndo)
                Button("Redo Last Change") { viewModel.redoLastChange() }
                    .disabled(!viewModel.canRedo)
                Divider()
                Button("Open Version History...") { openVersionsSheet() }
                    .disabled(isLoadingVersionHistory)
                Button("Restore Deleted from History...") { openVersionsSheet() }
                    .disabled(isLoadingVersionHistory)
                Button("Create Backup") { backup() }
            }
        }
        .buttonStyle(GlassToolbarButtonStyle())
        .controlSize(.small)
    }

    @ViewBuilder
    private var contextDetail: some View {
        if let id = selectedContextId(), let index = viewModel.contexts.firstIndex(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let warning = viewModel.contextWarning(viewModel.contexts[index]) {
                        WarningBanner(text: warning)
                    }

                    ContextEditor(
                        item: $viewModel.contexts[index],
                        currentContext: $viewModel.currentContext,
                        clusterNames: viewModel.clusters.map(\.name),
                        userNames: viewModel.users.map(\.name),
                        onOpenCluster: { clusterName in
                            if let cluster = viewModel.clusters.first(where: { $0.name == clusterName }) {
                                section = .clusters
                                selectedClusterIDs = [cluster.id]
                                selectedContextIDs = []
                                selectedUserIDs = []
                                syncEnumSelection()
                            }
                        },
                        onOpenUser: { userName in
                            if let user = viewModel.users.first(where: { $0.name == userName }) {
                                section = .users
                                selectedUserIDs = [user.id]
                                selectedContextIDs = []
                                selectedClusterIDs = []
                                syncEnumSelection()
                            }
                        }
                    )
                    .id(viewModel.contexts[index].id)

                    HStack {
                        Spacer()
                        Button("Remove") {
                            openRemoveDialog(.context(viewModel.contexts[index].id))
                        }
                        .buttonStyle(GlassDestructiveButtonStyle())
                    }
                }
                .padding()
            }
        } else {
            Text("Выбери context в списке")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var clusterDetail: some View {
        if let id = selectedClusterId(),
           let index = viewModel.clusters.firstIndex(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let warning = viewModel.clusterWarning(viewModel.clusters[index]) {
                        WarningBanner(text: warning)
                    }

                    GenericItemEditor(title: "Cluster", item: $viewModel.clusters[index]) { oldName, newName in
                        viewModel.syncContextReferences(oldName: oldName, newName: newName, type: "cluster")
                    }

                    GroupBox("Relations") {
                        HStack(alignment: .top, spacing: 24) {
                            RelatedItemsColumn(
                                title: "Contexts",
                                items: viewModel.contextsLinkedToCluster(viewModel.clusters[index].name).map(\.name),
                                emptyText: "Нет связанных contexts"
                            )
                            RelatedItemsColumn(
                                title: "Users",
                                items: viewModel.usersLinkedToCluster(viewModel.clusters[index].name).map(\.name),
                                emptyText: "Нет связанных users"
                            )
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Remove") {
                            openRemoveDialog(.cluster(viewModel.clusters[index].id))
                        }
                        .buttonStyle(GlassDestructiveButtonStyle())
                    }
                }
                .padding()
            }
        } else {
            Text("Выбери cluster в списке")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var userDetail: some View {
        if let id = selectedUserId(),
           let index = viewModel.users.firstIndex(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let warning = viewModel.userWarning(viewModel.users[index]) {
                        WarningBanner(text: warning)
                    }

                    GenericItemEditor(title: "User", item: $viewModel.users[index]) { oldName, newName in
                        viewModel.syncContextReferences(oldName: oldName, newName: newName, type: "user")
                    }

                    GroupBox("Relations") {
                        HStack(alignment: .top, spacing: 24) {
                            RelatedItemsColumn(
                                title: "Clusters",
                                items: viewModel.clustersLinkedToUser(viewModel.users[index].name).map(\.name),
                                emptyText: "Нет связанных clusters"
                            )
                            RelatedItemsColumn(
                                title: "Contexts",
                                items: viewModel.contextsLinkedToUser(viewModel.users[index].name).map(\.name),
                                emptyText: "Нет связанных contexts"
                            )
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Remove") {
                            openRemoveDialog(.user(viewModel.users[index].id))
                        }
                        .buttonStyle(GlassDestructiveButtonStyle())
                    }
                }
                .padding()
            }
        } else {
            Text("Выбери user в списке")
                .foregroundStyle(.secondary)
        }
    }

    private func selectedContextId() -> UUID? {
        viewModel.contexts.first(where: { selectedContextIDs.contains($0.id) })?.id
    }

    private func selectedClusterId() -> UUID? {
        viewModel.clusters.first(where: { selectedClusterIDs.contains($0.id) })?.id
    }

    private func selectedUserId() -> UUID? {
        viewModel.users.first(where: { selectedUserIDs.contains($0.id) })?.id
    }

    private var detailIdentity: String {
        if let id = selectedContextId() {
            return "\(section.rawValue)-context-\(id.uuidString)"
        }
        if let id = selectedClusterId() {
            return "\(section.rawValue)-cluster-\(id.uuidString)"
        }
        if let id = selectedUserId() {
            return "\(section.rawValue)-user-\(id.uuidString)"
        }
        return "\(section.rawValue)-none"
    }

    @ViewBuilder
    private func sidebarRow(title: String, warning: String?, includeInExport: Bool, isCurrent: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .lineLimit(1)
                .fontWeight(isCurrent ? .bold : .regular)
                .foregroundColor(warning == nil ? (includeInExport ? .primary : .secondary) : .red)
            if let warning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .help(warning)
            }
            if !includeInExport {
                Text("(hidden)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .help(warning ?? "OK")
    }

    @ViewBuilder
    private func sidebarButton(
        title: String,
        warning: String?,
        includeInExport: Bool,
        isSelected: Bool,
        isCurrent: Bool = false,
        action: @escaping () -> Void,
        onSetCurrent: (() -> Void)? = nil,
        onToggleExport: @escaping () -> Void,
        onDelete: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 8) {
            if let onSetCurrent {
                Button {
                    onSetCurrent()
                } label: {
                    Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(isCurrent ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(isCurrent ? "Current context" : "Set as current context and save")
            }
            Button(action: action) {
                HStack(spacing: 0) {
                    sidebarRow(title: title, warning: warning, includeInExport: includeInExport, isCurrent: isCurrent)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            Button {
                onToggleExport()
            } label: {
                Image(systemName: includeInExport ? "eye.fill" : "eye.slash.fill")
                    .foregroundColor(includeInExport ? .secondary : .orange)
            }
            .buttonStyle(.plain)
            .help(includeInExport ? "Показывать в итоговом kubeconfig" : "Скрыто из итогового kubeconfig")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .listRowBackground(
            isSelected
                ? Color.accentColor.opacity(0.35)
                : (isCurrent ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .contextMenu {
            if let onDelete {
                Button("Delete", role: .destructive) {
                    onDelete()
                }
            }
        }
    }

    private func activateContextFromSidebar(_ id: UUID) {
        selectedContextIDs = [id]
        selectedClusterIDs = []
        selectedUserIDs = []
        syncEnumSelection()
        do {
            try viewModel.activateContextAndSave(id)
        } catch {
            viewModel.statusMessage = "Не удалось активировать context: \(error.localizedDescription)"
        }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = viewModel.defaultKubeDirectoryURL
        panel.nameFieldStringValue = "config"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try viewModel.load(from: url)
                adoptSelectionFromViewModel()
            } catch {
                viewModel.statusMessage = "Ошибка загрузки: \(error.localizedDescription)"
            }
        }
    }

    private func save() {
        if let url = viewModel.currentPath {
            do {
                try viewModel.save(to: url)
            } catch {
                viewModel.statusMessage = "Ошибка сохранения: \(error.localizedDescription)"
            }
            return
        }

        saveAs()
    }

    private func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.directoryURL = viewModel.defaultKubeDirectoryURL
        panel.nameFieldStringValue = viewModel.currentPath?.lastPathComponent ?? "config"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try viewModel.save(to: url)
            } catch {
                viewModel.statusMessage = "Ошибка сохранения: \(error.localizedDescription)"
            }
        }
    }

    private func backup() {
        do {
            try viewModel.backup()
        } catch {
            viewModel.statusMessage = "Ошибка бэкапа: \(error.localizedDescription)"
        }
    }

    private func requestUpdateInstall() {
        guard !isStartingUpdateInstall, !updater.isUpdateInProgress else { return }
        isStartingUpdateInstall = true
        showUpdatesSheet = false
        installUpdateWithAutosave()
    }

    private func installUpdateWithAutosave() {
        do {
            if viewModel.hasUnsavedChanges {
                let saveURL = viewModel.currentPath ?? viewModel.defaultKubeconfigURL
                try FileManager.default.createDirectory(
                    at: saveURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try viewModel.save(to: saveURL)
            }
            updater.installAvailableUpdate()
            if !updater.isUpdateInProgress {
                isStartingUpdateInstall = false
            }
        } catch {
            isStartingUpdateInstall = false
            viewModel.statusMessage = "Не удалось сохранить перед обновлением: \(error.localizedDescription)"
        }
    }

    private func openVersionsSheet() {
        guard !isLoadingVersionHistory else { return }
        isLoadingVersionHistory = true
        viewModel.statusMessage = "Загрузка истории версий..."

        Task {
            defer { isLoadingVersionHistory = false }
            do {
                savedVersions = try await viewModel.listSavedVersionsAsync()
                showVersionsSheet = true
            } catch {
                viewModel.statusMessage = "Ошибка чтения версий: \(error.localizedDescription)"
            }
        }
    }

    private func addAwsEksQuickContext() {
        do {
            try viewModel.addAWSEKSContext(
                contextName: awsEksContextName,
                clusterArn: awsEksClusterArn,
                endpoint: awsEksEndpoint,
                certificateAuthorityData: awsEksCertificateAuthorityData,
                region: awsEksRegion,
                awsProfile: awsEksProfile
            )
            section = .contexts
            adoptSelectionFromViewModel()
            awsEksMessage = "AWS EKS context created"
            showAwsEksQuickAddSheet = false
            awsEksContextName = ""
            awsEksClusterArn = ""
            awsEksEndpoint = ""
            awsEksCertificateAuthorityData = ""
            awsEksProfile = ""
        } catch {
            awsEksMessage = "Ошибка создания AWS EKS context: \(error.localizedDescription)"
        }
    }

    private func makeCurrentAndSave() {
        do {
            try viewModel.activateContextAndSave(selectedContextId())
        } catch {
            viewModel.statusMessage = "Не удалось активировать context: \(error.localizedDescription)"
        }
    }

    private func exportSelectedContexts() {
        let selectedIDs = selectedContextIDs
        guard !selectedIDs.isEmpty else {
            viewModel.statusMessage = "Выбери хотя бы один context"
            return
        }

        if selectedIDs.count == 1, let id = selectedIDs.first, let item = viewModel.contexts.first(where: { $0.id == id }) {
            exportPanelDefaultName = "\(item.name)-kubeconfig.yaml"
        } else {
            exportPanelDefaultName = "kubeconfig-export.yaml"
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.directoryURL = viewModel.defaultKubeDirectoryURL
        panel.nameFieldStringValue = exportPanelDefaultName
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try viewModel.exportContexts(ids: selectedIDs, to: url)
            } catch {
                viewModel.statusMessage = "Ошибка экспорта: \(error.localizedDescription)"
            }
        }
    }

    private func ensureSelectionForCurrentSection() {
        adoptSelectionFromViewModel()

        switch section {
        case .contexts:
            if selectedContextId() != nil { return }
            selectedContextIDs = viewModel.contexts.first.map { [$0.id] } ?? []
            selectedClusterIDs = []
            selectedUserIDs = []
        case .clusters:
            if selectedClusterId() != nil { return }
            selectedClusterIDs = viewModel.clusters.first.map { [$0.id] } ?? []
            selectedContextIDs = []
            selectedUserIDs = []
        case .users:
            if selectedUserId() != nil { return }
            selectedUserIDs = viewModel.users.first.map { [$0.id] } ?? []
            selectedContextIDs = []
            selectedClusterIDs = []
        }
        syncEnumSelection()
    }

    private func adoptSelectionFromViewModel() {
        guard let selection = viewModel.selection else { return }
        switch selection {
        case .context(let id):
            selectedContextIDs = [id]
            selectedClusterIDs = []
            selectedUserIDs = []
        case .cluster(let id):
            selectedClusterIDs = [id]
            selectedContextIDs = []
            selectedUserIDs = []
        case .user(let id):
            selectedUserIDs = [id]
            selectedContextIDs = []
            selectedClusterIDs = []
        }
    }

    private func cleanupSelections() {
        let contextIDs = Set(viewModel.contexts.map(\.id))
        let clusterIDs = Set(viewModel.clusters.map(\.id))
        let userIDs = Set(viewModel.users.map(\.id))
        selectedContextIDs = selectedContextIDs.intersection(contextIDs)
        selectedClusterIDs = selectedClusterIDs.intersection(clusterIDs)
        selectedUserIDs = selectedUserIDs.intersection(userIDs)
        ensureSelectionForCurrentSection()
    }

    private func handleContextClick(_ id: UUID) {
        if isMultiSelectModifierPressed() {
            toggle(&selectedContextIDs, id: id)
        } else {
            selectedContextIDs = [id]
            selectedClusterIDs = []
            selectedUserIDs = []
        }
        syncEnumSelection()
    }

    private func handleClusterClick(_ id: UUID) {
        if isMultiSelectModifierPressed() {
            toggle(&selectedClusterIDs, id: id)
        } else {
            selectedClusterIDs = [id]
            selectedContextIDs = []
            selectedUserIDs = []
        }
        syncEnumSelection()
    }

    private func handleUserClick(_ id: UUID) {
        if isMultiSelectModifierPressed() {
            toggle(&selectedUserIDs, id: id)
        } else {
            selectedUserIDs = [id]
            selectedContextIDs = []
            selectedClusterIDs = []
        }
        syncEnumSelection()
    }

    private func toggle(_ set: inout Set<UUID>, id: UUID) {
        if set.contains(id) {
            set.remove(id)
        } else {
            set.insert(id)
        }
    }

    private func isMultiSelectModifierPressed() -> Bool {
        let flags = NSEvent.modifierFlags
        return flags.contains(.command) || flags.contains(.shift)
    }

    private func syncEnumSelection() {
        if let id = selectedContextId() {
            viewModel.selection = .context(id)
            return
        }
        if let id = selectedClusterId() {
            viewModel.selection = .cluster(id)
            return
        }
        if let id = selectedUserId() {
            viewModel.selection = .user(id)
            return
        }
        viewModel.selection = nil
    }

    private func requestDeleteSelectedBulk() {
        guard selectedCountInCurrentSection() > 0 else {
            viewModel.statusMessage = "Ничего не выбрано"
            return
        }
        showBulkDeleteDialog = true
    }

    private func deleteSelectedBulk(cascade: Bool) {
        switch section {
        case .contexts:
            viewModel.deleteContexts(ids: selectedContextIDs, cascade: cascade)
            selectedContextIDs.removeAll()
        case .clusters:
            viewModel.deleteClusters(ids: selectedClusterIDs, cascade: cascade)
            selectedClusterIDs.removeAll()
        case .users:
            viewModel.deleteUsers(ids: selectedUserIDs, cascade: cascade)
            selectedUserIDs.removeAll()
        }
        ensureSelectionForCurrentSection()
    }

    private func selectedCountInCurrentSection() -> Int {
        switch section {
        case .contexts:
            return selectedContextIDs.count
        case .clusters:
            return selectedClusterIDs.count
        case .users:
            return selectedUserIDs.count
        }
    }

    private func currentMergeTargetContextID() -> UUID? {
        if let id = selectedContextId() {
            return id
        }
        return viewModel.contexts.first(where: { $0.name == viewModel.currentContext })?.id
    }

    private func openContextMergeSheetAction() {
        guard let contextID = currentMergeTargetContextID() else {
            viewModel.statusMessage = "Выбери context для merge"
            return
        }
        contextMergeTargetContextID = contextID
        contextMergeRawText = ""
        contextMergeImportedContextName = ""
        contextMergePreview = nil
        contextMergeSelectedChangeIDs = []
        contextMergeMessage = "Вставь kubeconfig целиком, нажми Analyze, отметь нужные изменения и Apply."
        showContextMergeSheet = true
    }

    private func analyzeContextMergePreview() {
        guard let contextID = contextMergeTargetContextID else {
            contextMergeMessage = "Целевой context не выбран"
            return
        }
        do {
            let preview = try viewModel.buildContextMergePreview(
                importText: contextMergeRawText,
                intoContextID: contextID,
                importedContextName: contextMergeImportedContextName.isEmpty ? nil : contextMergeImportedContextName
            )
            contextMergePreview = preview
            contextMergeImportedContextName = preview.selectedImportedContextName
            contextMergeSelectedChangeIDs = Set(preview.changes.map(\.id))
            contextMergeMessage = "Найдено изменений: \(preview.changes.count)"
        } catch {
            contextMergePreview = nil
            contextMergeSelectedChangeIDs = []
            contextMergeMessage = "Ошибка анализа: \(error.localizedDescription)"
        }
    }

    private func applyContextMergeSelection() {
        guard let contextID = contextMergeTargetContextID else {
            contextMergeMessage = "Целевой context не выбран"
            return
        }
        guard let preview = contextMergePreview else {
            contextMergeMessage = "Сначала нажми Analyze"
            return
        }
        do {
            try viewModel.applyContextMergePreview(
                intoContextID: contextID,
                preview: preview,
                selectedChangeIDs: contextMergeSelectedChangeIDs
            )
            adoptSelectionFromViewModel()
            showContextMergeSheet = false
        } catch {
            contextMergeMessage = "Ошибка apply: \(error.localizedDescription)"
        }
    }

    private func openRemoveDialog(_ target: RemoveTarget) {
        pendingRemoveTarget = target
        showRemoveConfirmSheet = true
    }

    private func removeSheetTitle() -> String {
        guard let target = pendingRemoveTarget else { return "Remove?" }
        switch target {
        case .context:
            return "Remove context?"
        case .cluster:
            return "Remove cluster?"
        case .user:
            return "Remove user?"
        }
    }

    private func performRemoveConfirmed(cascade: Bool) {
        guard let target = pendingRemoveTarget else { return }
        do {
            switch target {
            case .context(let id):
                try viewModel.deleteContext(id, cascade: cascade)
                selectedContextIDs.remove(id)
            case .cluster(let id):
                viewModel.deleteClusters(ids: Set([id]), cascade: cascade)
                selectedClusterIDs.remove(id)
            case .user(let id):
                viewModel.deleteUsers(ids: Set([id]), cascade: cascade)
                selectedUserIDs.remove(id)
            }
            ensureSelectionForCurrentSection()
            showRemoveConfirmSheet = false
        } catch {
            viewModel.statusMessage = "Ошибка удаления: \(error.localizedDescription)"
        }
    }
}

private enum RemoveTarget: Hashable {
    case context(UUID)
    case cluster(UUID)
    case user(UUID)
}

struct RemoveConfirmSheet: View {
    let title: String
    let message: String
    var onCascade: () -> Void
    var onYes: () -> Void
    var onNo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title3)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack {
                Button("Cascade") {
                    onCascade()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.45, green: 0.05, blue: 0.12))

                Spacer()

                Button("No") {
                    onNo()
                }
                .buttonStyle(.bordered)

                Button("Yes") {
                    onYes()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(18)
    }
}

struct ContextEditor: View {
    @Binding var item: NamedItem
    @Binding var currentContext: String
    let clusterNames: [String]
    let userNames: [String]
    var onOpenCluster: (String) -> Void
    var onOpenUser: (String) -> Void

    var body: some View {
        Form {
            Section("Context Settings") {
                TextField("Name", text: $item.name)
                Toggle("Use as current context", isOn: Binding(
                    get: { currentContext == item.name },
                    set: { isCurrent in
                        if isCurrent { currentContext = item.name }
                        else if currentContext == item.name { currentContext = "" }
                    }
                ))

                HStack {
                    Menu("Cluster") {
                        Button("Clear") { contextFieldBinding("cluster").wrappedValue = "" }
                        ForEach(clusterOptions(), id: \.self) { value in
                            Button(value) {
                                contextFieldBinding("cluster").wrappedValue = value
                            }
                        }
                    }
                    .frame(width: 140)
                    TextField("Cluster", text: contextFieldBinding("cluster"))
                    Button("Go to Cluster") {
                        onOpenCluster(contextFieldBinding("cluster").wrappedValue)
                    }
                }

                HStack {
                    Menu("User") {
                        Button("Clear") { contextFieldBinding("user").wrappedValue = "" }
                        ForEach(userOptions(), id: \.self) { value in
                            Button(value) {
                                contextFieldBinding("user").wrappedValue = value
                            }
                        }
                    }
                    .frame(width: 140)
                    TextField("User", text: contextFieldBinding("user"))
                    Button("Go to User") {
                        onOpenUser(contextFieldBinding("user").wrappedValue)
                    }
                }

                TextField("Namespace", text: contextFieldBinding("namespace"))
            }

            Section("Additional Context Fields") {
                KeyValueEditor(fields: $item.fields, excludedKeys: ["cluster", "user", "namespace"])
            }
        }
    }

    private func contextFieldBinding(_ key: String) -> Binding<String> {
        Binding(
            get: {
                item.fields.first(where: { $0.key == key })?.value ?? ""
            },
            set: { newValue in
                if let index = item.fields.firstIndex(where: { $0.key == key }) {
                    item.fields[index].value = newValue
                } else {
                    item.fields.append(KeyValueField(key: key, value: newValue))
                }
            }
        )
    }

    private func clusterOptions() -> [String] {
        let current = contextFieldBinding("cluster").wrappedValue
        if current.isEmpty || clusterNames.contains(current) {
            return clusterNames
        }
        return [current] + clusterNames
    }

    private func userOptions() -> [String] {
        let current = contextFieldBinding("user").wrappedValue
        if current.isEmpty || userNames.contains(current) {
            return userNames
        }
        return [current] + userNames
    }
}

struct GenericItemEditor: View {
    let title: String
    @Binding var item: NamedItem
    var onNameChanged: (String, String) -> Void
    @State private var previousName: String = ""

    var body: some View {
        Form {
            Section("\(title) Settings") {
                TextField("Name", text: $item.name)
                    .onAppear { previousName = item.name }
                    .onSubmit {
                        onNameChanged(previousName, item.name)
                        previousName = item.name
                    }
                    .onChange(of: item.name) { newValue in
                        if !previousName.isEmpty, previousName != newValue {
                            onNameChanged(previousName, newValue)
                        }
                        previousName = newValue
                    }
            }

            Section("Fields") {
                KeyValueEditor(fields: $item.fields, excludedKeys: [])
            }
        }
    }
}

struct KeyValueEditor: View {
    @Binding var fields: [KeyValueField]
    let excludedKeys: Set<String>

    init(fields: Binding<[KeyValueField]>, excludedKeys: [String]) {
        _fields = fields
        self.excludedKeys = Set(excludedKeys)
    }

    private var visibleFieldIndices: [Int] {
        fields.indices.filter { !excludedKeys.contains(fields[$0].key) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !visibleFieldIndices.isEmpty {
                HStack {
                    Text("Key")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 250, alignment: .leading)
                    Text("Value")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            ForEach(visibleFieldIndices, id: \.self) { index in
                HStack(alignment: .top, spacing: 8) {
                    TextField("", text: $fields[index].key)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 250)
                    TextField("", text: $fields[index].value, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                    Button("Remove") {
                        let id = fields[index].id
                        fields.removeAll { $0.id == id }
                    }
                }
            }

            Button("Add Field") {
                fields.append(KeyValueField(key: "", value: ""))
            }
        }
    }
}

private struct GlassToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.ultraThinMaterial.opacity(configuration.isPressed ? 0.55 : 0.36))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(configuration.isPressed ? 0.22 : 0.14), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
    }
}

private struct GlassPrimaryPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.accentColor.opacity(configuration.isPressed ? 0.22 : 0.16))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
    }
}

private struct GlassDestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.red.opacity(configuration.isPressed ? 0.78 : 0.68))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
    }
}

struct WarningBanner: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(text)
                .foregroundStyle(.red)
            Spacer()
        }
        .padding(10)
        .background(Color.red.opacity(0.12))
        .cornerRadius(8)
    }
}

struct RelatedItemsColumn: View {
    let title: String
    let items: [String]
    let emptyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            if items.isEmpty {
                Text(emptyText)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items, id: \.self) { item in
                    Text(item)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct VersionsSheet: View {
    let versions: [KubeConfigViewModel.SavedVersion]
    var onRollback: (KubeConfigViewModel.SavedVersion) -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Version History")
                    .font(.title3)
                Spacer()
                Button("Close") {
                    onClose()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.cancelAction)
                .keyboardShortcut("w", modifiers: [.command])
            }
            Divider()
            if versions.isEmpty {
                Text("Версий пока нет")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(versions, id: \.id) { version in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(version.displayName)
                                .font(.body.monospaced())
                            Text(version.createdAt.formatted(date: .abbreviated, time: .standard))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Rollback to This Version") {
                            onRollback(version)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
    }
}

struct UpdateToast: View {
    let version: String
    let isInstalling: Bool
    let status: String
    var onUpdate: () -> Void
    var onLater: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("New version available")
                .font(.headline)
            Text("Version \(version)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Later") { onLater() }
                    .disabled(isInstalling)
                Spacer()
                Button("Update") { onUpdate() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isInstalling)
            }
        }
        .padding(12)
        .frame(width: 300)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        )
        .shadow(radius: 8, y: 2)
    }
}

struct UpdatesSheet: View {
    @ObservedObject var updater: ReleaseUpdater
    var onUpdate: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Updates")
                    .font(.title3)
                Spacer()
                Button("Close") { onClose() }
                    .buttonStyle(.borderedProminent)
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Current version")
                        .foregroundStyle(.secondary)
                    Text(updater.currentVersion)
                        .font(.body.monospaced())
                }
                GridRow {
                    Text("Available version")
                        .foregroundStyle(.secondary)
                    Text(updater.availableVersion)
                        .font(.body.monospaced())
                }
            }

            if !updater.installStatus.isEmpty {
                Text(updater.installStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button("Check for Updates") {
                    Task { await updater.checkForUpdates() }
                }
                .disabled(updater.isChecking || updater.isUpdateInProgress)

                if updater.isUpdateInProgress {
                    Button("Update") {
                        onUpdate()
                    }
                    .buttonStyle(.bordered)
                    .disabled(true)
                } else {
                    Button("Update") {
                        onUpdate()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!updater.hasNewerAvailableUpdate)
                }

                Spacer()
            }

            if let releaseURL = updater.availableUpdate?.releaseURL ?? updater.latestReleaseURL {
                Link("Open release page", destination: releaseURL)
                    .font(.caption)
            }

            Spacer()
        }
        .padding(14)
    }
}

struct AwsEksQuickAddSheet: View {
    @Binding var contextName: String
    @Binding var clusterArn: String
    @Binding var endpoint: String
    @Binding var certificateAuthorityData: String
    @Binding var region: String
    @Binding var awsProfile: String
    @Binding var message: String

    var onAdd: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close")

                Text("Quick Add AWS EKS")
                    .font(.title3)
                Spacer()
            }

            Divider()

            GroupBox("Required") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Cluster ARN (arn:aws:eks:region:account:cluster/name)", text: $clusterArn)
                    TextField("API server endpoint (https://...eks.amazonaws.com)", text: $endpoint)
                    TextField("AWS region (e.g. eu-central-1)", text: $region)
                }
                .textFieldStyle(.roundedBorder)
            }

            GroupBox("Optional") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Context name (default: cluster name from ARN)", text: $contextName)
                    TextField("AWS profile for exec env (AWS_PROFILE)", text: $awsProfile)
                    Text("certificate-authority-data")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $certificateAuthorityData)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 120)
                        .border(.quaternary)
                }
                .textFieldStyle(.roundedBorder)
            }

            if !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Create AWS EKS Context") {
                    onAdd()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }
}

struct ImportSnippetSheet: View {
    @Binding var rawText: String
    @Binding var previewText: String
    @Binding var prefix: String
    @Binding var replaceHost: String
    @Binding var message: String

    var onPreview: () -> Void
    var onMerge: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close")

                Text("Import Kubeconfig as New Entries")
                    .font(.title3)
            }

            HStack {
                TextField("Name prefix (optional)", text: $prefix)
                TextField("Replace 127.0.0.1 with host (optional)", text: $replaceHost)
            }

            Text("1) Paste kubeconfig")
                .font(.headline)
            TextEditor(text: $rawText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 220)
                .border(.quaternary)

            HStack {
                Button("Build Preview") { onPreview() }
                Button("Import as New Entries") { onMerge() }
                    .keyboardShortcut(.defaultAction)
            }

            Text("2) Review and edit preview")
                .font(.headline)
            TextEditor(text: $previewText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 220)
                .border(.quaternary)

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(16)
    }
}

struct ContextMergeSheet: View {
    @Binding var rawText: String
    @Binding var importedContextName: String
    @Binding var preview: ContextMergePreview?
    @Binding var selectedChangeIDs: Set<String>
    @Binding var message: String

    var onAnalyze: () -> Void
    var onApplySelected: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Merge Into Existing Context")
                .font(.title3)

            Text("Вставь kubeconfig целиком, проанализируй diff и выбери, какие изменения применить.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Import kubeconfig")
                .font(.headline)
            TextEditor(text: $rawText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 200)
                .border(.quaternary)

            HStack(spacing: 10) {
                Button("Analyze") { onAnalyze() }
                    .keyboardShortcut(.defaultAction)
                if let preview {
                    Picker("Imported context", selection: $importedContextName) {
                        ForEach(preview.importedContextNames, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .frame(maxWidth: 420)
                    .onChange(of: importedContextName) { _ in
                        onAnalyze()
                    }
                }
                Spacer()
                if let preview {
                    Button("Select all") {
                        selectedChangeIDs = Set(preview.changes.map(\.id))
                    }
                    Button("Clear") {
                        selectedChangeIDs.removeAll()
                    }
                }
            }

            if let preview {
                if !preview.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(preview.warnings, id: \.self) { warning in
                            WarningBanner(text: warning)
                        }
                    }
                }

                GroupBox("Diff Preview") {
                    if preview.changes.isEmpty {
                        Text("Изменений не найдено")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        List(preview.changes, id: \.id) { change in
                            VStack(alignment: .leading, spacing: 6) {
                                Toggle(isOn: Binding(
                                    get: { selectedChangeIDs.contains(change.id) },
                                    set: { checked in
                                        if checked { selectedChangeIDs.insert(change.id) }
                                        else { selectedChangeIDs.remove(change.id) }
                                    }
                                )) {
                                    Text("\(change.entity.rawValue.uppercased()) • \(change.targetName) • \(change.key)")
                                        .font(.headline)
                                }

                                HStack(alignment: .top, spacing: 10) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("OLD")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                        Text(change.oldValue.isEmpty ? "<empty>" : change.oldValue)
                                            .font(.system(.caption, design: .monospaced))
                                            .lineLimit(3)
                                            .textSelection(.enabled)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.right")
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("NEW")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                        Text(change.newValue.isEmpty ? "<empty>" : change.newValue)
                                            .font(.system(.caption, design: .monospaced))
                                            .lineLimit(3)
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }

            HStack {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Apply Selected") {
                    onApplySelected()
                }
                .disabled(preview == nil)
            }
        }
        .padding(16)
    }
}
