import Foundation
import Combine
import CryptoKit
import Yams
import SwiftGitX

public struct KeyValueField: Identifiable, Hashable {
    public let id: UUID
    public var key: String
    public var value: String

    public init(id: UUID = UUID(), key: String = "", value: String = "") {
        self.id = id
        self.key = key
        self.value = value
    }
}

public struct NamedItem: Identifiable, Hashable {
    public let id: UUID
    public var name: String
    public var fields: [KeyValueField]
    public var includeInExport: Bool

    public init(id: UUID = UUID(), name: String, fields: [KeyValueField] = [], includeInExport: Bool = true) {
        self.id = id
        self.name = name
        self.fields = fields
        self.includeInExport = includeInExport
    }
}

public enum SidebarSelection: Hashable {
    case context(UUID)
    case cluster(UUID)
    case user(UUID)
}

public enum MergeEntityType: String, Hashable {
    case context
    case cluster
    case user
}

public struct MergeFieldChange: Identifiable, Hashable {
    public let id: String
    public let entity: MergeEntityType
    public let targetName: String
    public let key: String
    public let oldValue: String
    public let newValue: String

    public init(id: String, entity: MergeEntityType, targetName: String, key: String, oldValue: String, newValue: String) {
        self.id = id
        self.entity = entity
        self.targetName = targetName
        self.key = key
        self.oldValue = oldValue
        self.newValue = newValue
    }
}

public struct ContextMergePreview: Hashable {
    public let importedContextNames: [String]
    public let selectedImportedContextName: String
    public let changes: [MergeFieldChange]
    public let warnings: [String]

    public init(importedContextNames: [String], selectedImportedContextName: String, changes: [MergeFieldChange], warnings: [String]) {
        self.importedContextNames = importedContextNames
        self.selectedImportedContextName = selectedImportedContextName
        self.changes = changes
        self.warnings = warnings
    }
}

public extension NamedItem {
    func fieldValue(_ key: String) -> String {
        fields.first(where: { $0.key == key })?.value ?? ""
    }

    mutating func setField(_ key: String, value: String) {
        if let index = fields.firstIndex(where: { $0.key == key }) {
            fields[index].value = value
            return
        }
        fields.append(KeyValueField(key: key, value: value))
    }
}

@MainActor
public final class KubeConfigViewModel: ObservableObject {
    @Published public var contexts: [NamedItem] = []
    @Published public var clusters: [NamedItem] = []
    @Published public var users: [NamedItem] = []
    @Published public var currentContext: String = ""
    @Published public var currentPath: URL?
    @Published public var statusMessage: String = ""
    @Published public var selection: SidebarSelection?
    @Published public var backgroundValidationEnabled: Bool = true
    @Published public var validationMessage: String = "YAML validation: off"
    @Published public var kubectlValidationEnabled: Bool = true
    @Published public var hasUnsavedChanges: Bool = false
    @Published public var canUndo: Bool = false
    @Published public var canRedo: Bool = false
    @Published public var draftPath: URL?

    private var rootExtras: [String: Any] = [:]
    private var undoStack: [HistorySnapshot] = []
    private var redoStack: [HistorySnapshot] = []
    private var lastSnapshotYAML: String = ""
    private var suppressHistoryTracking = false
    private var currentSessionKey: String = "unsaved-\(UUID().uuidString)"

    private struct HistorySnapshot {
        let yaml: String
        let reason: String
        let createdAt: Date
    }

    private struct ExportProjection {
        let contexts: [NamedItem]
        let clusters: [NamedItem]
        let users: [NamedItem]
        let currentContext: String
        let droppedContexts: Int
        let droppedClusters: Int
        let droppedUsers: Int
    }

    private struct StoreItem {
        let name: String
        let fields: [KeyValueField]
        let includeInExport: Bool
    }

    public struct SavedVersion: Identifiable, Hashable, Sendable {
        public let id: String
        public let fileURL: URL
        public let createdAt: Date
        public let displayName: String
    }

    public init() {
        newEmpty()
    }

