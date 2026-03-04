import CryptoKit
import Foundation
import Testing
@testable import KubeconfigEditorCore

@Suite("KubeConfigViewModel behavior")
@MainActor
struct KubeConfigViewModelTests {

    @Test("newEmpty creates baseline draft model")
    func newEmptyCreatesUsableDraftModel() {
        let vm = KubeConfigViewModel()

        #expect(vm.contexts.count == 1)
        #expect(vm.clusters.count == 1)
        #expect(vm.users.count == 1)
        #expect(vm.contexts[0].fieldValue("cluster") == "new-cluster")
        #expect(vm.contexts[0].fieldValue("user") == "new-user")
        #expect(vm.currentContext == "new-context")
    }

    @Test("load/save roundtrip preserves structure")
    func loadSaveRoundTripPreservesStructure() throws {
        try withTempDir { tempDir in
            let source = try writeFixture(dir: tempDir, named: "source.yaml", content: fixtureYAML)
            let target = tempDir.appendingPathComponent("saved.yaml")

            let vm = KubeConfigViewModel()
            try vm.load(from: source)
            try vm.save(to: target)

            let vm2 = KubeConfigViewModel()
            try vm2.load(from: target)

            #expect(vm2.contexts.map(\.name).sorted() == ["ctx-1", "ctx-2"])
            #expect(vm2.clusters.map(\.name).sorted() == ["cluster-a", "cluster-b"])
            #expect(vm2.users.map(\.name).sorted() == ["user-a", "user-b"])
            #expect(vm2.currentContext == "ctx-1")
        }
    }

    @Test("normalize import applies prefix and host replacement")
    func normalizeImportTextAppliesPrefixAndHostReplacement() throws {
        let vm = KubeConfigViewModel()
        let normalized = try vm.normalizeImportText(
            fixtureYAML,
            serverHostReplacement: "k8s.example.local",
            namePrefix: "dev"
        )

        #expect(normalized.contains("dev-cluster-a"))
        #expect(normalized.contains("dev-user-a"))
        #expect(normalized.contains("k8s.example.local"))
    }

    @Test("merge import renames conflicts and keeps references valid")
    func mergeImportTextRenamesConflictsAndKeepsReferencesConsistent() throws {
        try withTempDir { tempDir in
            let vm = KubeConfigViewModel()
            try vm.load(from: writeFixture(dir: tempDir, named: "base.yaml", content: fixtureYAML))

            let beforeContextCount = vm.contexts.count
            try vm.mergeImportText(fixtureYAML)

            #expect(vm.contexts.count == beforeContextCount + 2)
            #expect(vm.contexts.contains(where: { $0.name != "ctx-1" && $0.name.hasPrefix("ctx-1") }))

            for context in vm.contexts {
                let clusterRef = context.fieldValue("cluster")
                let userRef = context.fieldValue("user")
                #expect(vm.clusters.contains(where: { $0.name == clusterRef }))
                #expect(vm.users.contains(where: { $0.name == userRef }))
            }
        }
    }

    @Test("merge into project reuses equivalent cluster and user instead of duplicating")
    func mergeImportTextIntoProjectReusesEquivalentClusterAndUser() throws {
        try withTempDir { tempDir in
            let vm = KubeConfigViewModel()
            try vm.load(from: writeFixture(dir: tempDir, named: "base.yaml", content: fixtureYAML))

            let importYAML = """
            apiVersion: v1
            kind: Config
            current-context: ctx-sa
            clusters:
              - name: cluster-a-copy
                cluster:
                  server: https://127.0.0.1:6443
            users:
              - name: user-a-copy
                user:
                  token: token-a
            contexts:
              - name: ctx-sa
                context:
                  cluster: cluster-a-copy
                  user: user-a-copy
                  namespace: kube-system
            """

            let initialClusterCount = vm.clusters.count
            let initialUserCount = vm.users.count
            let initialContextCount = vm.contexts.count

            try vm.mergeImportTextIntoProject(importYAML)

            #expect(vm.clusters.count == initialClusterCount)
            #expect(vm.users.count == initialUserCount)
            #expect(vm.contexts.count == initialContextCount + 1)

            let imported = try #require(vm.contexts.first(where: { $0.name == "ctx-sa" }))
            #expect(imported.fieldValue("cluster") == "cluster-a")
            #expect(imported.fieldValue("user") == "user-a")
            #expect(imported.fieldValue("namespace") == "kube-system")
        }
    }

    @Test("unsaved changes resets when content returns to persisted baseline")
    func unsavedChangesResetsWhenContentReturnsToPersistedBaseline() throws {
        try withTempDir { tempDir in
            let vm = KubeConfigViewModel()
            let file = try writeFixture(dir: tempDir, named: "dirty.yaml", content: fixtureYAML)
            try vm.load(from: file)

            vm.addContext()
            vm.registerEdit(reason: "add-context")
            #expect(vm.hasUnsavedChanges)

            let addedContextID = try #require(vm.selectionContextID())
            try vm.deleteContext(addedContextID, cascade: false)
            vm.registerEdit(reason: "delete-context")

            #expect(!vm.hasUnsavedChanges)
        }
    }

