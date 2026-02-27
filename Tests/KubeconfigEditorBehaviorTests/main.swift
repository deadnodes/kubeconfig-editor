import Foundation
import KubeconfigEditorCore
import CryptoKit

@MainActor
func main() async {
    let runner = BehaviorRunner()
    await runner.run()
}

@MainActor
final class BehaviorRunner {
    private var passed = 0
    private var failed = 0

    func run() async {
        await test("newEmpty baseline") {
            let vm = KubeConfigViewModel()
            try expect(vm.contexts.count == 1, "contexts count")
            try expect(vm.clusters.count == 1, "clusters count")
            try expect(vm.users.count == 1, "users count")
            try expect(vm.currentContext == "new-context", "current context")
        }

        await test("load/save roundtrip") {
            try withTempDir { dir in
                let source = try writeFixture(dir: dir, name: "source.yaml", content: Fixtures.fixtureYAML)
                let out = dir.appendingPathComponent("out.yaml")
                let vm = KubeConfigViewModel()
                try vm.load(from: source)
                try vm.save(to: out)

                let vm2 = KubeConfigViewModel()
                try vm2.load(from: out)
                try expect(vm2.contexts.map(\.name).sorted() == ["ctx-1", "ctx-2"], "contexts roundtrip")
            }
        }

        await test("normalize import") {
            let vm = KubeConfigViewModel()
            let normalized = try vm.normalizeImportText(Fixtures.fixtureYAML, serverHostReplacement: "k8s.local", namePrefix: "dev")
            try expect(normalized.contains("dev-cluster-a"), "prefix applied")
            try expect(normalized.contains("k8s.local"), "host replace")
        }

        await test("merge import keeps refs valid") {
            try withTempDir { dir in
                let vm = KubeConfigViewModel()
                try vm.load(from: writeFixture(dir: dir, name: "base.yaml", content: Fixtures.fixtureYAML))
                try vm.mergeImportText(Fixtures.fixtureYAML)
                for ctx in vm.contexts {
                    let c = ctx.fieldValue("cluster")
                    let u = ctx.fieldValue("user")
                    try expect(vm.clusters.contains(where: { $0.name == c }), "cluster ref exists")
                    try expect(vm.users.contains(where: { $0.name == u }), "user ref exists")
                }
            }
        }

        await test("add/delete selected") {
            try withTempDir { dir in
                let vm = KubeConfigViewModel()
                try vm.load(from: writeFixture(dir: dir, name: "base.yaml", content: Fixtures.fixtureYAML))
                vm.addContext()
                vm.deleteSelected()
                vm.addCluster()
                vm.deleteSelected()
                vm.addUser()
                vm.deleteSelected()
                try expect(!vm.contexts.isEmpty, "still has contexts")
            }
        }

        await test("cascade delete contexts") {
            try withTempDir { dir in
                let vm = KubeConfigViewModel()
                try vm.load(from: writeFixture(dir: dir, name: "cascade.yaml", content: Fixtures.cascadeYAML))
                let ids = Set(vm.contexts.filter { $0.name == "ctx-only" }.map(\.id))
                vm.deleteContexts(ids: ids, cascade: true)
                try expect(!vm.clusters.contains(where: { $0.name == "cluster-only" }), "orphan cluster removed")
                try expect(!vm.users.contains(where: { $0.name == "user-only" }), "orphan user removed")
            }
        }

        await test("rename everywhere") {
            try withTempDir { dir in
                let vm = KubeConfigViewModel()
                try vm.load(from: writeFixture(dir: dir, name: "base.yaml", content: Fixtures.fixtureYAML))
                try vm.renameClusterEverywhere(oldName: "cluster-a", newName: "cluster-a-new")
                try vm.renameUserEverywhere(oldName: "user-a", newName: "user-a-new")
                let ctx = try require(vm.contexts.first { $0.name == "ctx-1" }, "ctx-1 exists")
                try expect(ctx.fieldValue("cluster") == "cluster-a-new", "cluster ref renamed")
                try expect(ctx.fieldValue("user") == "user-a-new", "user ref renamed")
            }
        }

        await test("relations lookup") {
            try withTempDir { dir in
                let vm = KubeConfigViewModel()
                try vm.load(from: writeFixture(dir: dir, name: "base.yaml", content: Fixtures.fixtureYAML))
                try expect(vm.contextsLinkedToCluster("cluster-a").map(\.name) == ["ctx-1"], "contexts linked")
                try expect(vm.usersLinkedToCluster("cluster-a").map(\.name) == ["user-a"], "users linked")
            }
        }

        await test("warnings") {
            try withTempDir { dir in
                let vm = KubeConfigViewModel()
                try vm.load(from: writeFixture(dir: dir, name: "invalid.yaml", content: Fixtures.invalidYAML))
                let ctx = try require(vm.contexts.first, "ctx exists")
                try expect(vm.contextWarning(ctx) != nil, "context warning")
            }
        }

        await test("undo redo") {
            try withTempDir { dir in
                let vm = KubeConfigViewModel()
                try vm.load(from: writeFixture(dir: dir, name: "base.yaml", content: Fixtures.fixtureYAML))
                let original = vm.contexts.count
                vm.addContext()
                vm.registerEdit(reason: "add-context")
                vm.undoLastChange()
                try expect(vm.contexts.count == original, "undo restored")
                vm.redoLastChange()
                try expect(vm.contexts.count == original + 1, "redo restored")
            }
        }

        await test("git versions + rollback") {
            try withTempDir { dir in
                let file = try writeFixture(dir: dir, name: "history.yaml", content: Fixtures.fixtureYAML)
                let vm = KubeConfigViewModel()
                try vm.load(from: file)
                try vm.save(to: file)
                if let i = vm.contexts.firstIndex(where: { $0.name == "ctx-1" }) {
                    vm.contexts[i].name = "ctx-1-renamed"
                }
                vm.registerEdit(reason: "rename")
                try vm.save(to: file)

                let versions = try vm.listSavedVersions()
                try expect(versions.count >= 2, "at least two versions")
                let oldest = try require(versions.last, "oldest exists")
                try vm.rollbackToVersion(oldest)
                try expect(vm.contexts.contains(where: { $0.name == "ctx-1" }), "rollback restored old content")
            }
        }

        await test("context merge preview + selective apply") {
            try withTempDir { dir in
                let vm = KubeConfigViewModel()
                try vm.load(from: writeFixture(dir: dir, name: "base.yaml", content: Fixtures.fixtureYAML))
                let targetID = try require(vm.contexts.first(where: { $0.name == "ctx-1" })?.id, "target context exists")

                let preview = try vm.buildContextMergePreview(
                    importText: Fixtures.mergeIntoContextYAML,
                    intoContextID: targetID,
                    importedContextName: "imp-ctx"
                )

                let serverChange = try require(
                    preview.changes.first(where: { $0.entity == .cluster && $0.key == "server" }),
                    "cluster server change exists"
                )
                let tokenChange = try require(
                    preview.changes.first(where: { $0.entity == .user && $0.key == "token" }),
                    "user token change exists"
                )
                try expect(serverChange.newValue.contains("6444"), "expected new cluster server")
                try expect(tokenChange.newValue == "token-new", "expected new user token")

                try vm.applyContextMergePreview(
                    intoContextID: targetID,
                    preview: preview,
                    selectedChangeIDs: [serverChange.id]
                )

                let clusterName = try require(vm.contexts.first(where: { $0.id == targetID })?.fieldValue("cluster"), "cluster ref")
                let userName = try require(vm.contexts.first(where: { $0.id == targetID })?.fieldValue("user"), "user ref")
                let cluster = try require(vm.clusters.first(where: { $0.name == clusterName }), "cluster exists")
                let user = try require(vm.users.first(where: { $0.name == userName }), "user exists")

                try expect(cluster.fieldValue("server") == "https://10.10.10.10:6444", "selected cluster change applied")
                try expect(user.fieldValue("token") == "token-a", "non-selected user change not applied")
            }
        }

        await test("save exports only complete contexts with referenced clusters/users") {
            try withTempDir { dir in
                let vm = KubeConfigViewModel()
                vm.contexts = [
                    NamedItem(name: "ctx-valid", fields: [
                        KeyValueField(key: "cluster", value: "cluster-valid"),
                        KeyValueField(key: "user", value: "user-valid")
                    ]),
                    NamedItem(name: "ctx-broken", fields: [
                        KeyValueField(key: "cluster", value: "cluster-missing"),
                        KeyValueField(key: "user", value: "user-valid")
                    ])
                ]
                vm.clusters = [
                    NamedItem(name: "cluster-valid", fields: [KeyValueField(key: "server", value: "https://ok:6443")]),
                    NamedItem(name: "cluster-unused", fields: [KeyValueField(key: "server", value: "https://unused:6443")])
                ]
                vm.users = [
                    NamedItem(name: "user-valid", fields: [KeyValueField(key: "token", value: "x")]),
                    NamedItem(name: "user-unused", fields: [KeyValueField(key: "token", value: "y")])
                ]
                vm.currentContext = "ctx-broken"

                let out = dir.appendingPathComponent("filtered.yaml")
                try vm.save(to: out)
                let text = try String(contentsOf: out, encoding: .utf8)

                try expect(text.contains("ctx-valid"), "valid context exported")
                try expect(!text.contains("ctx-broken"), "broken context skipped")
                try expect(text.contains("cluster-valid"), "referenced cluster exported")
                try expect(!text.contains("cluster-unused"), "unused cluster skipped")
                try expect(text.contains("user-valid"), "referenced user exported")
                try expect(!text.contains("user-unused"), "unused user skipped")
            }
        }

        await test("hidden context is excluded from save but can be exported explicitly") {
            try withTempDir { dir in
                let vm = KubeConfigViewModel()
                try vm.load(from: writeFixture(dir: dir, name: "base.yaml", content: Fixtures.fixtureYAML))
                let hiddenID = try require(vm.contexts.first(where: { $0.name == "ctx-1" })?.id, "ctx-1 exists")
                vm.toggleContextExport(hiddenID)

                let saved = dir.appendingPathComponent("saved.yaml")
                try vm.save(to: saved)
                let savedText = try String(contentsOf: saved, encoding: .utf8)
                try expect(!savedText.contains("ctx-1"), "hidden context not in saved kubeconfig")

                let exported = dir.appendingPathComponent("exported.yaml")
                try vm.exportContexts(ids: [hiddenID], to: exported)
                let exportText = try String(contentsOf: exported, encoding: .utf8)
                try expect(exportText.contains("ctx-1"), "explicit export includes hidden context")
                try expect(exportText.contains("cluster-a"), "cluster included in explicit export")
                try expect(exportText.contains("user-a"), "user included in explicit export")
            }
        }

        await test("save normalizes exec.provideClusterInfo to bool") {
            try withTempDir { dir in
                let vm = KubeConfigViewModel()
                let src = try writeFixture(dir: dir, name: "aws-exec.yaml", content: Fixtures.awsExecNumericBoolYAML)
                let out = dir.appendingPathComponent("aws-exec-out.yaml")

                try vm.load(from: src)
                try vm.save(to: out)
                let text = try String(contentsOf: out, encoding: .utf8)

                try expect(text.contains("provideClusterInfo: false"), "numeric provideClusterInfo converted to bool false")
            }
        }

        await test("history is isolated between different kubeconfig files") {
            try withTempDir { dir in
                let fileA = try writeFixture(dir: dir, name: "a.yaml", content: Fixtures.fixtureYAML)
                let fileB = try writeFixture(dir: dir, name: "b.yaml", content: Fixtures.fixtureYAML.replacingOccurrences(of: "ctx-1", with: "ctx-b"))

                let vm = KubeConfigViewModel()
                try vm.load(from: fileA)
                try vm.save(to: fileA)
                if let i = vm.contexts.firstIndex(where: { $0.name == "ctx-1" }) {
                    vm.contexts[i].name = "ctx-1-a"
                }
                vm.registerEdit(reason: "rename-a")
                try vm.save(to: fileA)
                let aVersions = try vm.listSavedVersions()
                try expect(aVersions.count >= 2, "file A has multiple versions")

                try vm.load(from: fileB)
                try vm.save(to: fileB)
                let bVersions = try vm.listSavedVersions()
                try expect(!bVersions.isEmpty, "file B has history")
                try expect(!bVersions.contains(where: { $0.displayName.contains("rename-a") }), "file B history does not contain file A changes")
            }
        }

        await test("legacy local history repo is migrated to canonical store") {
            try withTempDir { dir in
                let file = try writeFixture(dir: dir, name: "legacy-history.yaml", content: Fixtures.fixtureYAML)
                let vm = KubeConfigViewModel()
                try vm.load(from: file)
                try vm.save(to: file)

                let repoRoot = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library")
                    .appendingPathComponent("Application Support")
                    .appendingPathComponent("KubeconfigEditor")
                    .appendingPathComponent("git-repos")

                let localRepo = localHistoryRepo(file)
                let canonicalRepo = repoRoot.appendingPathComponent(sessionKey(file))

                if FileManager.default.fileExists(atPath: localRepo.path) {
                    try? FileManager.default.removeItem(at: localRepo)
                }
                if FileManager.default.fileExists(atPath: canonicalRepo.path) {
                    try? FileManager.default.moveItem(at: canonicalRepo, to: localRepo)
                }
                try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)

                let vm2 = KubeConfigViewModel()
                try vm2.load(from: file)
                let versions = try vm2.listSavedVersions()
                try expect(!versions.isEmpty, "versions from migrated repo are visible")
                try expect(FileManager.default.fileExists(atPath: canonicalRepo.path), "canonical repo exists")
                try expect(!FileManager.default.fileExists(atPath: localRepo.path), "legacy local repo removed")
            }
        }

