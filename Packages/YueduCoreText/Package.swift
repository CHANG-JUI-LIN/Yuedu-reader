// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "YueduCoreText",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "YueduCoreTextTypography",
            targets: ["YueduCoreTextTypography"]
        ),
    ],
    targets: [
        .target(
            name: "YueduCoreTextTypography"
        ),
        .testTarget(
            name: "YueduCoreTextTypographyTests",
            dependencies: ["YueduCoreTextTypography"]
        ),
    ]
)