    @Test("add and delete selected works for each entity type")
    func addAndDeleteSelectedByType() throws {
        try withTempDir { tempDir in
            let vm = KubeConfigViewModel()
            try vm.load(from: writeFixture(dir: tempDir, named: "base.yaml", content: fixtureYAML))

            vm.addContext()
            if case .context(let contextID) = vm.selection {
                vm.deleteSelected()
                #expect(!vm.contexts.contains(where: { $0.id == contextID }))
            } else {
                Issue.record("Expected context selection")
            }

            vm.addCluster()
            if case .cluster(let clusterID) = vm.selection {
                vm.deleteSelected()
                #expect(!vm.clusters.contains(where: { $0.id == clusterID }))
            } else {
                Issue.record("Expected cluster selection")
            }

            vm.addUser()
            if case .user(let userID) = vm.selection {
                vm.deleteSelected()
                #expect(!vm.users.contains(where: { $0.id == userID }))
            } else {
                Issue.record("Expected user selection")
            }
        }
    }

    @Test("delete contexts cascade removes orphan linked entities only")
    func deleteContextsCascadeRemovesOrphanLinkedEntitiesOnly() throws {
        try withTempDir { tempDir in
            let vm = KubeConfigViewModel()
            try vm.load(from: writeFixture(dir: tempDir, named: "cascade.yaml", content: cascadeFixtureYAML))

            let targetIDs = Set(vm.contexts.filter { $0.name == "ctx-only" }.map(\.id))
            vm.deleteContexts(ids: targetIDs, cascade: true)

            #expect(!vm.contexts.contains(where: { $0.name == "ctx-only" }))
            #expect(!vm.clusters.contains(where: { $0.name == "cluster-only" }))
            #expect(!vm.users.contains(where: { $0.name == "user-only" }))

            #expect(vm.clusters.contains(where: { $0.name == "cluster-shared" }))
            #expect(vm.users.contains(where: { $0.name == "user-shared" }))
        }
    }

    @Test("delete clusters cascade removes dependent contexts and orphan users")
    func deleteClustersCascadeRemovesDependentContextsAndOrphanUsers() throws {
        try withTempDir { tempDir in
            let vm = KubeConfigViewModel()
            try vm.load(from: writeFixture(dir: tempDir, named: "cascade.yaml", content: cascadeFixtureYAML))

            let ids = Set(vm.clusters.filter { $0.name == "cluster-only" }.map(\.id))
            vm.deleteClusters(ids: ids, cascade: true)

            #expect(!vm.clusters.contains(where: { $0.name == "cluster-only" }))
            #expect(!vm.contexts.contains(where: { $0.name == "ctx-only" }))
            #expect(!vm.users.contains(where: { $0.name == "user-only" }))
        }
    }

    @Test("delete users cascade removes dependent contexts and orphan clusters")
    func deleteUsersCascadeRemovesDependentContextsAndOrphanClusters() throws {
        try withTempDir { tempDir in
            let vm = KubeConfigViewModel()
            try vm.load(from: writeFixture(dir: tempDir, named: "cascade.yaml", content: cascadeFixtureYAML))

            let ids = Set(vm.users.filter { $0.name == "user-only" }.map(\.id))
            vm.deleteUsers(ids: ids, cascade: true)

            #expect(!vm.users.contains(where: { $0.name == "user-only" }))
            #expect(!vm.contexts.contains(where: { $0.name == "ctx-only" }))
            #expect(!vm.clusters.contains(where: { $0.name == "cluster-only" }))
        }
    }

    @Test("activate context and save updates current-context")
    func activateContextAndSaveWritesCurrentContextToTarget() throws {
        try withTempDir { tempDir in
            let vm = KubeConfigViewModel()
            let file = try writeFixture(dir: tempDir, named: "base.yaml", content: fixtureYAML)
            try vm.load(from: file)

            let ctx2 = try #require(vm.contexts.first(where: { $0.name == "ctx-2" }))
            try vm.activateContextAndSave(ctx2.id)

            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(text.contains("current-context: ctx-2"))
        }
    }

    @Test("watcher picks up external current-context switch")
    func watcherPicksUpExternalCurrentContextSwitch() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let vm = KubeConfigViewModel()
        let file = try writeFixture(dir: tempDir, named: "watch.yaml", content: fixtureYAML)
        try vm.load(from: file)
        #expect(vm.currentContext == "ctx-1")

        let switched = fixtureYAML.replacingOccurrences(of: "current-context: ctx-1", with: "current-context: ctx-2")
        try switched.write(to: file, atomically: true, encoding: .utf8)