        print("\nBehavior tests: passed=\(passed), failed=\(failed)")
        if failed > 0 {
            exit(1)
        }
        exit(0)
    }

    private func test(_ name: String, _ body: () throws -> Void) async {
        do {
            try body()
            passed += 1
            print("[PASS] \(name)")
        } catch {
            failed += 1
            print("[FAIL] \(name): \(error)")
        }
    }
}

struct TestError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw TestError(message: message)
    }
}

func require<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else {
        throw TestError(message: message)
    }
    return value
}

func withTempDir(_ body: (URL) throws -> Void) throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("kubeconfig-editor-behavior-tests")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
}

func writeFixture(dir: URL, name: String, content: String) throws -> URL {
    let url = dir.appendingPathComponent(name)
    try content.write(to: url, atomically: true, encoding: .utf8)
    return url
}

private func sessionKey(_ url: URL) -> String {
    let canonical = url.standardizedFileURL.resolvingSymlinksInPath().path
    let digest = SHA256.hash(data: Data(canonical.utf8))
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    return "file-\(hex.prefix(16))"
}

private func localHistoryRepo(_ url: URL) -> URL {
    url.deletingLastPathComponent()
        .appendingPathComponent(".\(url.lastPathComponent).kce-history.git", isDirectory: true)
}

