// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "kubeconfig-editor",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "KubeconfigEditorCore",
            targets: ["KubeconfigEditorCore"]
        ),
        .executable(
            name: "KubeconfigEditor",
            targets: ["KubeconfigEditor"]
        ),
        .executable(
            name: "KubeconfigEditorBehaviorTests",
            targets: ["KubeconfigEditorBehaviorTests"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.1"),
        .package(url: "https://github.com/ibrahimcetin/SwiftGitX.git", from: "0.4.0"),
        .package(url: "https://github.com/swiftlang/swift-testing.git", from: "0.9.0")
    ],
    targets: [
        .target(
            name: "KubeconfigEditorCore",
            dependencies: ["Yams", "SwiftGitX"],
            path: "Sources/KubeconfigEditorCore"
        ),
        .executableTarget(
            name: "KubeconfigEditor",
            dependencies: ["KubeconfigEditorCore"],
            path: "Sources/KubeconfigEditor"
        ),
        .executableTarget(
            name: "KubeconfigEditorBehaviorTests",
            dependencies: ["KubeconfigEditorCore"],
            path: "Tests/KubeconfigEditorBehaviorTests"
        ),
        .testTarget(
            name: "KubeconfigEditorTests",
            dependencies: [
                "KubeconfigEditor",
                "KubeconfigEditorCore",
                .product(name: "Testing", package: "swift-testing")
            ],
            path: "Tests/KubeconfigEditorTests"
        )
    ]
)
