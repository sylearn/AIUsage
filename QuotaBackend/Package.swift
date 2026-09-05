// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QuotaBackend",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "QuotaBackend", targets: ["QuotaBackend"]),
        .library(name: "QuotaServerCore", targets: ["QuotaServerCore"]),
        .executable(name: "QuotaServer", targets: ["QuotaServer"])
    ],
    targets: [
        .target(
            name: "QuotaBackend",
            path: "Sources/QuotaBackend",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "QuotaServerCore",
            dependencies: ["QuotaBackend"],
            path: "Sources/QuotaServer",
            exclude: ["main.swift"]
        ),
        .executableTarget(
            name: "QuotaServer",
            dependencies: ["QuotaBackend", "QuotaServerCore"],
            path: "Sources/QuotaServer",
            exclude: [
                "QuotaHTTPServer.swift",
                "QuotaHTTPServer+ClaudeProxy.swift",
                "QuotaHTTPServer+Admin.swift",
                "QuotaHTTPServer+CodexProxy.swift",
                "QuotaHTTPServer+CodexWebSocket.swift",
                "QuotaHTTPServer+OpenCodeProxy.swift",
                "QuotaHTTPServer+Passthrough.swift",
                "QuotaHTTPServer+TLS.swift",
                "QuotaWebSocket.swift",
                "ParentWatchdog.swift",
            ],
            sources: ["main.swift"]
        ),
        .testTarget(
            name: "QuotaBackendTests",
            dependencies: ["QuotaBackend", "QuotaServerCore"],
            path: "Tests/QuotaBackendTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
