// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CLexbor",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
    ],
    products: [
        .library(name: "CLexbor", targets: ["CLexbor"]),
    ],
    targets: [
        .target(
            name: "CLexbor",
            path: "Sources/CLexbor",
            exclude: ["CLexborBridgeImplementation.inc"],
            sources: ["lexbor-amalgamated.generated.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath(".")]
        ),
        .testTarget(name: "CLexborTests", dependencies: ["CLexbor"]),
    ]
)