private enum Fixtures {
    static let fixtureYAML = """
apiVersion: v1
kind: Config
current-context: ctx-1
clusters:
  - name: cluster-a
    cluster:
      server: https://127.0.0.1:6443
  - name: cluster-b
    cluster:
      server: https://10.0.0.2:6443
users:
  - name: user-a
    user:
      token: token-a
  - name: user-b
    user:
      token: token-b
contexts:
  - name: ctx-1
    context:
      cluster: cluster-a
      user: user-a
  - name: ctx-2
    context:
      cluster: cluster-b
      user: user-b
"""

    static let cascadeYAML = """
apiVersion: v1
kind: Config
current-context: ctx-shared
clusters:
  - name: cluster-only
    cluster:
      server: https://cluster-only:6443
  - name: cluster-shared
    cluster:
      server: https://cluster-shared:6443
users:
  - name: user-only
    user:
      token: user-only-token
  - name: user-shared
    user:
      token: user-shared-token
contexts:
  - name: ctx-only
    context:
      cluster: cluster-only
      user: user-only
  - name: ctx-shared
    context:
      cluster: cluster-shared
      user: user-shared
"""

    static let invalidYAML = """
apiVersion: v1
kind: Config
current-context: ctx-z
clusters:
  - name: cluster-z
    cluster:
      server: ""
users:
  - name: user-z
    user: {}
contexts:
  - name: ctx-z
    context:
      cluster: missing-cluster
      user: missing-user
"""