        let switchedInModel = await waitUntil(timeout: 3.0) { vm.currentContext == "ctx-2" }
        #expect(switchedInModel)
        #expect(vm.hasUnsavedChanges == false)
    }

    @Test("watcher ignores unknown current-context from external edits")
    func watcherIgnoresUnknownCurrentContextFromExternalEdits() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let vm = KubeConfigViewModel()
        let file = try writeFixture(dir: tempDir, named: "watch-unknown.yaml", content: fixtureYAML)
        try vm.load(from: file)
        #expect(vm.currentContext == "ctx-1")

        let unknown = fixtureYAML.replacingOccurrences(of: "current-context: ctx-1", with: "current-context: ghost-context")
        try unknown.write(to: file, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(600))

        #expect(vm.currentContext == "ctx-1")
    }

    @Test("watcher survives file delete and recovers after recreate")
    func watcherSurvivesFileDeleteAndRecoversAfterRecreate() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let vm = KubeConfigViewModel()
        let file = try writeFixture(dir: tempDir, named: "watch-recreate.yaml", content: fixtureYAML)
        try vm.load(from: file)
        #expect(vm.currentContext == "ctx-1")

        try FileManager.default.removeItem(at: file)
        try await Task.sleep(for: .milliseconds(700))

        let switched = fixtureYAML.replacingOccurrences(of: "current-context: ctx-1", with: "current-context: ctx-2")
        try switched.write(to: file, atomically: true, encoding: .utf8)

        let switchedInModel = await waitUntil(timeout: 4.0) { vm.currentContext == "ctx-2" }
        #expect(switchedInModel)
    }

    @Test("rename cluster/user everywhere updates context refs")
    func renameClusterAndUserEverywhereUpdatesReferences() throws {
        try withTempDir { tempDir in
            let vm = KubeConfigViewModel()
            try vm.load(from: writeFixture(dir: tempDir, named: "base.yaml", content: fixtureYAML))

            try vm.renameClusterEverywhere(oldName: "cluster-a", newName: "cluster-a-new")
            try vm.renameUserEverywhere(oldName: "user-a", newName: "user-a-new")

            #expect(vm.contexts.contains(where: { $0.name == "ctx-1" && $0.fieldValue("cluster") == "cluster-a-new" }))
            #expect(vm.contexts.contains(where: { $0.name == "ctx-1" && $0.fieldValue("user") == "user-a-new" }))
        }
    }

    @Test("relation lookups return expected linked sets")
    func relationLookupsReturnExpectedLinkedSets() throws {
        try withTempDir { tempDir in
            let vm = KubeConfigViewModel()
            try vm.load(from: writeFixture(dir: tempDir, named: "base.yaml", content: fixtureYAML))

            #expect(vm.contextsLinkedToCluster("cluster-a").map(\.name) == ["ctx-1"])
            #expect(vm.usersLinkedToCluster("cluster-a").map(\.name) == ["user-a"])
            #expect(vm.contextsLinkedToUser("user-b").map(\.name) == ["ctx-2"])
            #expect(vm.clustersLinkedToUser("user-b").map(\.name) == ["cluster-b"])
        }
    }

    @Test("delete context cascade removes orphan refs")
    func deleteContextCascadeRemovesOrphans() throws {
        try withTempDir { tempDir in
            let vm = KubeConfigViewModel()
            try vm.load(from: writeFixture(dir: tempDir, named: "cascade.yaml", content: cascadeFixtureYAML))

            let context = try #require(vm.contexts.first(where: { $0.name == "ctx-only" }))
            try vm.deleteContext(context.id, cascade: true)

            #expect(!vm.contexts.contains(where: { $0.name == "ctx-only" }))
            #expect(!vm.clusters.contains(where: { $0.name == "cluster-only" }))
            #expect(!vm.users.contains(where: { $0.name == "user-only" }))
        }
    }

    @Test("validation and warnings signal invalid refs")
    func validationAndWarningSignals() throws {
        try withTempDir { tempDir in
            let vm = KubeConfigViewModel()
            try vm.load(from: writeFixture(dir: tempDir, named: "invalid.yaml", content: invalidRefsYAML))

            vm.setBackgroundValidation(true)
            #expect(vm.validationMessage.contains("OK"))

            let broken = try #require(vm.contexts.first)
            #expect(vm.contextWarning(broken) != nil)

            let orphanCluster = try #require(vm.clusters.first(where: { $0.name == "cluster-z" }))
            #expect(vm.clusterWarning(orphanCluster) != nil)

            let orphanUser = try #require(vm.users.first(where: { $0.name == "user-z" }))
            #expect(vm.userWarning(orphanUser) != nil)
        }
    }

    @Test("undo/redo applies step history")
    func undoRedoStepHistory() throws {
        try withTempDir { tempDir in
            let vm = KubeConfigViewModel()
            try vm.load(from: writeFixture(dir: tempDir, named: "base.yaml", content: fixtureYAML))

            let originalCount = vm.contexts.count
            vm.addContext()
            vm.registerEdit(reason: "add-context")

            #expect(vm.canUndo)
            vm.undoLastChange()
            #expect(vm.contexts.count == originalCount)

            #expect(vm.canRedo)
            vm.redoLastChange()
            #expect(vm.contexts.count == originalCount + 1)
        }
    }

    @Test("save creates git versions and rollback restores older version")
    func saveCreatesGitVersionsAndRollbackToSpecificVersion() throws {
        try withTempDir { tempDir in
            let vm = KubeConfigViewModel()
            let file = try writeFixture(dir: tempDir, named: "history.yaml", content: fixtureYAML)
            try vm.load(from: file)

            try vm.save(to: file)

            if let idx = vm.contexts.firstIndex(where: { $0.name == "ctx-1" }) {
                vm.contexts[idx].name = "ctx-1-renamed"
            }
            vm.registerEdit(reason: "rename-context")
            try vm.save(to: file)

            let versions = try vm.listSavedVersions()
            #expect(versions.count >= 2)

            let oldest = try #require(versions.last)
            try vm.rollbackToVersion(oldest)

            #expect(vm.contexts.contains(where: { $0.name == "ctx-1" }))
        }
    }

    @Test("save writes workspace sidecar with app metadata comments")
    func saveWritesWorkspaceSidecarWithMetadataComments() throws {
        try withTempDir { tempDir in
            let file = try writeFixture(dir: tempDir, named: "config.yaml", content: fixtureYAML)
            let vm = KubeConfigViewModel()
            try vm.load(from: file)

            let hiddenContext = try #require(vm.contexts.first(where: { $0.name == "ctx-2" }))
            vm.toggleContextExport(hiddenContext.id)
            try vm.save(to: file)

            let mainText = try String(contentsOf: file, encoding: .utf8)
            #expect(!mainText.contains("name: ctx-2"))

            let workspaceURL = workspaceURL(for: file)
            #expect(FileManager.default.fileExists(atPath: workspaceURL.path))

            let workspaceText = try String(contentsOf: workspaceURL, encoding: .utf8)
            #expect(workspaceText.contains("name: ctx-2"))
            #expect(workspaceText.contains("# kce:export=false"))
        }
    }

    @Test("load restores hidden state from workspace sidecar")
    func loadRestoresHiddenStateFromWorkspaceSidecar() throws {
        try withTempDir { tempDir in
            let file = try writeFixture(dir: tempDir, named: "config.yaml", content: fixtureYAML)
            let vm = KubeConfigViewModel()
            try vm.load(from: file)
            let hiddenContext = try #require(vm.contexts.first(where: { $0.name == "ctx-2" }))
            vm.toggleContextExport(hiddenContext.id)
            try vm.save(to: file)

            let vm2 = KubeConfigViewModel()
            try vm2.load(from: file)

            #expect(vm2.contexts.contains(where: { $0.name == "ctx-2" }))
            let restored = try #require(vm2.contexts.first(where: { $0.name == "ctx-2" }))
            #expect(restored.includeInExport == false)
        }
    }

    @Test("missing workspace sidecar is recreated from git history snapshot")
    func missingWorkspaceSidecarIsRecreatedFromGitHistorySnapshot() throws {
        try withTempDir { tempDir in
            let file = try writeFixture(dir: tempDir, named: "config.yaml", content: fixtureYAML)

            let vm = KubeConfigViewModel()
            try vm.load(from: file)
            let hiddenContext = try #require(vm.contexts.first(where: { $0.name == "ctx-2" }))
            vm.toggleContextExport(hiddenContext.id)
            try vm.save(to: file)

            let workspaceURL = workspaceURL(for: file)
            try FileManager.default.removeItem(at: workspaceURL)
            #expect(!FileManager.default.fileExists(atPath: workspaceURL.path))

            let vm2 = KubeConfigViewModel()
            try vm2.load(from: file)

            #expect(FileManager.default.fileExists(atPath: workspaceURL.path))
            let restored = try #require(vm2.contexts.first(where: { $0.name == "ctx-2" }))
            #expect(restored.includeInExport == false)

            let versions = try vm2.listSavedVersions()
            #expect(!versions.isEmpty)
        }
    }

    @Test("version normalization strips v-prefix")
    func versionNormalizationStripsVPrefix() {
        #expect(normalizedVersion("v1.2.3") == "1.2.3")
        #expect(normalizedVersion(" 1.2.3 ") == "1.2.3")
    }

    @Test("quick add AWS EKS builds exec env with AWS_PROFILE")
    func quickAddAwsEksBuildsExecEnvWithProfile() throws {
        let vm = KubeConfigViewModel()

        try vm.addAWSEKSContext(
            contextName: "mock-eks",
            clusterArn: "arn:aws:eks:eu-central-1:000000000000:cluster/mock-eks",
            endpoint: "https://example.eks.amazonaws.com",
            certificateAuthorityData: "LS0tTEST==",
            region: "eu-central-1",
            awsProfile: "mock-aws-profile"
        )

        let createdContext = try #require(vm.contexts.first(where: { $0.name.hasPrefix("mock-eks") }))
        let clusterRef = createdContext.fieldValue("cluster")
        let userRef = createdContext.fieldValue("user")
        #expect(!clusterRef.isEmpty)
        #expect(!userRef.isEmpty)

        let createdUser = try #require(vm.users.first(where: { $0.name == userRef }))
        let execPayload = createdUser.fieldValue("exec")
        #expect(execPayload.contains("AWS_PROFILE"))
        #expect(execPayload.contains("mock-aws-profile"))
        #expect(execPayload.contains("provideClusterInfo"))

        let createdCluster = try #require(vm.clusters.first(where: { $0.name == clusterRef }))
        #expect(createdCluster.fieldValue("server") == "https://example.eks.amazonaws.com")
        #expect(createdCluster.fieldValue("certificate-authority-data") == "LS0tTEST==")
    }

    @Test("configure OIDC exec keeps legacy auth fields until explicit migration")
    func configureOIDCExecKeepsLegacyAuthFieldsUntilExplicitMigration() throws {
        try withTempDir { tempDir in
            let vm = KubeConfigViewModel()
            try vm.load(from: writeFixture(dir: tempDir, named: "oidc.yaml", content: fixtureYAML))

            let initialUser = try #require(vm.users.first(where: { $0.name == "user-a" }))
            let userID = initialUser.id
            if let idx = vm.users.firstIndex(where: { $0.id == userID }) {
                vm.users[idx].setField("auth-provider", value: "{name: oidc}")
                vm.users[idx].setField("token", value: "legacy-token")
            }

            try vm.configureOIDCExec(
                userID: userID,
                issuerURL: "https://dex.example.com",
                clientID: "kubernetes",
                clientSecret: "secret-x",
                extraScopes: ["profile", "email", "groups"]
            )

            let user = try #require(vm.users.first(where: { $0.id == userID }))
            #expect(vm.userOIDCAuthMode(user) == .exec)
            #expect(vm.userHasOIDCExec(user))
            #expect(user.fieldValue("exec").contains("oidc-login"))
            #expect(!user.fieldValue("auth-provider").isEmpty)
            #expect(!user.fieldValue("token").isEmpty)
            #expect(vm.userNeedsLegacyMigration(user))
        }
    }

    @Test("explicit legacy OIDC migration clears old auth fields")
    func explicitLegacyOIDCMigrationClearsOldAuthFields() throws {
        try withTempDir { tempDir in
            let vm = KubeConfigViewModel()
            try vm.load(from: writeFixture(dir: tempDir, named: "oidc-migration.yaml", content: fixtureYAML))

            let initialUser = try #require(vm.users.first(where: { $0.name == "user-a" }))
            let userID = initialUser.id
            if let idx = vm.users.firstIndex(where: { $0.id == userID }) {
                vm.users[idx].setField("auth-provider", value: "{name: oidc}")
                vm.users[idx].setField("token", value: "legacy-token")
                vm.users[idx].setField("id-token", value: "id-token-x")
                vm.users[idx].setField("refresh-token", value: "refresh-token-x")
            }

            try vm.configureOIDCExec(
                userID: userID,
                issuerURL: "https://dex.example.com",
                clientID: "kubernetes",
                clientSecret: "",
                extraScopes: []
            )

            try vm.migrateLegacyOIDCFields(userID: userID)

            let user = try #require(vm.users.first(where: { $0.id == userID }))
            #expect(user.fieldValue("auth-provider").isEmpty)
            #expect(user.fieldValue("token").isEmpty)
            #expect(user.fieldValue("id-token").isEmpty)
            #expect(user.fieldValue("refresh-token").isEmpty)
            #expect(!vm.userNeedsLegacyMigration(user))
        }
    }

    @Test("build OIDC reauth command targets selected context and kubeconfig")
    func buildOIDCReauthCommandTargetsContextAndKubeconfig() throws {
        try withTempDir { tempDir in
            let vm = KubeConfigViewModel()
            let file = try writeFixture(dir: tempDir, named: "oidc-cmd.yaml", content: fixtureYAML)
            try vm.load(from: file)

            let userID = try #require(vm.users.first(where: { $0.name == "user-a" })?.id)
            try vm.configureOIDCExec(
                userID: userID,
                issuerURL: "https://dex.example.com",
                clientID: "kubernetes",
                clientSecret: "",
                extraScopes: []
            )

            let contextID = try #require(vm.contexts.first(where: { $0.name == "ctx-1" })?.id)
            let cmd = try vm.buildOIDCReauthCommand(contextID: contextID)

            #expect(cmd.first == "kubectl")
            #expect(cmd.contains("--context"))
            #expect(cmd.contains("ctx-1"))
            #expect(cmd.contains("--kubeconfig"))
            #expect(cmd.contains(file.path))
            #expect(cmd.suffix(2) == ["get", "--raw=/version"])
        }
    }

    @Test("generate serviceaccount kubeconfig builds token command and returns yaml")
    func generateServiceAccountKubeconfigBuildsCommandAndReturnsYAML() async throws {
        let capture = CommandCapture()
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let vm = KubeConfigViewModel(externalCommandRunner: { args in
            capture.append(args)
            return (exitCode: 0, stdout: "token-from-mock", stderr: "")
        })

        let file = try writeFixture(dir: tempDir, named: "sa.yaml", content: fixtureYAML)
        try vm.load(from: file)

        let contextID = try #require(vm.contexts.first(where: { $0.name == "ctx-2" })?.id)
        let yaml = try await vm.generateServiceAccountKubeconfig(
            contextID: contextID,
            serviceAccount: "azuredevops",
            namespace: "kube-system",
            duration: "8760h"
        )

        let args = try #require(capture.last())
        #expect(args.first == "kubectl")
        #expect(args.contains("--kubeconfig"))
        #expect(args.contains(file.path))
        #expect(args.contains("--context"))
        #expect(args.contains("ctx-2"))
        #expect(args.contains("create"))
        #expect(args.contains("token"))
        #expect(args.contains("azuredevops"))
        #expect(args.contains("-n"))
        #expect(args.contains("kube-system"))
        #expect(args.contains("--duration=8760h"))

        #expect(yaml.contains("current-context: ctx-2-azuredevops"))
        #expect(yaml.contains("name: sa-kube-system-azuredevops"))
        #expect(yaml.contains("token: token-from-mock"))
        #expect(yaml.contains("namespace: kube-system"))
        #expect(yaml.contains("server: https://10.0.0.2:6443"))
    }

    @Test("generate serviceaccount kubeconfig propagates kubectl errors")
    func generateServiceAccountKubeconfigPropagatesKubectlError() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let vm = KubeConfigViewModel(externalCommandRunner: { _ in
            (exitCode: 1, stdout: "", stderr: "forbidden: cannot create token")
        })

        let file = try writeFixture(dir: tempDir, named: "sa-fail.yaml", content: fixtureYAML)
        try vm.load(from: file)

        await #expect(throws: NSError.self) {
            _ = try await vm.generateServiceAccountKubeconfig(
                contextID: vm.contexts.first?.id,
                serviceAccount: "azuredevops",
                namespace: "kube-system",
                duration: "8760h"
            )
        }
    }

    @Test("serviceaccount token info is parsed only for renewable jwt token")
    func serviceAccountTokenInfoParsesOnlyRenewableJwtToken() {
        let vm = KubeConfigViewModel()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let token = makeServiceAccountJWT(namespace: "kube-system", serviceAccountName: "azuredevops", issuedAt: now, expiresAt: now.addingTimeInterval(3600))
        let user = NamedItem(name: "u", fields: [KeyValueField(key: "token", value: token)])

        let info = vm.serviceAccountTokenInfo(for: user)
        #expect(info?.namespace == "kube-system")
        #expect(info?.serviceAccountName == "azuredevops")
        #expect(info?.issuedAt == now)
        #expect(info?.expiresAt == now.addingTimeInterval(3600))

        let invalid = NamedItem(name: "x", fields: [KeyValueField(key: "token", value: "plain-token")])
        #expect(vm.serviceAccountTokenInfo(for: invalid) == nil)
    }

    @Test("reissue serviceaccount token updates user token and preserves ttl")
    func reissueServiceAccountTokenUpdatesUserTokenAndPreservesTTL() async throws {
        let capture = CommandCapture()
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let oldIssuedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let oldExpiresAt = oldIssuedAt.addingTimeInterval(3600)
        let oldToken = makeServiceAccountJWT(namespace: "kube-system", serviceAccountName: "azuredevops", issuedAt: oldIssuedAt, expiresAt: oldExpiresAt)

        let newIssuedAt = Date(timeIntervalSince1970: 1_700_010_000)
        let newExpiresAt = newIssuedAt.addingTimeInterval(3600)
        let newToken = makeServiceAccountJWT(namespace: "kube-system", serviceAccountName: "azuredevops", issuedAt: newIssuedAt, expiresAt: newExpiresAt)

        let vm = KubeConfigViewModel(externalCommandRunner: { args in
            capture.append(args)
            return (exitCode: 0, stdout: newToken, stderr: "")
        })

        let file = try writeFixture(dir: tempDir, named: "sa-reissue.yaml", content: fixtureYAML)
        try vm.load(from: file)

        let userID = try #require(vm.users.first(where: { $0.name == "user-a" })?.id)
        let contextID = try #require(vm.contexts.first(where: { $0.name == "ctx-1" })?.id)
        if let idx = vm.users.firstIndex(where: { $0.id == userID }) {
            vm.users[idx].setField("token", value: oldToken)
        }

        let info = try await vm.reissueServiceAccountToken(userID: userID, contextID: contextID)
        #expect(info.namespace == "kube-system")
        #expect(info.serviceAccountName == "azuredevops")
        #expect(info.expiresAt == newExpiresAt)

        let args = try #require(capture.last())
        #expect(args.first == "kubectl")
        #expect(args.contains("--context"))
        #expect(args.contains("ctx-1"))
        #expect(args.contains("create"))
        #expect(args.contains("token"))
        #expect(args.contains("azuredevops"))
        #expect(args.contains("-n"))
        #expect(args.contains("kube-system"))
        #expect(args.contains("--duration=3600s"))

        let updatedUser = try #require(vm.users.first(where: { $0.id == userID }))
        #expect(updatedUser.fieldValue("token") == newToken)
    }

    @Test("reissue serviceaccount token uses explicit duration when provided")
    func reissueServiceAccountTokenUsesExplicitDurationWhenProvided() async throws {
        let capture = CommandCapture()
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let issuedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let expiresAt = issuedAt.addingTimeInterval(7200)
        let token = makeServiceAccountJWT(namespace: "kube-system", serviceAccountName: "azuredevops", issuedAt: issuedAt, expiresAt: expiresAt)

        let vm = KubeConfigViewModel(externalCommandRunner: { args in
            capture.append(args)
            return (exitCode: 0, stdout: token, stderr: "")
        })

        let file = try writeFixture(dir: tempDir, named: "sa-reissue-explicit.yaml", content: fixtureYAML)
        try vm.load(from: file)

        let userID = try #require(vm.users.first(where: { $0.name == "user-a" })?.id)
        let contextID = try #require(vm.contexts.first(where: { $0.name == "ctx-1" })?.id)
        if let idx = vm.users.firstIndex(where: { $0.id == userID }) {
            vm.users[idx].setField("token", value: token)
        }

        _ = try await vm.reissueServiceAccountToken(
            userID: userID,
            contextID: contextID,
            duration: "24h"
        )

        let args = try #require(capture.last())
        #expect(args.contains("--duration=24h"))
    }

    @Test("dependency status checks command availability")
    func dependencyStatusChecksCommandAvailability() async {
        let vm = KubeConfigViewModel(externalCommandRunner: { args in
            if args.count >= 3, args[0] == "bash", args[1] == "-lc" {
                let script = args[2]
                if script.contains("command -v kubectl-view-serviceaccount-kubeconfig") { return (1, "", "") }
                if script.contains("command -v kubectl-oidc_login") { return (0, "/Users/test/.krew/bin/kubectl-oidc_login", "") }
                if script.contains("command -v kubectl-krew") { return (1, "", "") }
                if script.contains("command -v brew") { return (0, "/opt/homebrew/bin/brew", "") }
                if script.contains("command -v kubectl") { return (0, "/opt/homebrew/bin/kubectl", "") }
            }
            return (1, "", "unexpected")
        })

        let status = await vm.checkDependencyStatus()
        #expect(status.hasBrew)
        #expect(status.hasKubectl)
        #expect(!status.hasKrew)
        #expect(status.hasOIDCPlugin)
        #expect(!status.hasViewServiceAccountPlugin)
    }

    @Test("install kubectl dependency calls brew install")
    func installKubectlDependencyCallsBrewInstall() async throws {
        let capture = CommandCapture()
        let vm = KubeConfigViewModel(externalCommandRunner: { args in
            capture.append(args)
            if args.count >= 3, args[0] == "bash", args[1] == "-lc" {
                let script = args[2]
                if script.contains("command -v brew") { return (0, "/opt/homebrew/bin/brew", "") }
                if script == "brew install kubernetes-cli" { return (0, "installed", "") }
            }
            return (1, "", "unexpected")
        })

        try await vm.installKubectlDependency()
        let commands = capture.all()
        #expect(commands.contains(where: { $0.count >= 3 && $0[2] == "brew install kubernetes-cli" }))
    }

    @Test("project connection test uses selected context from in-memory project")
    func testConnectionWithCurrentProjectUsesSelectedContextFromInMemoryProject() async throws {
        let capture = CommandCapture()
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let vm = KubeConfigViewModel(externalCommandRunner: { args in
            capture.append(args)
            capture.captureKubeconfigSnapshot(from: args)
            return (exitCode: 0, stdout: "{\"gitVersion\":\"v1.31.0\"}", stderr: "")
        })

        let file = try writeFixture(dir: tempDir, named: "project-conn.yaml", content: fixtureYAML)
        try vm.load(from: file)

        let contextID = try #require(vm.contexts.first(where: { $0.name == "ctx-2" })?.id)
        if let idx = vm.contexts.firstIndex(where: { $0.id == contextID }) {
            vm.contexts[idx].name = "ctx-2-live"
        }

        let output = try await vm.testConnectionWithCurrentProject(contextID: contextID)
        #expect(output.contains("gitVersion"))

        let args = try #require(capture.last())
        #expect(args.first == "kubectl")
        #expect(args.contains("--kubeconfig"))
        #expect(args.contains("--context"))
        #expect(args.contains("ctx-2-live"))
        #expect(args.suffix(2) == ["get", "--raw=/version"])

        let snapshot = try #require(capture.lastKubeconfigSnapshot())
        #expect(snapshot.contains("name: ctx-2-live"))
    }

    @Test("generated kubeconfig connection test uses context from provided kubeconfig")
    func testConnectionWithGeneratedKubeconfigUsesProvidedContext() async throws {
        let capture = CommandCapture()
        let vm = KubeConfigViewModel(externalCommandRunner: { args in
            capture.append(args)
            capture.captureKubeconfigSnapshot(from: args)
            return (exitCode: 0, stdout: "{\"major\":\"1\"}", stderr: "")
        })

        let output = try await vm.testConnectionWithKubeconfigText(fixtureYAML)
        #expect(output.contains("major"))

        let args = try #require(capture.last())
        #expect(args.first == "kubectl")
        #expect(args.contains("--context"))
        #expect(args.contains("ctx-1"))

        let snapshot = try #require(capture.lastKubeconfigSnapshot())
        #expect(snapshot.contains("current-context: ctx-1"))
        #expect(snapshot.contains("name: ctx-1"))
    }

    @Test("version compare handles semantic parts")
    func versionComparisonHandlesSemanticParts() {
        #expect(isVersion("1.2.4", newerThan: "1.2.3"))
        #expect(isVersion("1.10.0", newerThan: "1.9.9"))
        #expect(!isVersion("1.2.3", newerThan: "1.2.3"))
        #expect(!isVersion("1.2.3", newerThan: "1.2.4"))
    }

    private func withTempDir(_ body: (URL) throws -> Void) throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kubeconfig-editor-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func waitUntil(timeout: TimeInterval, intervalMs: UInt64 = 50, condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(intervalMs))
        }
        return condition()
    }

    private func writeFixture(dir: URL, named name: String, content: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func workspaceURL(for kubeconfigURL: URL) -> URL {
        let canonical = kubeconfigURL.standardizedFileURL.resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let sessionKey = "file-\(hex.prefix(16))"

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("KubeconfigEditor")
            .appendingPathComponent("workspaces")
            .appendingPathComponent("\(sessionKey).kce.yaml")
    }
}

