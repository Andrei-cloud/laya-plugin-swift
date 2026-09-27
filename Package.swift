// swift-tools-version:6.2
// Laya decision plugin — native Swift port of laya-plugin (Python).
//
// Layering (mirrors the Python package):
//   LayaCore   — pure Foundation: JSON, naming/aliases, constants, tokenizer,
//                sequence building, wire ops, security validation, decision
//                log, Core AI engine, use-case rails, remote engine client.
//   LayaGRPC   — generated protobuf/gRPC stubs (Scripts/protogen.sh).
//   LayaHTTP   — loopback HTTP/1.1 surface on Network.framework (no deps).
//   layad      — warm daemon: Engine + /health + /v1 question API + gRPC.
//   laya       — dual-named CLI (jev is the same binary via symlink):
//                gRPC → HTTP backend, or --local Core AI inference in-process.
//   layacoreai-probe — dev probe: one Core AI pass, logits dumped for parity.
//   laya-tokenizer-compile — compiles tokenizer.json → tokenizer.bin (fast load).
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
            "LayaCore", "LayaGRPC",
            "LayaHTTP",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
            .product(name: "GRPC", package: "grpc-swift"),
        ]),
        .executableTarget(name: "layacoreai-probe", dependencies: ["LayaCore"]),
        .executableTarget(name: "laya-tokenizer-bench", dependencies: ["LayaCore"]),
        .executableTarget(name: "laya-tokenizer-compile", dependencies: ["LayaCore"]),
        .testTarget(name: "LayaCoreTests", dependencies: ["LayaCore"]),
        .testTarget(name: "LayaParityTests", dependencies: ["LayaCore", "LayaHTTP", "LayaGRPC"]),
    ]
)
