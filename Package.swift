// swift-tools-version:6.3
// Laya decision plugin — native Swift. One fine-tuned Apple Core AI
// model (11 chains in one .aimodel) answering guardrail / triage /
// mail_sort / supervise / choose / compact / rerank locally, on the
// Neural Engine. Apache-2.0.
//
// Targets:
//   LayaCore    — pure Foundation: JSON, naming/aliases, constants,
//                 tokenizer, sequence building, wire ops, security
//                 validation, decision log, Core AI engine, use-case
//                 rails, remote-engine client, version + asset paths.
//   LayaGRPC    — generated protobuf/gRPC stubs (Protos/laya.proto).
//   LayaHTTP    — loopback HTTP/1.1 surface on Network.framework (no deps).
//   layad       — warm daemon: Engine + /health + /v1 question API + gRPC.
//   laya        — dual-named CLI (jev is the same binary via symlink):
//                 gRPC → HTTP backend, or --local Core AI inference in-process.
//   LayaMenuBar — macOS menu bar agent: status dot, live /health stats,
//                 launchd start/stop, settings editor; headless modes
//                 (--init-config / --render-plist / --status / --version).
import PackageDescription

let package = Package(
    name: "laya-plugin-swift",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift.git", exact: "1.27.6"),
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.5.0"),
    ],
    targets: [
        .target(name: "LayaCore"),
        .target(name: "LayaGRPC", dependencies: [
            .product(name: "GRPC", package: "grpc-swift"),
            .product(name: "SwiftProtobuf", package: "swift-protobuf"),
        ]),
        .target(name: "LayaHTTP", dependencies: ["LayaCore"]),
        .executableTarget(name: "layad", dependencies: [
            "LayaCore", "LayaHTTP", "LayaGRPC",
            .product(name: "GRPC", package: "grpc-swift"),
        ]),
        .executableTarget(name: "laya", dependencies: [
            "LayaCore", "LayaGRPC", "LayaHTTP",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
            .product(name: "GRPC", package: "grpc-swift"),
        ]),
        .executableTarget(name: "LayaMenuBar", dependencies: ["LayaCore"]),
    ]
)