private let fixtureYAML = """
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

private let cascadeFixtureYAML = """
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

private let invalidRefsYAML = """
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

private func normalizedVersion(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.lowercased().hasPrefix("v") {
        return String(trimmed.dropFirst())
    }
    return trimmed
}

private func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
    let l = lhs.split(separator: ".").map { Int($0) ?? 0 }
    let r = rhs.split(separator: ".").map { Int($0) ?? 0 }
    let count = max(l.count, r.count)
    for i in 0..<count {
        let lv = i < l.count ? l[i] : 0
        let rv = i < r.count ? r[i] : 0
        if lv != rv { return lv > rv }
    }
    return false
}

private extension KubeConfigViewModel {
    func selectionContextID() -> UUID? {
        if case .context(let id) = selection {
            return id
        }
        return nil
    }
}

private func makeServiceAccountJWT(namespace: String, serviceAccountName: String, issuedAt: Date, expiresAt: Date) -> String {
    let header: [String: Any] = ["alg": "RS256", "typ": "JWT"]
    let payload: [String: Any] = [
        "iat": Int(issuedAt.timeIntervalSince1970),
        "exp": Int(expiresAt.timeIntervalSince1970),
        "kubernetes.io": [
            "namespace": namespace,
            "serviceaccount": [
                "name": serviceAccountName
            ]
        ]
    ]

    let headerData = try! JSONSerialization.data(withJSONObject: header)
    let payloadData = try! JSONSerialization.data(withJSONObject: payload)
    let headerEncoded = base64URLEncode(headerData)
    let payloadEncoded = base64URLEncode(payloadData)
    return "\(headerEncoded).\(payloadEncoded).signature"
}

private func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private final class CommandCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [[String]] = []
    private var kubeconfigSnapshots: [String] = []

    func append(_ command: [String]) {
        lock.lock()
        commands.append(command)
        lock.unlock()
    }

    func last() -> [String]? {
        lock.lock()
        defer { lock.unlock() }
        return commands.last
    }

    func all() -> [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return commands
    }

    func captureKubeconfigSnapshot(from command: [String]) {
        guard let idx = command.firstIndex(of: "--kubeconfig"), idx + 1 < command.count else { return }
        let path = command[idx + 1]
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        lock.lock()
        kubeconfigSnapshots.append(text)
        lock.unlock()
    }

    func lastKubeconfigSnapshot() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return kubeconfigSnapshots.last
    }
}