    public var defaultKubeconfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kube")
            .appendingPathComponent("config")
    }

    public var defaultKubeDirectoryURL: URL {
        defaultKubeconfigURL.deletingLastPathComponent()
    }

    private var appSupportDirectoryURL: URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("KubeconfigEditor")
        return base
    }

    public func newEmpty() {
        suppressHistoryTracking = true
        currentSessionKey = "unsaved-\(UUID().uuidString)"
        contexts = [NamedItem(name: "new-context", fields: [
            KeyValueField(key: "cluster", value: "new-cluster"),
            KeyValueField(key: "user", value: "new-user")
        ])]
        clusters = [NamedItem(name: "new-cluster", fields: [
            KeyValueField(key: "server", value: "https://127.0.0.1:6443")
        ])]
        users = [NamedItem(name: "new-user", fields: [KeyValueField(key: "token", value: "")])]
        currentContext = contexts.first?.name ?? ""
        rootExtras = [
            "apiVersion": "v1",
            "kind": "Config",
            "preferences": [:]
        ]
        selection = contexts.first.map { .context($0.id) }
        currentPath = nil
        let yaml = (try? buildCurrentYAML()) ?? ""
        try? createDraftFile(fromYAML: yaml)
        try? syncGitWorkingTree(yaml: yaml)
        resetHistory(reason: "new-empty")
        suppressHistoryTracking = false
        hasUnsavedChanges = false
        triggerBackgroundValidationIfNeeded()
        statusMessage = "Создан новый конфиг в памяти"
    }

    public func load(from url: URL) throws {
        suppressHistoryTracking = true
        let fileSession = sessionKey(for: url)
        let workspaceURL = workspaceFileURL(for: url)
        let legacyWorkspaceURL = legacyWorkspaceFileURL(for: url)
        let manager = FileManager.default
        let workspaceExists = manager.fileExists(atPath: workspaceURL.path)
        let legacyWorkspaceExists = manager.fileExists(atPath: legacyWorkspaceURL.path)
        let detachedStoreExists = manager.fileExists(atPath: detachedStoreURL(for: url).path)
        let recoveredWorkspace = workspaceExists ? nil : tryLoadLatestWorkspaceSnapshot(for: url, sessionKey: fileSession)
        let useRecoveredWorkspace: Bool = {
            guard let recoveredWorkspace else { return false }
            if recoveredWorkspace.contains("# kce:export=") {
                return true
            }
            // If detached store exists, prefer it over old history snapshots without workspace metadata.
            return !detachedStoreExists
        }()
        let sourceURL = workspaceExists ? workspaceURL : (legacyWorkspaceExists ? legacyWorkspaceURL : url)
        let text: String
        if useRecoveredWorkspace, let recoveredWorkspace {
            text = recoveredWorkspace
        } else {
            text = try String(contentsOf: sourceURL, encoding: .utf8)
        }
        let loaded = try Yams.load(yaml: text)
        guard let root = loaded as? [String: Any] else {
            throw NSError(domain: "KubeconfigEditor", code: 1001, userInfo: [NSLocalizedDescriptionKey: "Неверный формат kubeconfig: корень должен быть map"])
        }

        currentSessionKey = fileSession
        currentPath = url
        currentContext = root["current-context"] as? String ?? ""
        contexts = parseNamedItems(array: root["contexts"], nestedKey: "context")
        clusters = parseNamedItems(array: root["clusters"], nestedKey: "cluster")
        users = parseNamedItems(array: root["users"], nestedKey: "user")

        rootExtras = root
        rootExtras.removeValue(forKey: "contexts")
        rootExtras.removeValue(forKey: "clusters")
        rootExtras.removeValue(forKey: "users")
        rootExtras.removeValue(forKey: "current-context")

        if workspaceExists || legacyWorkspaceExists || useRecoveredWorkspace {
            applyWorkspaceExportFlags(from: text)
        } else {
            // Backward-compatibility with old detached store before workspace sidecar existed.
            try restoreDetachedStore(for: url)
        }

        if let first = contexts.first {
            selection = .context(first.id)
        } else if let first = clusters.first {
            selection = .cluster(first.id)
        } else if let first = users.first {
            selection = .user(first.id)
        } else {
            selection = nil
        }

        let workspaceYAML = try buildWorkspaceYAML()
        if !workspaceExists {
            try writeWorkspaceFile(for: url, contents: workspaceYAML)
            if legacyWorkspaceExists {
                try? manager.removeItem(at: legacyWorkspaceURL)
            }
        }
        try createDraftFile(fromYAML: workspaceYAML)
        try? syncGitWorkingTree(yaml: workspaceYAML)
        try? ensureInitialGitSnapshot(yaml: workspaceYAML, reason: "initial-load")
        resetHistory(reason: "load")
        suppressHistoryTracking = false
        hasUnsavedChanges = false
        triggerBackgroundValidationIfNeeded()
        if workspaceExists {
            statusMessage = "Загружен: \(url.path) (workspace: \(workspaceURL.lastPathComponent))"
        } else if useRecoveredWorkspace {
            statusMessage = "Загружен: \(url.path) (workspace восстановлен из истории: \(workspaceURL.lastPathComponent))"
        } else {
            statusMessage = "Загружен: \(url.path) (workspace создан: \(workspaceURL.lastPathComponent))"
        }
    }

    public func loadDefaultKubeconfigIfExists() {
        guard currentPath == nil else { return }

        let url = defaultKubeconfigURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            statusMessage = "Файл по умолчанию не найден: \(url.path)"
            return
        }

        do {
            try load(from: url)
        } catch {
            statusMessage = "Не удалось загрузить файл по умолчанию: \(error.localizedDescription)"
        }
    }

    public func normalizeImportText(_ text: String, serverHostReplacement: String, namePrefix: String) throws -> String {
        var parsed = try parseKubeconfigText(text)

        if !serverHostReplacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parsed.clusters = replaceLocalhostServer(in: parsed.clusters, with: serverHostReplacement)
        }

        if !namePrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parsed = applyPrefix(prefix: namePrefix, to: parsed)
        }

        var output = parsed.extras
        output["apiVersion"] = output["apiVersion"] ?? "v1"
        output["kind"] = output["kind"] ?? "Config"
        output["current-context"] = parsed.currentContext
        output["contexts"] = encodeNamedItems(items: parsed.contexts, nestedKey: "context")
        output["clusters"] = encodeNamedItems(items: parsed.clusters, nestedKey: "cluster")
        output["users"] = encodeNamedItems(items: parsed.users, nestedKey: "user")
        return try Yams.dump(object: output)
    }

    public func mergeImportText(_ text: String) throws {
        var parsed = try parseKubeconfigText(text)

        var usedClusterNames = Set(clusters.map(\.name))
        var clusterNameMap: [String: String] = [:]
        for index in parsed.clusters.indices {
            let oldName = parsed.clusters[index].name
            let newName = makeUniqueName(base: oldName, used: &usedClusterNames)
            parsed.clusters[index].name = newName
            clusterNameMap[oldName] = newName
        }

        var usedUserNames = Set(users.map(\.name))
        var userNameMap: [String: String] = [:]
        for index in parsed.users.indices {
            let oldName = parsed.users[index].name
            let newName = makeUniqueName(base: oldName, used: &usedUserNames)
            parsed.users[index].name = newName
            userNameMap[oldName] = newName
        }

        var usedContextNames = Set(contexts.map(\.name))
        var contextNameMap: [String: String] = [:]
        for index in parsed.contexts.indices {
            let oldName = parsed.contexts[index].name
            let newName = makeUniqueName(base: oldName, used: &usedContextNames)
            parsed.contexts[index].name = newName
            contextNameMap[oldName] = newName

            let clusterRef = parsed.contexts[index].fieldValue("cluster")
            if let mapped = clusterNameMap[clusterRef], !clusterRef.isEmpty {
                parsed.contexts[index].setField("cluster", value: mapped)
            }

            let userRef = parsed.contexts[index].fieldValue("user")
            if let mapped = userNameMap[userRef], !userRef.isEmpty {
                parsed.contexts[index].setField("user", value: mapped)
            }
        }

        clusters.append(contentsOf: parsed.clusters)
        users.append(contentsOf: parsed.users)
        contexts.append(contentsOf: parsed.contexts)

        if currentContext.isEmpty {
            let importedCurrent = contextNameMap[parsed.currentContext]
            currentContext = importedCurrent ?? parsed.contexts.first?.name ?? ""
        }

        if let first = parsed.contexts.first {
            selection = .context(first.id)
        } else if let first = parsed.clusters.first {
            selection = .cluster(first.id)
        } else if let first = parsed.users.first {
            selection = .user(first.id)
        }

        statusMessage = "Импортировано: contexts \(parsed.contexts.count), clusters \(parsed.clusters.count), users \(parsed.users.count)"
    }

    public func buildContextMergePreview(importText: String, intoContextID: UUID, importedContextName: String? = nil) throws -> ContextMergePreview {
        guard let targetContext = contexts.first(where: { $0.id == intoContextID }) else {
            throw NSError(domain: "KubeconfigEditor", code: 1016, userInfo: [NSLocalizedDescriptionKey: "Целевой context не найден"])
        }

        let parsed = try parseKubeconfigText(importText)
        let importedContextNames = parsed.contexts.map(\.name)
        guard !importedContextNames.isEmpty else {
            throw NSError(domain: "KubeconfigEditor", code: 1017, userInfo: [NSLocalizedDescriptionKey: "В импортируемом kubeconfig нет contexts"])
        }

        let selectedImportedName: String
        if let explicit = importedContextName?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            selectedImportedName = explicit
        } else if !parsed.currentContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            selectedImportedName = parsed.currentContext
        } else {
            selectedImportedName = importedContextNames[0]
        }

        guard let importedContext = parsed.contexts.first(where: { $0.name == selectedImportedName }) else {
            throw NSError(domain: "KubeconfigEditor", code: 1018, userInfo: [NSLocalizedDescriptionKey: "Context '\(selectedImportedName)' не найден в импорте"])
        }

        var warnings: [String] = []
        var changes: [MergeFieldChange] = []

        appendFieldChanges(
            changes: &changes,
            entity: .context,
            targetName: targetContext.name,
            targetFields: targetContext.fields,
            sourceFields: importedContext.fields
        )

        let targetClusterName = targetContext.fieldValue("cluster").trimmingCharacters(in: .whitespacesAndNewlines)
        let importedClusterName = importedContext.fieldValue("cluster").trimmingCharacters(in: .whitespacesAndNewlines)
        if targetClusterName.isEmpty {
            warnings.append("У целевого context пустая ссылка на cluster, merge cluster-полей пропущен.")
        } else if importedClusterName.isEmpty {
            warnings.append("У импортируемого context пустая ссылка на cluster, merge cluster-полей пропущен.")
        } else if let targetCluster = clusters.first(where: { $0.name == targetClusterName }) {
            if let importedCluster = parsed.clusters.first(where: { $0.name == importedClusterName }) {
                appendFieldChanges(
                    changes: &changes,
                    entity: .cluster,
                    targetName: targetCluster.name,
                    targetFields: targetCluster.fields,
                    sourceFields: importedCluster.fields
                )
            } else {
                warnings.append("Cluster '\(importedClusterName)' из импорта не найден, merge cluster-полей пропущен.")
            }
        } else {
            warnings.append("Cluster '\(targetClusterName)' у целевого context не найден, merge cluster-полей пропущен.")
        }

        let targetUserName = targetContext.fieldValue("user").trimmingCharacters(in: .whitespacesAndNewlines)
        let importedUserName = importedContext.fieldValue("user").trimmingCharacters(in: .whitespacesAndNewlines)
        if targetUserName.isEmpty {
            warnings.append("У целевого context пустая ссылка на user, merge user-полей пропущен.")
        } else if importedUserName.isEmpty {
            warnings.append("У импортируемого context пустая ссылка на user, merge user-полей пропущен.")
        } else if let targetUser = users.first(where: { $0.name == targetUserName }) {
            if let importedUser = parsed.users.first(where: { $0.name == importedUserName }) {
                appendFieldChanges(
                    changes: &changes,
                    entity: .user,
                    targetName: targetUser.name,
                    targetFields: targetUser.fields,
                    sourceFields: importedUser.fields
                )
            } else {
                warnings.append("User '\(importedUserName)' из импорта не найден, merge user-полей пропущен.")
            }
        } else {
            warnings.append("User '\(targetUserName)' у целевого context не найден, merge user-полей пропущен.")
        }

        return ContextMergePreview(
            importedContextNames: importedContextNames.sorted(),
            selectedImportedContextName: selectedImportedName,
            changes: changes,
            warnings: warnings
        )
    }

    public func applyContextMergePreview(intoContextID: UUID, preview: ContextMergePreview, selectedChangeIDs: Set<String>) throws {
        guard !selectedChangeIDs.isEmpty else {
            statusMessage = "Нечего применять: не выбраны изменения"
            return
        }
        guard let contextIndex = contexts.firstIndex(where: { $0.id == intoContextID }) else {
            throw NSError(domain: "KubeconfigEditor", code: 1019, userInfo: [NSLocalizedDescriptionKey: "Целевой context не найден"])
        }

        var applied = 0
        for change in preview.changes where selectedChangeIDs.contains(change.id) {
            switch change.entity {
            case .context:
                contexts[contextIndex].setField(change.key, value: change.newValue)
                applied += 1
            case .cluster:
                if let idx = clusters.firstIndex(where: { $0.name == change.targetName }) {
                    clusters[idx].setField(change.key, value: change.newValue)
                    applied += 1
                }
            case .user:
                if let idx = users.firstIndex(where: { $0.name == change.targetName }) {
                    users[idx].setField(change.key, value: change.newValue)
                    applied += 1
                }
            }
        }

        statusMessage = "Merge применен: \(applied) изменений"
        triggerBackgroundValidationIfNeeded()
    }

    public func save(to url: URL) throws {
        let oldSession = currentSessionKey
        let newSession = sessionKey(for: url)
        let projection = projectedForExport()
        if projection.currentContext != currentContext {
            currentContext = projection.currentContext
        }
        let yaml = try buildExportYAML(projection: projection)
        let kubectlInfo = try validateBeforeSave(yaml)
        let tmpURL = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        try yaml.write(to: tmpURL, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmpURL)
        if !FileManager.default.fileExists(atPath: url.path) {
            try yaml.write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: tmpURL)
        }
        currentPath = url
        if oldSession != newSession {
            migrateSessionStorage(from: oldSession, to: newSession)
            currentSessionKey = newSession
        }
        let workspaceYAML = try buildWorkspaceYAML()
        try writeWorkspaceFile(for: url, contents: workspaceYAML)
        try createDraftFile(fromYAML: workspaceYAML)
        try? syncGitWorkingTree(yaml: workspaceYAML)
        try? commitGitSnapshot(yaml: workspaceYAML, reason: "save")
        hasUnsavedChanges = false
        if let kubectlInfo {
            validationMessage = kubectlInfo
        } else {
            validationMessage = "YAML validation: OK"
        }
        if projection.droppedContexts > 0 || projection.droppedClusters > 0 || projection.droppedUsers > 0 {
            statusMessage = "Сохранено: \(url.path). Исключено: contexts \(projection.droppedContexts), clusters \(projection.droppedClusters), users \(projection.droppedUsers)"
        } else {
            statusMessage = "Сохранено: \(url.path)"
        }
        if backgroundValidationEnabled {
            validateCurrentYaml()
        }
    }

    public func backup() throws {
        guard let source = currentPath else {
            throw NSError(domain: "KubeconfigEditor", code: 1002, userInfo: [NSLocalizedDescriptionKey: "Сначала открой файл kubeconfig"])
        }

        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backupURL = source.deletingPathExtension().appendingPathExtension("backup.\(timestamp).yml")
        try FileManager.default.copyItem(at: source, to: backupURL)
        statusMessage = "Бэкап создан: \(backupURL.lastPathComponent)"
    }

    public func addContext() {
        let item = NamedItem(name: uniqueName(base: "context", in: contexts), fields: [
            KeyValueField(key: "cluster", value: clusters.first?.name ?? ""),
            KeyValueField(key: "user", value: users.first?.name ?? "")
        ], includeInExport: true)
        contexts.append(item)
        selection = .context(item.id)
        if currentContext.isEmpty { currentContext = item.name }
        triggerBackgroundValidationIfNeeded()
    }

    public func addCluster() {
        let item = NamedItem(name: uniqueName(base: "cluster", in: clusters), fields: [KeyValueField(key: "server", value: "")], includeInExport: true)
        clusters.append(item)
        selection = .cluster(item.id)
        triggerBackgroundValidationIfNeeded()
    }

    public func addUser() {
        let item = NamedItem(name: uniqueName(base: "user", in: users), fields: [KeyValueField(key: "token", value: "")], includeInExport: true)
        users.append(item)
        selection = .user(item.id)
        triggerBackgroundValidationIfNeeded()
    }

    public func addAWSEKSContext(
        contextName: String,
        clusterArn: String,
        endpoint: String,
        certificateAuthorityData: String,
        region: String,
        awsProfile: String
    ) throws {
        let cleanArn = clusterArn.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanCA = certificateAuthorityData.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanRegion = region.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanProfile = awsProfile.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanArn.isEmpty else {
            throw NSError(domain: "KubeconfigEditor", code: 1030, userInfo: [NSLocalizedDescriptionKey: "Cluster ARN is required"])
        }
        guard !cleanEndpoint.isEmpty else {
            throw NSError(domain: "KubeconfigEditor", code: 1031, userInfo: [NSLocalizedDescriptionKey: "API server endpoint is required"])
        }
        guard !cleanRegion.isEmpty else {
            throw NSError(domain: "KubeconfigEditor", code: 1032, userInfo: [NSLocalizedDescriptionKey: "AWS region is required"])
        }

        let clusterNameFromArn = eksClusterName(fromArn: cleanArn) ?? "eks-cluster"
        let baseContextName: String
        let cleanedContextName = contextName.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanedContextName.isEmpty {
            baseContextName = clusterNameFromArn
        } else {
            baseContextName = cleanedContextName
        }

        let clusterRefName = uniqueName(base: cleanArn, in: clusters)
        let userRefName = uniqueName(base: cleanArn, in: users)
        let contextRefName = uniqueName(base: baseContextName, in: contexts)

        var clusterFields: [KeyValueField] = [
            KeyValueField(key: "server", value: cleanEndpoint)
        ]
        if !cleanCA.isEmpty {
            clusterFields.append(KeyValueField(key: "certificate-authority-data", value: cleanCA))
        }

        let execArgs: [Any] = [
            "--region", cleanRegion,
            "eks", "get-token",
            "--cluster-name", clusterNameFromArn,
            "--output", "json"
        ]
        var execObject: [String: Any] = [
            "apiVersion": "client.authentication.k8s.io/v1beta1",
            "command": "aws",
            "args": execArgs,
            "interactiveMode": "IfAvailable",
            "provideClusterInfo": false
        ]
        if !cleanProfile.isEmpty {
            execObject["env"] = [
                [
                    "name": "AWS_PROFILE",
                    "value": cleanProfile
                ]
            ]
        }
        let execValue = anyToString(execObject)

        let clusterItem = NamedItem(
            name: clusterRefName,
            fields: clusterFields,
            includeInExport: true
        )
        let userItem = NamedItem(
            name: userRefName,
            fields: [KeyValueField(key: "exec", value: execValue)],
            includeInExport: true
        )
        let contextItem = NamedItem(
            name: contextRefName,
            fields: [
                KeyValueField(key: "cluster", value: clusterRefName),
                KeyValueField(key: "user", value: userRefName)
            ],
            includeInExport: true
        )

        clusters.append(clusterItem)
        users.append(userItem)
        contexts.append(contextItem)

        selection = .context(contextItem.id)
        if currentContext.isEmpty {
            currentContext = contextItem.name
        }
        statusMessage = "AWS EKS context added: \(contextItem.name)"
        triggerBackgroundValidationIfNeeded()
    }

    public func deleteSelected() {
        guard let selection else { return }

        switch selection {
        case .context(let id):
            if let index = contexts.firstIndex(where: { $0.id == id }) {
                let removed = contexts.remove(at: index)
                if currentContext == removed.name {
                    currentContext = contexts.first?.name ?? ""
                }
            }
            self.selection = contexts.first.map { .context($0.id) }
        case .cluster(let id):
            clusters.removeAll { $0.id == id }
            self.selection = clusters.first.map { .cluster($0.id) }
        case .user(let id):
            users.removeAll { $0.id == id }
            self.selection = users.first.map { .user($0.id) }
        }
        triggerBackgroundValidationIfNeeded()
    }

    public func deleteContexts(ids: Set<UUID>, cascade: Bool) {
        guard !ids.isEmpty else { return }
        let removed = contexts.filter { ids.contains($0.id) }
        let removedNames = removed.map(\.name)
        contexts.removeAll { ids.contains($0.id) }
        if removedNames.contains(currentContext) {
            currentContext = contexts.first?.name ?? ""
        }

        if cascade {
            let removedClusterNames = Set(removed.map { $0.fieldValue("cluster").trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            let removedUserNames = Set(removed.map { $0.fieldValue("user").trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            clusters.removeAll { cluster in
                removedClusterNames.contains(cluster.name) &&
                !contexts.contains(where: { context in context.fieldValue("cluster") == cluster.name })
            }
            users.removeAll { user in
                removedUserNames.contains(user.name) &&
                !contexts.contains(where: { context in context.fieldValue("user") == user.name })
            }
            statusMessage = "Удалено contexts каскадно: \(removedNames.count)"
        } else {
            statusMessage = "Удалено contexts: \(removedNames.count)"
        }
        triggerBackgroundValidationIfNeeded()
    }

    public func deleteClusters(ids: Set<UUID>, cascade: Bool) {
        guard !ids.isEmpty else { return }
        let removedClusters = clusters.filter { ids.contains($0.id) }
        let removedClusterNames = Set(removedClusters.map(\.name))
        clusters.removeAll { ids.contains($0.id) }

        var removedContextsCount = 0
        var removedUsersCount = 0
        if cascade {
            let contextIDsToRemove = Set(
                contexts
                    .filter { removedClusterNames.contains($0.fieldValue("cluster")) }
                    .map(\.id)
            )
            removedContextsCount = contextIDsToRemove.count
            if removedContextsCount > 0 {
                let removedContexts = contexts.filter { contextIDsToRemove.contains($0.id) }
                contexts.removeAll { contextIDsToRemove.contains($0.id) }
                if removedContexts.map(\.name).contains(currentContext) {
                    currentContext = contexts.first?.name ?? ""
                }

                let possiblyOrphanUsers = Set(
                    removedContexts
                        .map { $0.fieldValue("user").trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                )
                let before = users.count
                users.removeAll { user in
                    possiblyOrphanUsers.contains(user.name) &&
                    !contexts.contains(where: { context in context.fieldValue("user") == user.name })
                }
                removedUsersCount = before - users.count
            }
            statusMessage = "Удалено clusters: \(removedClusterNames.count), contexts: \(removedContextsCount), users: \(removedUsersCount)"
        } else {
            statusMessage = "Удалено clusters: \(removedClusterNames.count)"
        }
        triggerBackgroundValidationIfNeeded()
    }

    public func deleteUsers(ids: Set<UUID>, cascade: Bool) {
        guard !ids.isEmpty else { return }
        let removedUsers = users.filter { ids.contains($0.id) }
        let removedUserNames = Set(removedUsers.map(\.name))
        users.removeAll { ids.contains($0.id) }

        var removedContextsCount = 0
        var removedClustersCount = 0
        if cascade {
            let contextIDsToRemove = Set(
                contexts
                    .filter { removedUserNames.contains($0.fieldValue("user")) }
                    .map(\.id)
            )
            removedContextsCount = contextIDsToRemove.count
            if removedContextsCount > 0 {
                let removedContexts = contexts.filter { contextIDsToRemove.contains($0.id) }
                contexts.removeAll { contextIDsToRemove.contains($0.id) }
                if removedContexts.map(\.name).contains(currentContext) {
                    currentContext = contexts.first?.name ?? ""
                }

                let possiblyOrphanClusters = Set(
                    removedContexts
                        .map { $0.fieldValue("cluster").trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                )
                let before = clusters.count
                clusters.removeAll { cluster in
                    possiblyOrphanClusters.contains(cluster.name) &&
                    !contexts.contains(where: { context in context.fieldValue("cluster") == cluster.name })
                }
                removedClustersCount = before - clusters.count
            }
            statusMessage = "Удалено users: \(removedUserNames.count), contexts: \(removedContextsCount), clusters: \(removedClustersCount)"
        } else {
            statusMessage = "Удалено users: \(removedUserNames.count)"
        }
        triggerBackgroundValidationIfNeeded()
    }

    public func toggleContextExport(_ id: UUID) {
        guard let index = contexts.firstIndex(where: { $0.id == id }) else { return }
        let wasIncluded = contexts[index].includeInExport
        contexts[index].includeInExport.toggle()

        if wasIncluded && !contexts[index].includeInExport && currentContext == contexts[index].name {
            currentContext = contexts.first(where: { $0.includeInExport && $0.id != id })?.name ?? ""
        } else if !wasIncluded && contexts[index].includeInExport && currentContext.isEmpty {
            currentContext = contexts[index].name
        }
        triggerBackgroundValidationIfNeeded()
    }

    public func toggleClusterExport(_ id: UUID) {
        guard let index = clusters.firstIndex(where: { $0.id == id }) else { return }
        clusters[index].includeInExport.toggle()
        triggerBackgroundValidationIfNeeded()
    }

    public func toggleUserExport(_ id: UUID) {
        guard let index = users.firstIndex(where: { $0.id == id }) else { return }
        users[index].includeInExport.toggle()
        triggerBackgroundValidationIfNeeded()
    }

    public func activateContextAndSave(_ contextID: UUID?) throws {
        guard let contextID else {
            throw NSError(domain: "KubeconfigEditor", code: 1003, userInfo: [NSLocalizedDescriptionKey: "Выбери context"])
        }
        guard let context = contexts.first(where: { $0.id == contextID }) else {
            throw NSError(domain: "KubeconfigEditor", code: 1004, userInfo: [NSLocalizedDescriptionKey: "Context не найден"])
        }

        currentContext = context.name
        let saveURL = currentPath ?? defaultKubeconfigURL
        try FileManager.default.createDirectory(at: saveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try save(to: saveURL)
        statusMessage = "Активирован context '\(context.name)' и сохранен \(saveURL.path)"
    }

    public func exportContexts(ids: Set<UUID>, to url: URL) throws {
        guard !ids.isEmpty else {
            throw NSError(domain: "KubeconfigEditor", code: 1022, userInfo: [NSLocalizedDescriptionKey: "Выбери хотя бы один context для экспорта"])
        }

        let selected = contexts.filter { ids.contains($0.id) }
        guard !selected.isEmpty else {
            throw NSError(domain: "KubeconfigEditor", code: 1023, userInfo: [NSLocalizedDescriptionKey: "Выбранные contexts не найдены"])
        }

        let clusterNames = Set(selected.map { $0.fieldValue("cluster").trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        let userNames = Set(selected.map { $0.fieldValue("user").trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })

        let missingClusters = clusterNames.subtracting(Set(clusters.map(\.name)))
        let missingUsers = userNames.subtracting(Set(users.map(\.name)))
        if !missingClusters.isEmpty || !missingUsers.isEmpty {
            let parts = [
                missingClusters.isEmpty ? nil : "clusters: \(missingClusters.sorted().joined(separator: ", "))",
                missingUsers.isEmpty ? nil : "users: \(missingUsers.sorted().joined(separator: ", "))"
            ].compactMap { $0 }
            throw NSError(domain: "KubeconfigEditor", code: 1024, userInfo: [NSLocalizedDescriptionKey: "Экспорт невозможен, отсутствуют связи: \(parts.joined(separator: "; "))"])
        }

        let exportClusters = clusters.filter { clusterNames.contains($0.name) }
        let exportUsers = users.filter { userNames.contains($0.name) }
        let exportCurrentContext = selected.first?.name ?? ""

        let projection = ExportProjection(
            contexts: selected,
            clusters: exportClusters,
            users: exportUsers,
            currentContext: exportCurrentContext,
            droppedContexts: 0,
            droppedClusters: 0,
            droppedUsers: 0
        )

        let yaml = try buildExportYAML(projection: projection)
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        statusMessage = "Экспортировано contexts: \(selected.count) -> \(url.path)"
    }

    public func syncContextReferences(oldName: String, newName: String, type: String) {
        guard oldName != newName else { return }

        for ctxIndex in contexts.indices {
            for fieldIndex in contexts[ctxIndex].fields.indices where contexts[ctxIndex].fields[fieldIndex].key == type && contexts[ctxIndex].fields[fieldIndex].value == oldName {
                contexts[ctxIndex].fields[fieldIndex].value = newName
            }
        }

        if type == "context" && currentContext == oldName {
            currentContext = newName
        }
        triggerBackgroundValidationIfNeeded()
    }

    public func renameClusterEverywhere(oldName: String, newName: String) throws {
        let oldTrimmed = oldName.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTrimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oldTrimmed.isEmpty, !newTrimmed.isEmpty else {
            throw NSError(domain: "KubeconfigEditor", code: 1005, userInfo: [NSLocalizedDescriptionKey: "Old/New имя cluster не должно быть пустым"])
        }
        guard oldTrimmed != newTrimmed else { return }
        guard let index = clusters.firstIndex(where: { $0.name == oldTrimmed }) else {
            throw NSError(domain: "KubeconfigEditor", code: 1006, userInfo: [NSLocalizedDescriptionKey: "Cluster '\(oldTrimmed)' не найден"])
        }
        if clusters.contains(where: { $0.name == newTrimmed }) {
            throw NSError(domain: "KubeconfigEditor", code: 1007, userInfo: [NSLocalizedDescriptionKey: "Cluster '\(newTrimmed)' уже существует"])
        }

        clusters[index].name = newTrimmed
        syncContextReferences(oldName: oldTrimmed, newName: newTrimmed, type: "cluster")
        statusMessage = "Cluster переименован: \(oldTrimmed) -> \(newTrimmed)"
    }

    public func renameUserEverywhere(oldName: String, newName: String) throws {
        let oldTrimmed = oldName.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTrimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oldTrimmed.isEmpty, !newTrimmed.isEmpty else {
            throw NSError(domain: "KubeconfigEditor", code: 1008, userInfo: [NSLocalizedDescriptionKey: "Old/New имя user не должно быть пустым"])
        }
        guard oldTrimmed != newTrimmed else { return }
        guard let index = users.firstIndex(where: { $0.name == oldTrimmed }) else {
            throw NSError(domain: "KubeconfigEditor", code: 1009, userInfo: [NSLocalizedDescriptionKey: "User '\(oldTrimmed)' не найден"])
        }
        if users.contains(where: { $0.name == newTrimmed }) {
            throw NSError(domain: "KubeconfigEditor", code: 1010, userInfo: [NSLocalizedDescriptionKey: "User '\(newTrimmed)' уже существует"])
        }

        users[index].name = newTrimmed
        syncContextReferences(oldName: oldTrimmed, newName: newTrimmed, type: "user")
        statusMessage = "User переименован: \(oldTrimmed) -> \(newTrimmed)"
    }

    public func contextsLinkedToCluster(_ clusterName: String) -> [NamedItem] {
        contexts.filter { $0.fieldValue("cluster") == clusterName }
    }

    public func usersLinkedToCluster(_ clusterName: String) -> [NamedItem] {
        let userNames = Set(
            contextsLinkedToCluster(clusterName)
                .map { $0.fieldValue("user").trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        return users
            .filter { userNames.contains($0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func contextsLinkedToUser(_ userName: String) -> [NamedItem] {
        contexts.filter { $0.fieldValue("user") == userName }
    }

    public func clustersLinkedToUser(_ userName: String) -> [NamedItem] {
        let clusterNames = Set(
            contextsLinkedToUser(userName)
                .map { $0.fieldValue("cluster").trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        return clusters
            .filter { clusterNames.contains($0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func deleteContext(_ contextID: UUID, cascade: Bool) throws {
        guard let index = contexts.firstIndex(where: { $0.id == contextID }) else {
            throw NSError(domain: "KubeconfigEditor", code: 1011, userInfo: [NSLocalizedDescriptionKey: "Context не найден"])
        }

        let removed = contexts.remove(at: index)
        if currentContext == removed.name {
            currentContext = contexts.first?.name ?? ""
        }

        if cascade {
            let clusterName = removed.fieldValue("cluster").trimmingCharacters(in: .whitespacesAndNewlines)
            let userName = removed.fieldValue("user").trimmingCharacters(in: .whitespacesAndNewlines)

            if !clusterName.isEmpty && !contexts.contains(where: { $0.fieldValue("cluster") == clusterName }) {
                clusters.removeAll { $0.name == clusterName }
            }

            if !userName.isEmpty && !contexts.contains(where: { $0.fieldValue("user") == userName }) {
                users.removeAll { $0.name == userName }
            }

            statusMessage = "Context удален каскадно: \(removed.name)"
        } else {
            statusMessage = "Context удален: \(removed.name)"
        }

        selection = contexts.first.map { .context($0.id) }
        triggerBackgroundValidationIfNeeded()
    }

    public func setBackgroundValidation(_ enabled: Bool) {
        backgroundValidationEnabled = enabled
        if enabled {
            validateCurrentYaml()
        } else {
            validationMessage = "YAML validation: off"
        }
    }

    public func registerEdit(reason: String = "ui-edit") {
        guard !suppressHistoryTracking else { return }
        guard let currentYAML = try? buildWorkspaceYAML() else { return }
        guard currentYAML != lastSnapshotYAML else { return }

        let snapshot = HistorySnapshot(yaml: currentYAML, reason: reason, createdAt: Date())
        undoStack.append(snapshot)
        redoStack.removeAll()
        lastSnapshotYAML = currentYAML
        hasUnsavedChanges = true
        updateUndoRedoFlags()
        writeChangeLogEntry(from: undoStack.dropLast().last?.yaml, to: currentYAML, reason: reason)
        try? createDraftFile(fromYAML: currentYAML)
    }

    public func undoLastChange() {
        guard undoStack.count >= 2 else { return }
        let current = undoStack.removeLast()
        redoStack.append(current)
        if let previous = undoStack.last {
            applySnapshot(previous, reason: "undo")
            lastSnapshotYAML = previous.yaml
        }
        updateUndoRedoFlags()
    }

    public func redoLastChange() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(snapshot)
        applySnapshot(snapshot, reason: "redo")
        lastSnapshotYAML = snapshot.yaml
        updateUndoRedoFlags()
    }

    public func rollbackToPreviousSavedVersion() throws {
        let versions = try listSavedVersions()
        guard let latest = versions.dropFirst().first ?? versions.first else {
            throw NSError(domain: "KubeconfigEditor", code: 1013, userInfo: [NSLocalizedDescriptionKey: "Нет сохраненных версий для отката"])
        }
        try rollbackToVersion(latest)
        statusMessage = "Откат к версии: \(latest.displayName)"
    }

    public func listSavedVersions() throws -> [SavedVersion] {
        try Self.collectSavedVersions(from: gitRepositoryCandidates())
    }

    public func listSavedVersionsAsync() async throws -> [SavedVersion] {
        let candidates = gitRepositoryCandidates()
        return try await Task.detached(priority: .userInitiated) {
            try Self.collectSavedVersions(from: candidates)
        }.value
    }

    private nonisolated static func collectSavedVersions(from repositoryDirectories: [URL]) throws -> [SavedVersion] {
        var versions: [SavedVersion] = []
        var seenCommitIDs = Set<String>()
        let maxVersionsPerRepository = 300
        let maxVersionsTotal = 1000

        for repoDir in repositoryDirectories {
            guard FileManager.default.fileExists(atPath: repoDir.path) else { continue }
            guard let repository = try? Repository(at: repoDir, createIfNotExists: false) else { continue }
            guard !repository.isHEADUnborn else { continue }
            guard let commits = try? repository.log(sorting: [.time]) else { continue }

            var localCount = 0
            for commit in commits {
                let commitID = commit.id.hex
                guard seenCommitIDs.insert(commitID).inserted else { continue }
                versions.append(
                    SavedVersion(
                        id: commitID,
                        fileURL: repositoryWorkingFileURL(in: repoDir),
                        createdAt: commit.date,
                        displayName: "\(commit.id.abbreviated)  \(commit.summary)"
                    )
                )
                localCount += 1
                if localCount >= maxVersionsPerRepository || versions.count >= maxVersionsTotal {
                    break
                }
            }
            if versions.count >= maxVersionsTotal {
                break
            }
        }

        return versions.sorted(by: { $0.createdAt > $1.createdAt })
    }

    private nonisolated static func repositoryWorkingFileURL(in repoDir: URL) -> URL {
        if let filename = try? FileManager.default.contentsOfDirectory(atPath: repoDir.path)
            .first(where: { $0.hasSuffix(".kce.yaml") }) {
            return repoDir.appendingPathComponent(filename)
        }
        return repoDir.appendingPathComponent("kubeconfig.yaml")
    }

    public func rollbackToVersion(_ version: SavedVersion) throws {
        let oid = try OID(hex: version.id)
        var foundYAML: String?

        for repoDir in gitRepositoryCandidates() {
            guard let repository = try? Repository(at: repoDir, createIfNotExists: false) else { continue }
            if let commit: Commit = try? repository.show(id: oid),
               let yaml = try? yamlFromCommit(commit, in: repository) {
                foundYAML = yaml
                break
            }
        }

        guard let yaml = foundYAML else {
            throw NSError(domain: "KubeconfigEditor", code: 1014, userInfo: [NSLocalizedDescriptionKey: "Версия не найдена в истории этого kubeconfig"])
        }
        try loadFromYAML(yaml, sourceURL: currentPath)
        try createDraftFile(fromYAML: yaml)
        try? syncGitWorkingTree(yaml: yaml)
        resetHistory(reason: "rollback-\(version.id)")
        hasUnsavedChanges = true
        statusMessage = "Откат к версии: \(version.displayName)"
    }

    public func validateCurrentYaml() {
        do {
            var output = rootExtras
            output["current-context"] = currentContext
            output["contexts"] = encodeNamedItems(items: contexts, nestedKey: "context")
            output["clusters"] = encodeNamedItems(items: clusters, nestedKey: "cluster")
            output["users"] = encodeNamedItems(items: users, nestedKey: "user")
            if output["apiVersion"] == nil { output["apiVersion"] = "v1" }
            if output["kind"] == nil { output["kind"] = "Config" }

            let yaml = try Yams.dump(object: output)
            _ = try Yams.load(yaml: yaml)
            validationMessage = "YAML validation: OK"
        } catch {
            validationMessage = "YAML validation error: \(error.localizedDescription)"
        }
    }

    public func contextWarning(_ context: NamedItem) -> String? {
        let clusterName = context.fieldValue("cluster").trimmingCharacters(in: .whitespacesAndNewlines)
        let userName = context.fieldValue("user").trimmingCharacters(in: .whitespacesAndNewlines)

        if clusterName.isEmpty {
            return "Нет cluster"
        }
        if userName.isEmpty {
            return "Нет user"
        }
        if !clusters.contains(where: { $0.name == clusterName }) {
            return "Cluster '\(clusterName)' не найден"
        }
        if !users.contains(where: { $0.name == userName }) {
            return "User '\(userName)' не найден"
        }
        return nil
    }

    public func clusterWarning(_ cluster: NamedItem) -> String? {
        let refs = contexts.filter { $0.fieldValue("cluster") == cluster.name }
        if refs.isEmpty {
            return "Cluster не используется в contexts"
        }
        if cluster.fieldValue("server").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "У cluster пустой server"
        }
        if refs.contains(where: {
            let userName = $0.fieldValue("user").trimmingCharacters(in: .whitespacesAndNewlines)
            return userName.isEmpty || !users.contains(where: { $0.name == userName })
        }) {
            return "Есть context с этим cluster, но без валидного user"
        }
        return nil
    }

    public func userWarning(_ user: NamedItem) -> String? {
        let refs = contexts.filter { $0.fieldValue("user") == user.name }
        if refs.isEmpty {
            return "User не используется в contexts"
        }
        if refs.contains(where: {
            let clusterName = $0.fieldValue("cluster").trimmingCharacters(in: .whitespacesAndNewlines)
            return clusterName.isEmpty || !clusters.contains(where: { $0.name == clusterName })
        }) {
            return "Есть context с этим user, но без валидного cluster"
        }

        let hasAuth =
            !user.fieldValue("token").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !user.fieldValue("client-certificate-data").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !user.fieldValue("client-key-data").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !user.fieldValue("client-certificate").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !user.fieldValue("client-key").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !user.fieldValue("exec").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !user.fieldValue("auth-provider").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !user.fieldValue("username").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if !hasAuth {
            return "У user нет auth полей"
        }
        return nil
    }

    private func parseNamedItems(array: Any?, nestedKey: String) -> [NamedItem] {
        guard let raw = array as? [[String: Any]] else { return [] }

        return raw.map { item in
            let name = item["name"] as? String ?? ""
            let fields = dictionaryToFields(item[nestedKey] as? [String: Any] ?? [:])
            return NamedItem(name: name, fields: fields, includeInExport: true)
        }
    }

    private func buildCurrentObject() -> [String: Any] {
        var output = rootExtras
        output["current-context"] = currentContext
        output["contexts"] = encodeNamedItems(items: contexts, nestedKey: "context")
        output["clusters"] = encodeNamedItems(items: clusters, nestedKey: "cluster")
        output["users"] = encodeNamedItems(items: users, nestedKey: "user")
        if output["apiVersion"] == nil { output["apiVersion"] = "v1" }
        if output["kind"] == nil { output["kind"] = "Config" }
        return output
    }

    private func buildCurrentYAML() throws -> String {
        try Yams.dump(object: buildCurrentObject())
    }

    private func buildWorkspaceYAML() throws -> String {
        let base = try buildCurrentYAML()
        return annotateWorkspaceYAML(base)
    }

    private func buildExportYAML(projection: ExportProjection) throws -> String {
        var output = rootExtras
        output["current-context"] = projection.currentContext
        output["contexts"] = encodeNamedItems(items: projection.contexts, nestedKey: "context")
        output["clusters"] = encodeNamedItems(items: projection.clusters, nestedKey: "cluster")
        output["users"] = encodeNamedItems(items: projection.users, nestedKey: "user")
        if output["apiVersion"] == nil { output["apiVersion"] = "v1" }
        if output["kind"] == nil { output["kind"] = "Config" }
        return try Yams.dump(object: output)
    }

    private func loadFromYAML(_ text: String, sourceURL: URL?) throws {
        let loaded = try Yams.load(yaml: text)
        guard let root = loaded as? [String: Any] else {
            throw NSError(domain: "KubeconfigEditor", code: 1001, userInfo: [NSLocalizedDescriptionKey: "Неверный формат kubeconfig: корень должен быть map"])
        }

        suppressHistoryTracking = true
        currentPath = sourceURL
        currentContext = root["current-context"] as? String ?? ""
        contexts = parseNamedItems(array: root["contexts"], nestedKey: "context")
        clusters = parseNamedItems(array: root["clusters"], nestedKey: "cluster")
        users = parseNamedItems(array: root["users"], nestedKey: "user")

        rootExtras = root
        rootExtras.removeValue(forKey: "contexts")
        rootExtras.removeValue(forKey: "clusters")
        rootExtras.removeValue(forKey: "users")
        rootExtras.removeValue(forKey: "current-context")
        applyWorkspaceExportFlags(from: text)

        if let first = contexts.first {
            selection = .context(first.id)
        } else if let first = clusters.first {
            selection = .cluster(first.id)
        } else if let first = users.first {
            selection = .user(first.id)
        } else {
            selection = nil
        }
        suppressHistoryTracking = false
    }

    private func workspaceFileURL(for kubeconfigURL: URL) -> URL {
        let workspaceName = "\(sessionKey(for: kubeconfigURL)).kce.yaml"
        return appSupportDirectoryURL
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent(workspaceName)
    }

    private func legacyWorkspaceFileURL(for kubeconfigURL: URL) -> URL {
        let baseName = kubeconfigURL.lastPathComponent
        let workspaceName = ".\(baseName).kce.yaml"
        return kubeconfigURL.deletingLastPathComponent().appendingPathComponent(workspaceName)
    }

    private func writeWorkspaceFile(for kubeconfigURL: URL, contents: String? = nil) throws {
        let workspaceURL = workspaceFileURL(for: kubeconfigURL)
        let yaml = try contents ?? buildWorkspaceYAML()
        let dir = workspaceURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try yaml.write(to: workspaceURL, atomically: true, encoding: .utf8)
    }

    private func annotateWorkspaceYAML(_ yaml: String) -> String {
        enum Section: String {
            case contexts
            case clusters
            case users
        }

        let lines = yaml.components(separatedBy: .newlines)
        var result: [String] = []
        var section: Section?
        var contextIndex = 0
        var clusterIndex = 0
        var userIndex = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed == "contexts:" {
                section = .contexts
                result.append(line)
                continue
            }
            if trimmed == "clusters:" {
                section = .clusters
                result.append(line)
                continue
            }
            if trimmed == "users:" {
                section = .users
                result.append(line)
                continue
            }
            if section != nil, !trimmed.isEmpty, !trimmed.hasPrefix("-"), !trimmed.hasPrefix("#"), !line.hasPrefix(" ") {
                section = nil
            }

            if line.hasPrefix("- ") {
                switch section {
                case .contexts:
                    if contextIndex < contexts.count {
                        result.append("# kce:export=\(contexts[contextIndex].includeInExport ? "true" : "false")")
                    }
                    contextIndex += 1
                case .clusters:
                    if clusterIndex < clusters.count {
                        result.append("# kce:export=\(clusters[clusterIndex].includeInExport ? "true" : "false")")
                    }
                    clusterIndex += 1
                case .users:
                    if userIndex < users.count {
                        result.append("# kce:export=\(users[userIndex].includeInExport ? "true" : "false")")
                    }
                    userIndex += 1
                case .none:
                    break
                }
            }

            result.append(line)
        }

        return result.joined(separator: "\n")
    }

    private func applyWorkspaceExportFlags(from yaml: String) {
        let sections = parseWorkspaceExportSections(yaml)
        applyExportFlags(sections.contexts, to: &contexts)
        applyExportFlags(sections.clusters, to: &clusters)
        applyExportFlags(sections.users, to: &users)
    }

    private func applyExportFlags(_ flags: [Bool], to items: inout [NamedItem]) {
        guard !flags.isEmpty else { return }
        for index in items.indices where index < flags.count {
            items[index].includeInExport = flags[index]
        }
    }

    private func parseWorkspaceExportSections(_ yaml: String) -> (contexts: [Bool], clusters: [Bool], users: [Bool]) {
        enum Section: String {
            case contexts
            case clusters
            case users
        }

        let lines = yaml.components(separatedBy: .newlines)
        var section: Section?
        var pendingFlag: Bool?
        var contextFlags: [Bool] = []
        var clusterFlags: [Bool] = []
        var userFlags: [Bool] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed == "contexts:" {
                section = .contexts
                pendingFlag = nil
                continue
            }
            if trimmed == "clusters:" {
                section = .clusters
                pendingFlag = nil
                continue
            }
            if trimmed == "users:" {
                section = .users
                pendingFlag = nil
                continue
            }
            if section != nil, !trimmed.isEmpty, !trimmed.hasPrefix("-"), !trimmed.hasPrefix("#"), !line.hasPrefix(" ") {
                section = nil
                pendingFlag = nil
            }

            if trimmed.hasPrefix("# kce:export=") {
                let value = trimmed.replacingOccurrences(of: "# kce:export=", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                pendingFlag = (value == "true" || value == "1" || value == "yes" || value == "on")
                continue
            }

            guard line.hasPrefix("- ") else { continue }
            let flag = pendingFlag ?? true
            pendingFlag = nil

            switch section {
            case .contexts:
                contextFlags.append(flag)
            case .clusters:
                clusterFlags.append(flag)
            case .users:
                userFlags.append(flag)
            case .none:
                break
            }
        }

        return (contexts: contextFlags, clusters: clusterFlags, users: userFlags)
    }

    private func createDraftFile(fromYAML yaml: String) throws {
        let dir = appSupportDirectoryURL.appendingPathComponent("drafts")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let filename = "\(sessionIdentifier()).yaml"
        let draftURL = dir.appendingPathComponent(filename)
        try yaml.write(to: draftURL, atomically: true, encoding: .utf8)
        self.draftPath = draftURL
    }

    private func sessionIdentifier() -> String {
        currentSessionKey
    }

    private func sessionKey(for url: URL) -> String {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "file-\(hex.prefix(16))"
    }

    private func resetHistory(reason: String) {
        let yaml = (try? buildWorkspaceYAML()) ?? ""
        undoStack = [HistorySnapshot(yaml: yaml, reason: reason, createdAt: Date())]
        redoStack.removeAll()
        lastSnapshotYAML = yaml
        updateUndoRedoFlags()
        writeChangeLogEntry(from: nil, to: yaml, reason: reason)
    }

    private func applySnapshot(_ snapshot: HistorySnapshot, reason: String) {
        do {
            try loadFromYAML(snapshot.yaml, sourceURL: currentPath)
            hasUnsavedChanges = true
            statusMessage = reason == "undo" ? "Отмена шага" : "Повтор шага"
            try? createDraftFile(fromYAML: snapshot.yaml)
            writeChangeLogEntry(from: nil, to: snapshot.yaml, reason: reason)
        } catch {
            statusMessage = "Ошибка \(reason): \(error.localizedDescription)"
        }
    }

    private func updateUndoRedoFlags() {
        canUndo = undoStack.count > 1
        canRedo = !redoStack.isEmpty
    }

    private func gitRepositoryDirectory() -> URL {
        if let currentPath {
            return localGitRepositoryURL(for: currentPath)
        }
        return appSupportDirectoryURL
            .appendingPathComponent("git-repos")
            .appendingPathComponent(sessionIdentifier())
    }

    private func localGitRepositoryURL(for kubeconfigURL: URL) -> URL {
        let repoName = ".\(kubeconfigURL.lastPathComponent).kce-history.git"
        return kubeconfigURL.deletingLastPathComponent().appendingPathComponent(repoName, isDirectory: true)
    }

    private func gitRepositoryDirectory(for sessionKey: String) -> URL {
        appSupportDirectoryURL
            .appendingPathComponent("git-repos")
            .appendingPathComponent(sessionKey)
    }

    private func detachedStoreDirectoryURL() -> URL {
        appSupportDirectoryURL.appendingPathComponent("detached-store")
    }

    private func detachedStoreURL(for kubeconfigURL: URL) -> URL {
        let safeName = sessionKey(for: kubeconfigURL)
        return detachedStoreDirectoryURL().appendingPathComponent("\(safeName).yaml")
    }

    private func gitWorkingFileURL() -> URL {
        gitRepositoryDirectory().appendingPathComponent(gitTrackedWorkspaceFilename())
    }

    private func legacySessionKeys(for url: URL) -> [String] {
        let raw = url.path
        let standardized = url.standardizedFileURL.path
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath().path
        let candidates = [raw, standardized, canonical]
        var seen = Set<String>()
        return candidates.compactMap { path in
            let key = path.replacingOccurrences(of: "/", with: "_")
            guard !key.isEmpty else { return nil }
            guard seen.insert(key).inserted else { return nil }
            return key
        }
    }

    private func gitRepositoryCandidates() -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []

        func add(_ url: URL) {
            let key = url.standardizedFileURL.path
            guard seen.insert(key).inserted else { return }
            result.append(url)
        }

        add(gitRepositoryDirectory())
        if let currentPath {
            for legacyKey in legacySessionKeys(for: currentPath) {
                add(gitRepositoryDirectory(for: legacyKey))
            }
        }
        return result
    }

    private func openGitRepository(createIfNeeded: Bool) throws -> Repository {
        let repoDir = gitRepositoryDirectory()
        if createIfNeeded {
            try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
            let repository = try Repository(at: repoDir, createIfNotExists: true)
            if (try? repository.config.string(forKey: "user.name")) == nil {
                try? repository.config.set("user.name", to: "KubeconfigEditor")
            }
            if (try? repository.config.string(forKey: "user.email")) == nil {
                try? repository.config.set("user.email", to: "kubeconfig-editor@local")
            }
            return repository
        }
        return try Repository(at: repoDir, createIfNotExists: false)
    }

    private func syncGitWorkingTree(yaml: String) throws {
        let repository = try openGitRepository(createIfNeeded: true)
        let fileURL = try repository.workingDirectory.appendingPathComponent(gitTrackedWorkspaceFilename())
        try yaml.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func commitGitSnapshot(yaml: String, reason: String) throws {
        let repository = try openGitRepository(createIfNeeded: true)
        let trackedFile = gitTrackedWorkspaceFilename()
        let fileURL = try repository.workingDirectory.appendingPathComponent(trackedFile)
        try yaml.write(to: fileURL, atomically: true, encoding: .utf8)
        try repository.add(path: trackedFile)
        _ = try? repository.commit(message: "save: \(reason) at \(ISO8601DateFormatter().string(from: Date()))", options: .allowEmpty)
    }

    private func yamlFromCommit(_ commit: Commit, in repository: Repository) throws -> String {
        let tree = try commit.tree
        let trackedFile = gitTrackedWorkspaceFilename()
        guard let entry = tree.entries.first(where: { $0.name == trackedFile }) ?? tree.entries.first(where: { $0.name == "kubeconfig.yaml" }) else {
            throw NSError(domain: "KubeconfigEditor", code: 1014, userInfo: [NSLocalizedDescriptionKey: "В версии нет \(trackedFile)"])
        }
        let blob: Blob = try repository.show(id: entry.id)
        guard let text = String(data: blob.content, encoding: .utf8) else {
            throw NSError(domain: "KubeconfigEditor", code: 1015, userInfo: [NSLocalizedDescriptionKey: "Не удалось декодировать содержимое версии"])
        }
        return text
    }

    private func gitTrackedWorkspaceFilename() -> String {
        if let currentPath {
            return workspaceFileURL(for: currentPath).lastPathComponent
        }
        return ".kubeconfig.kce.yaml"
    }

    private func ensureInitialGitSnapshot(yaml: String, reason: String) throws {
        let repository = try openGitRepository(createIfNeeded: true)
        guard repository.isHEADUnborn else { return }
        try commitGitSnapshot(yaml: yaml, reason: reason)
    }

    private func tryLoadLatestWorkspaceSnapshot(for kubeconfigURL: URL, sessionKey: String) -> String? {
        let preferredFilename = workspaceFileURL(for: kubeconfigURL).lastPathComponent
        var candidates: [URL] = [localGitRepositoryURL(for: kubeconfigURL)]
        candidates.append(gitRepositoryDirectory(for: sessionKey))
        for legacyKey in legacySessionKeys(for: kubeconfigURL) {
            candidates.append(gitRepositoryDirectory(for: legacyKey))
        }

        var seen = Set<String>()
        for repoDir in candidates {
            let key = repoDir.standardizedFileURL.path
            guard seen.insert(key).inserted else { continue }
            guard let repository = try? Repository(at: repoDir, createIfNotExists: false) else { continue }
            guard !repository.isHEADUnborn else { continue }
            guard let commits = try? repository.log(sorting: [.time]) else { continue }
            guard let latestCommit = commits.first(where: { _ in true }) else { continue }
            if let text = try? workspaceYAMLFromCommit(latestCommit, in: repository, preferredFilename: preferredFilename) {
                return text
            }
        }
        return nil
    }

    private func workspaceYAMLFromCommit(_ commit: Commit, in repository: Repository, preferredFilename: String) throws -> String {
        let tree = try commit.tree
        guard let entry = tree.entries.first(where: { $0.name == preferredFilename })
                ?? tree.entries.first(where: { $0.name.hasSuffix(".kce.yaml") }) else {
            throw NSError(domain: "KubeconfigEditor", code: 1014, userInfo: [NSLocalizedDescriptionKey: "В версии нет workspace файла"])
        }
        let blob: Blob = try repository.show(id: entry.id)
        guard let text = String(data: blob.content, encoding: .utf8) else {
            throw NSError(domain: "KubeconfigEditor", code: 1015, userInfo: [NSLocalizedDescriptionKey: "Не удалось декодировать содержимое версии"])
        }
        return text
    }

    private func writeChangeLogEntry(from oldYAML: String?, to newYAML: String, reason: String) {
        let logsDir = appSupportDirectoryURL.appendingPathComponent("logs")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let logURL = logsDir.appendingPathComponent("\(sessionIdentifier()).changes.log")
        let oldLines = Set((oldYAML ?? "").components(separatedBy: .newlines))
        let newLines = Set(newYAML.components(separatedBy: .newlines))
        let added = newLines.subtracting(oldLines).prefix(30).map { "+ \($0)" }
        let removed = oldLines.subtracting(newLines).prefix(30).map { "- \($0)" }
        let header = "[\(ISO8601DateFormatter().string(from: Date()))] reason=\(reason)\n"
        let body = (Array(removed) + Array(added)).joined(separator: "\n")
        let chunk = header + body + "\n\n"
        if let data = chunk.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path),
               let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    private func encodeNamedItems(items: [NamedItem], nestedKey: String) -> [[String: Any]] {
        items.map { item in
            [
                "name": item.name,
                nestedKey: fieldsToDictionary(item.fields)
            ]
        }
    }

    private func dictionaryToFields(_ dict: [String: Any]) -> [KeyValueField] {
        dict.keys.sorted().map { key in
            KeyValueField(key: key, value: anyToString(dict[key]))
        }
    }

    private func fieldsToDictionary(_ fields: [KeyValueField]) -> [String: Any] {
        var output: [String: Any] = [:]
        for field in fields {
            let key = field.key.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty { continue }
            output[key] = stringToAny(field.value, key: key)
        }
        return output
    }

    private func anyToString(_ value: Any?) -> String {
        guard let value else { return "" }

        if let string = value as? String { return string }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }

        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }

        if let text = try? Yams.dump(object: value).trimmingCharacters(in: .whitespacesAndNewlines) {
            return text
        }

        return String(describing: value)
    }

    private func stringToAny(_ input: String, key: String) -> Any {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }

        let lowered = trimmed.lowercased()
        if lowered == "true" { return true }
        if lowered == "false" { return false }

        if Self.kubeBoolKeys.contains(key) {
            if ["1", "yes", "on"].contains(lowered) { return true }
            if ["0", "no", "off"].contains(lowered) { return false }
        }

        if let jsonData = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: jsonData),
           JSONSerialization.isValidJSONObject(json) {
            return normalizeKubeValueTypes(json, key: key)
        }

        return input
    }

    private func normalizeKubeValueTypes(_ value: Any, key: String? = nil) -> Any {
        if let key, Self.kubeBoolKeys.contains(key), let boolValue = coerceToBool(value) {
            return boolValue
        }

        if let dict = value as? [String: Any] {
            var normalized: [String: Any] = [:]
            for (nestedKey, nestedValue) in dict {
                normalized[nestedKey] = normalizeKubeValueTypes(nestedValue, key: nestedKey)
            }
            return normalized
        }

        if let array = value as? [Any] {
            return array.map { normalizeKubeValueTypes($0) }
        }

        return value
    }

    private func coerceToBool(_ value: Any) -> Bool? {
        if let boolValue = value as? Bool {
            return boolValue
        }

        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue
            }
            let numeric = number.doubleValue
            if numeric == 1 { return true }
            if numeric == 0 { return false }
            return nil
        }

        if let string = value as? String {
            let lowered = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "1", "yes", "on"].contains(lowered) { return true }
            if ["false", "0", "no", "off"].contains(lowered) { return false }
        }

        return nil
    }

    private static let kubeBoolKeys: Set<String> = [
        "provideClusterInfo",
        "insecure-skip-tls-verify",
        "disable-compression"
    ]

    private func uniqueName(base: String, in items: [NamedItem]) -> String {
        var index = 1
        var candidate = "\(base)-\(index)"
        let allNames = Set(items.map(\.name))

        while allNames.contains(candidate) {
            index += 1
            candidate = "\(base)-\(index)"
        }

        return candidate
    }

    private func parseKubeconfigText(_ text: String) throws -> (contexts: [NamedItem], clusters: [NamedItem], users: [NamedItem], currentContext: String, extras: [String: Any]) {
        let loaded = try Yams.load(yaml: text)
        guard let root = loaded as? [String: Any] else {
            throw NSError(domain: "KubeconfigEditor", code: 1001, userInfo: [NSLocalizedDescriptionKey: "Неверный формат kubeconfig: корень должен быть map"])
        }

        var extras = root
        extras.removeValue(forKey: "contexts")
        extras.removeValue(forKey: "clusters")
        extras.removeValue(forKey: "users")
        extras.removeValue(forKey: "current-context")

        return (
            contexts: parseNamedItems(array: root["contexts"], nestedKey: "context"),
            clusters: parseNamedItems(array: root["clusters"], nestedKey: "cluster"),
            users: parseNamedItems(array: root["users"], nestedKey: "user"),
            currentContext: root["current-context"] as? String ?? "",
            extras: extras
        )
    }

    private func replaceLocalhostServer(in clusters: [NamedItem], with replacementHost: String) -> [NamedItem] {
        let trimmedHost = replacementHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { return clusters }

        return clusters.map { cluster in
            var updated = cluster
            let server = updated.fieldValue("server")
            if server.contains("127.0.0.1") {
                updated.setField("server", value: server.replacingOccurrences(of: "127.0.0.1", with: trimmedHost))
            }
            return updated
        }
    }

    private func applyPrefix(prefix: String, to parsed: (contexts: [NamedItem], clusters: [NamedItem], users: [NamedItem], currentContext: String, extras: [String: Any])) -> (contexts: [NamedItem], clusters: [NamedItem], users: [NamedItem], currentContext: String, extras: [String: Any]) {
        let cleanPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPrefix.isEmpty else { return parsed }

        var clusters = parsed.clusters
        var clusterMap: [String: String] = [:]
        var usedClusterNames: Set<String> = []
        for index in clusters.indices {
            let oldName = clusters[index].name
            let candidate = "\(cleanPrefix)-\(oldName)"
            let newName = makeUniqueName(base: candidate, used: &usedClusterNames)
            clusters[index].name = newName
            clusterMap[oldName] = newName
        }

        var users = parsed.users
        var userMap: [String: String] = [:]
        var usedUserNames: Set<String> = []
        for index in users.indices {
            let oldName = users[index].name
            let candidate = "\(cleanPrefix)-\(oldName)"
            let newName = makeUniqueName(base: candidate, used: &usedUserNames)
            users[index].name = newName
            userMap[oldName] = newName
        }

        var contexts = parsed.contexts
        var contextMap: [String: String] = [:]
        var usedContextNames: Set<String> = []
        for index in contexts.indices {
            let oldName = contexts[index].name
            let candidate = "\(cleanPrefix)-\(oldName)"
            let newName = makeUniqueName(base: candidate, used: &usedContextNames)
            contexts[index].name = newName
            contextMap[oldName] = newName

            let clusterRef = contexts[index].fieldValue("cluster")
            if let mapped = clusterMap[clusterRef], !clusterRef.isEmpty {
                contexts[index].setField("cluster", value: mapped)
            }

            let userRef = contexts[index].fieldValue("user")
            if let mapped = userMap[userRef], !userRef.isEmpty {
                contexts[index].setField("user", value: mapped)
            }
        }

        let mappedCurrent = contextMap[parsed.currentContext] ?? parsed.currentContext
        return (contexts: contexts, clusters: clusters, users: users, currentContext: mappedCurrent, extras: parsed.extras)
    }

    private func makeUniqueName(base: String, used: inout Set<String>) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let initial = trimmed.isEmpty ? "item" : trimmed
        var candidate = initial
        var index = 1
        while used.contains(candidate) {
            candidate = "\(initial)-\(index)"
            index += 1
        }
        used.insert(candidate)
        return candidate
    }

    private func eksClusterName(fromArn arn: String) -> String? {
        let marker = "cluster/"
        guard let range = arn.range(of: marker) else { return nil }
        let name = String(arn[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private func projectedForExport() -> ExportProjection {
        let exportableClusterNames = Set(clusters.filter(\.includeInExport).map(\.name))
        let exportableUserNames = Set(users.filter(\.includeInExport).map(\.name))

        let exportContexts = contexts.filter { context in
            guard context.includeInExport else { return false }
            let cluster = context.fieldValue("cluster").trimmingCharacters(in: .whitespacesAndNewlines)
            let user = context.fieldValue("user").trimmingCharacters(in: .whitespacesAndNewlines)
            return !cluster.isEmpty && !user.isEmpty && exportableClusterNames.contains(cluster) && exportableUserNames.contains(user)
        }

        let usedClusterNames = Set(exportContexts.map { $0.fieldValue("cluster").trimmingCharacters(in: .whitespacesAndNewlines) })
        let usedUserNames = Set(exportContexts.map { $0.fieldValue("user").trimmingCharacters(in: .whitespacesAndNewlines) })

        let exportClusters = clusters.filter { $0.includeInExport && usedClusterNames.contains($0.name) }
        let exportUsers = users.filter { $0.includeInExport && usedUserNames.contains($0.name) }

        let exportCurrentContext: String
        if exportContexts.contains(where: { $0.name == currentContext }) {
            exportCurrentContext = currentContext
        } else {
            exportCurrentContext = exportContexts.first?.name ?? ""
        }

        return ExportProjection(
            contexts: exportContexts,
            clusters: exportClusters,
            users: exportUsers,
            currentContext: exportCurrentContext,
            droppedContexts: contexts.count - exportContexts.count,
            droppedClusters: clusters.count - exportClusters.count,
            droppedUsers: users.count - exportUsers.count
        )
    }

    private enum KubectlValidationResult {
        case ok
        case notInstalled
        case failed(String)
    }

    private func validateBeforeSave(_ yaml: String) throws -> String? {
        let loaded = try Yams.load(yaml: yaml)
        guard loaded is [String: Any] else {
            throw NSError(
                domain: "KubeconfigEditor",
                code: 1020,
                userInfo: [NSLocalizedDescriptionKey: "YAML lint failed: kubeconfig root must be a mapping/object"]
            )
        }

        guard kubectlValidationEnabled else { return nil }
        switch runKubectlValidation(yaml) {
        case .ok:
            return "YAML validation: OK + kubectl check: OK"
        case .notInstalled:
            return "YAML validation: OK (kubectl not installed)"
        case .failed(let stderr):
            throw NSError(
                domain: "KubeconfigEditor",
                code: 1021,
                userInfo: [NSLocalizedDescriptionKey: "kubectl validation failed: \(stderr)"]
            )
        }
    }

    private func runKubectlValidation(_ yaml: String) -> KubectlValidationResult {
        let manager = FileManager.default
        let tempURL = manager.temporaryDirectory.appendingPathComponent("kubeconfig-editor-validate-\(UUID().uuidString).yaml")
        do {
            try yaml.write(to: tempURL, atomically: true, encoding: .utf8)
        } catch {
            return .failed("cannot create temp file: \(error.localizedDescription)")
        }
        defer { try? manager.removeItem(at: tempURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["kubectl", "config", "view", "--kubeconfig", tempURL.path, "--raw"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .notInstalled
        }

        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        let stderrText = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown kubectl error"

        if process.terminationStatus == 0 {
            return .ok
        }

        if stderrText.contains("No such file") || stderrText.contains("not found") {
            return .notInstalled
        }
        return .failed(stderrText)
    }

    private func persistDetachedStore(for kubeconfigURL: URL) throws {
        let projection = projectedForExport()
        let exportedClusterNames = Set(projection.clusters.map(\.name))
        let exportedUserNames = Set(projection.users.map(\.name))
        let detachedClusters = clusters.filter { !exportedClusterNames.contains($0.name) }
        let detachedUsers = users.filter { !exportedUserNames.contains($0.name) }

        let storeURL = detachedStoreURL(for: kubeconfigURL)
        let manager = FileManager.default
        try manager.createDirectory(at: detachedStoreDirectoryURL(), withIntermediateDirectories: true)

        let exportedContextIDs = Set(projection.contexts.map(\.id))
        let detachedContexts = contexts.filter { !exportedContextIDs.contains($0.id) }

        if detachedClusters.isEmpty && detachedUsers.isEmpty && detachedContexts.isEmpty {
            if manager.fileExists(atPath: storeURL.path) {
                try manager.removeItem(at: storeURL)
            }
            return
        }

        let payload: [String: Any] = [
            "apiVersion": "v1",
            "kind": "DetachedStore",
            "contexts": encodeStoreItems(detachedContexts, nestedKey: "context"),
            "clusters": encodeStoreItems(detachedClusters, nestedKey: "cluster"),
            "users": encodeStoreItems(detachedUsers, nestedKey: "user")
        ]
        let yaml = try Yams.dump(object: payload)
        try yaml.write(to: storeURL, atomically: true, encoding: .utf8)
    }

    private func restoreDetachedStore(for kubeconfigURL: URL) throws {
        let storeURL = detachedStoreURL(for: kubeconfigURL)
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }

        let text = try String(contentsOf: storeURL, encoding: .utf8)
        let loaded = try Yams.load(yaml: text)
        guard let root = loaded as? [String: Any] else { return }

        let detachedContexts = parseStoreItems(array: root["contexts"], nestedKey: "context")
        let detachedClusters = parseStoreItems(array: root["clusters"], nestedKey: "cluster")
        let detachedUsers = parseStoreItems(array: root["users"], nestedKey: "user")

        var existingContextNames = Set(contexts.map(\.name))
        for item in detachedContexts {
            guard !existingContextNames.contains(item.name) else { continue }
            contexts.append(NamedItem(name: item.name, fields: item.fields, includeInExport: item.includeInExport))
            existingContextNames.insert(item.name)
        }

        var existingClusterNames = Set(clusters.map(\.name))
        for item in detachedClusters {
            guard !existingClusterNames.contains(item.name) else { continue }
            clusters.append(NamedItem(name: item.name, fields: item.fields, includeInExport: item.includeInExport))
            existingClusterNames.insert(item.name)
        }

        var existingUserNames = Set(users.map(\.name))
        for item in detachedUsers {
            guard !existingUserNames.contains(item.name) else { continue }
            users.append(NamedItem(name: item.name, fields: item.fields, includeInExport: item.includeInExport))
            existingUserNames.insert(item.name)
        }
    }

    private func encodeStoreItems(_ items: [NamedItem], nestedKey: String) -> [[String: Any]] {
        items.map { item in
            [
                "name": item.name,
                "export-enabled": item.includeInExport,
                nestedKey: fieldsToDictionary(item.fields)
            ]
        }
    }

    private func migrateSessionStorage(from oldKey: String, to newKey: String) {
        guard oldKey != newKey else { return }
        let manager = FileManager.default

        let oldGit = gitRepositoryDirectory(for: oldKey)
        let newGit = gitRepositoryDirectory(for: newKey)
        if manager.fileExists(atPath: oldGit.path), !manager.fileExists(atPath: newGit.path) {
            try? manager.createDirectory(at: newGit.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? manager.moveItem(at: oldGit, to: newGit)
        }

        let logsDir = appSupportDirectoryURL.appendingPathComponent("logs")
        let oldLog = logsDir.appendingPathComponent("\(oldKey).changes.log")
        let newLog = logsDir.appendingPathComponent("\(newKey).changes.log")
        if manager.fileExists(atPath: oldLog.path), !manager.fileExists(atPath: newLog.path) {
            try? manager.createDirectory(at: logsDir, withIntermediateDirectories: true)
            try? manager.moveItem(at: oldLog, to: newLog)
        }

        let draftsDir = appSupportDirectoryURL.appendingPathComponent("drafts")
        let oldDraft = draftsDir.appendingPathComponent("\(oldKey).yaml")
        let newDraft = draftsDir.appendingPathComponent("\(newKey).yaml")
        if manager.fileExists(atPath: oldDraft.path), !manager.fileExists(atPath: newDraft.path) {
            try? manager.createDirectory(at: draftsDir, withIntermediateDirectories: true)
            try? manager.moveItem(at: oldDraft, to: newDraft)
        }
    }

    private func parseStoreItems(array: Any?, nestedKey: String) -> [StoreItem] {
        guard let raw = array as? [[String: Any]] else { return [] }
        return raw.map { item in
            let name = item["name"] as? String ?? ""
            let fields = dictionaryToFields(item[nestedKey] as? [String: Any] ?? [:])
            let include = item["export-enabled"] as? Bool ?? true
            return StoreItem(name: name, fields: fields, includeInExport: include)
        }
    }

    private func triggerBackgroundValidationIfNeeded() {
        if backgroundValidationEnabled {
            validateCurrentYaml()
        }
    }

    private func appendFieldChanges(
        changes: inout [MergeFieldChange],
        entity: MergeEntityType,
        targetName: String,
        targetFields: [KeyValueField],
        sourceFields: [KeyValueField]
    ) {
        let targetMap = Dictionary(uniqueKeysWithValues: targetFields.map { ($0.key, $0.value) })
        for source in sourceFields {
            let oldValue = targetMap[source.key] ?? ""
            guard oldValue != source.value else { continue }
            let id = "\(entity.rawValue)|\(targetName)|\(source.key)"
            changes.append(
                MergeFieldChange(
                    id: id,
                    entity: entity,
                    targetName: targetName,
                    key: source.key,
                    oldValue: oldValue,
                    newValue: source.value
                )
            )
        }
    }
}
