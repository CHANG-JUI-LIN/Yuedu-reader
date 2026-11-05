// swift-tools-version:5.9

import PackageDescription

let package = Package(
	name: "LNSystemMarqueeLabel",
	platforms: [
		.iOS(.v13),
		.macCatalyst(.v13)
	],
	products: [
		.library(
			name: "LNSystemMarqueeLabel",
			targets: ["LNSystemMarqueeLabel"])
	],
	dependencies: [],
	targets: [
		.target(
			name: "LNSystemMarqueeLabel",
			dependencies: [],
			exclude: [
			],
			publicHeadersPath: "."
		),
	],
	cxxLanguageStandard: .gnucxx20
)
