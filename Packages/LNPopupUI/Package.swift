// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "LNPopupUI",
	platforms: [
		.iOS(.v14),
		.macCatalyst(.v14)
	],
    products: [
        .library(
            name: "LNPopupUI",
			type: .dynamic,
            targets: ["LNPopupUI"]),
		.library(
			name: "LNPopupUI-Static",
			type: .static,
			targets: ["LNPopupUI"]),
    ],
    dependencies: [
		// Yuedu: the vendored copies beside this one (see VENDOR-MANIFEST.json).
		.package(path: "../LNPopupController"),
		.package(path: "../LNSwiftUIUtils")
    ],
    targets: [
        .target(
            name: "LNPopupUI",
			dependencies: [
				.product(name: "LNSwiftUIUtils", package: "LNSwiftUIUtils"),
				.product(name: "LNPopupController-Static", package: "LNPopupController")
			],
			swiftSettings: [
				.swiftLanguageMode(.v5)
			])
    ]
)
