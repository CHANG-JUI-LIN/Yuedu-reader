// swift-tools-version: 5.5

import PackageDescription

let package = Package(
    name: "LNSwiftUIUtils",
	platforms: [
		.iOS(.v14),
		.macCatalyst(.v14)
	],
    products: [
        .library(
            name: "LNSwiftUIUtils",
            targets: ["LNSwiftUIUtils"]),
    ],
    targets: [
        .target(
            name: "LNSwiftUIUtils"),
    ]
)
