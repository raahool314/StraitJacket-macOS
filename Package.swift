// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StraitJacketMac",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // Shared models, paths, and the domain blocklist data structure.
        .target(
            name: "SJCore"
        ),
        // The root launchd daemon that enforces domain + app blocking.
        .executableTarget(
            name: "parentd",
            dependencies: ["SJCore"]
        ),
        // The admin-only CLI used by the parent to manage policy.
        .executableTarget(
            name: "parentctl",
            dependencies: ["SJCore"]
        ),
    ]
)