    static let mergeIntoContextYAML = """
apiVersion: v1
kind: Config
current-context: imp-ctx
clusters:
  - name: imp-cluster
    cluster:
      server: https://10.10.10.10:6444
      certificate-authority-data: NEW_CA_DATA
users:
  - name: imp-user
    user:
      token: token-new
      client-certificate-data: NEW_CERT_DATA
contexts:
  - name: imp-ctx
    context:
      cluster: imp-cluster
      user: imp-user
      namespace: merged-ns
"""

static let awsExecNumericBoolYAML = """
apiVersion: v1
kind: Config
current-context: aws-ctx
clusters:
  - name: arn:aws:eks:eu-central-1:000000000000:cluster/mock-eks
    cluster:
      server: https://example.eks.amazonaws.com
      certificate-authority-data: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCg==
users:
  - name: arn:aws:eks:eu-central-1:000000000000:cluster/mock-eks
    user:
      exec:
        apiVersion: client.authentication.k8s.io/v1beta1
        command: aws
        args:
          - --region
          - eu-central-1
          - eks
          - get-token
          - --cluster-name
          - mock-eks
          - --output
          - json
        provideClusterInfo: 0
contexts:
  - name: aws-ctx
    context:
      cluster: arn:aws:eks:eu-central-1:000000000000:cluster/mock-eks
      user: arn:aws:eks:eu-central-1:000000000000:cluster/mock-eks
"""
}

Task { await main() }
RunLoop.main.run()
