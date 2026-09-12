# Executed verification commands

Destination: `platform=iOS Simulator,id=9022EC10-D454-4270-AA9B-36D15CAD67C6`. Each command below comes from its actual xcodebuild log. Results are tracked separately in verification.json; a command here does not imply success.

## baseline-core-rerun

Log: `/tmp/yuedu-engine-extraction/baseline-core-rerun.log`

```sh
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader -destination "platform=iOS Simulator,id=9022EC10-D454-4270-AA9B-36D15CAD67C6" -parallel-testing-enabled NO "-only-testing:yuedu appTests/BrowserLayoutFixtureTests" "-only-testing:yuedu appTests/BrowserLayoutFloatLayoutTests" "-only-testing:yuedu appTests/BrowserLayoutRubyLayoutTests" "-only-testing:yuedu appTests/BrowserScrollDocumentTests" "-only-testing:yuedu appTests/BrowserLayoutSourceMappingTests" "-only-testing:yuedu appTests/BrowserLayoutSessionTests" -resultBundlePath /tmp/yuedu-engine-extraction/baseline-core-rerun.xcresult test-without-building
```

## baseline-extended

Log: `/tmp/yuedu-engine-extraction/baseline-extended.log`

```sh
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader -destination "platform=iOS Simulator,id=9022EC10-D454-4270-AA9B-36D15CAD67C6" -parallel-testing-enabled NO "-only-testing:yuedu appTests/BrowserLayoutProductionCorrectnessTests" "-only-testing:yuedu appTests/BrowserLayoutPerfTests" "-only-testing:yuedu appTests/BrowserLayoutRubySubsetTests" "-only-testing:yuedu appTests/BrowserLayoutRubyUnitTests" "-only-testing:yuedu appTests/BrowserLayoutRubyMeasurementTests" "-only-testing:yuedu appTests/BrowserLayoutRubyFragmentTests" "-only-testing:yuedu appTests/BrowserLayoutInlineDecorationTests" "-only-testing:yuedu appTests/BrowserLayoutCapabilityScannerTests" -resultBundlePath /tmp/yuedu-engine-extraction/baseline-extended.xcresult test-without-building
```

## baseline-package-core

Log: `/tmp/yuedu-engine-extraction/baseline-package-core.log`

```sh
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild -scheme YueduCoreText-Package -destination "platform=iOS Simulator,id=9022EC10-D454-4270-AA9B-36D15CAD67C6" -parallel-testing-enabled NO "-only-testing:YueduCoreTextTests" -resultBundlePath /tmp/yuedu-engine-extraction/baseline-package-core.xcresult test
```

## baseline-corpus

Log: `/tmp/yuedu-engine-extraction/baseline-corpus.log`

```sh
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader -destination "platform=iOS Simulator,id=9022EC10-D454-4270-AA9B-36D15CAD67C6" -parallel-testing-enabled NO "-only-testing:yuedu appTests/BrowserLayoutReportedTitlePageTests" "-only-testing:yuedu appTests/BrowserLayoutRedChamberRegressionTests/coverPageBoxGeometry" "-only-testing:yuedu appTests/BrowserLayoutRedChamberRegressionTests/firstLineGeometry" -resultBundlePath /tmp/yuedu-engine-extraction/baseline-corpus.xcresult test-without-building
```

## baseline-geometry

Log: `/tmp/yuedu-engine-extraction/baseline-geometry.log`

```sh
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader -destination "platform=iOS Simulator,id=9022EC10-D454-4270-AA9B-36D15CAD67C6" -parallel-testing-enabled NO "-only-testing:yuedu appTests/BrowserLayoutInlineFormattingContextParityTests" -resultBundlePath /tmp/yuedu-engine-extraction/baseline-geometry.xcresult test-without-building
```

## package-verified

Log: `/tmp/yuedu-engine-extraction/package-verified.log`

```sh
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild -scheme YueduCoreText-Package -destination "platform=iOS Simulator,id=9022EC10-D454-4270-AA9B-36D15CAD67C6" -parallel-testing-enabled NO -resultBundlePath /tmp/yuedu-engine-extraction/package-verified.xcresult test-without-building
```

## consumer-clean-render

Log: `/tmp/yuedu-engine-extraction/consumer-clean-render.log`

```sh
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild -scheme YueduCoreTextConsumer -destination "platform=iOS Simulator,id=9022EC10-D454-4270-AA9B-36D15CAD67C6" -parallel-testing-enabled NO -resultBundlePath /tmp/yuedu-engine-extraction/consumer-clean-render.xcresult test
```

## app-integration-build13

Log: `/tmp/yuedu-engine-extraction/app-integration-build13.log`

```sh
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild -workspace Yuedu-Engine.xcworkspace -scheme Yuedu-Reader -destination "platform=iOS Simulator,id=9022EC10-D454-4270-AA9B-36D15CAD67C6" -parallel-testing-enabled NO build-for-testing
```

## app-core-after

Log: `/tmp/yuedu-engine-extraction/app-core-after.log`

```sh
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild -workspace Yuedu-Engine.xcworkspace -scheme Yuedu-Reader -destination "platform=iOS Simulator,id=9022EC10-D454-4270-AA9B-36D15CAD67C6" -parallel-testing-enabled NO "-only-testing:yuedu appTests/BrowserLayoutFixtureTests" "-only-testing:yuedu appTests/BrowserLayoutFloatLayoutTests" "-only-testing:yuedu appTests/BrowserLayoutSourceMappingTests" "-only-testing:yuedu appTests/BrowserLayoutSessionTests" "-only-testing:yuedu appTests/BrowserScrollDocumentTests" "-only-testing:yuedu appTests/BrowserLayoutProductionCorrectnessTests" "-only-testing:yuedu appTests/BrowserLayoutPerfTests" "-only-testing:yuedu appTests/BrowserLayoutRubySubsetTests" "-only-testing:yuedu appTests/BrowserLayoutRubyUnitTests" "-only-testing:yuedu appTests/BrowserLayoutRubyMeasurementTests" "-only-testing:yuedu appTests/BrowserLayoutRubyFragmentTests" "-only-testing:yuedu appTests/BrowserLayoutInlineDecorationTests" "-only-testing:yuedu appTests/BrowserLayoutCapabilityScannerTests" "-only-testing:yuedu appTests/BrowserLayoutInlineFormattingContextParityTests" -resultBundlePath /tmp/yuedu-engine-extraction/app-core-after.xcresult test-without-building
```

## app-integration-tests

Log: `/tmp/yuedu-engine-extraction/app-integration-tests.log`

```sh
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild -workspace Yuedu-Engine.xcworkspace -scheme Yuedu-Reader -destination "platform=iOS Simulator,id=9022EC10-D454-4270-AA9B-36D15CAD67C6" -parallel-testing-enabled NO "-only-testing:yuedu appTests/BrowserLayoutPageEngineTests" "-only-testing:yuedu appTests/BrowserReaderParityTests" "-only-testing:yuedu appTests/BrowserReaderTypographyTests" "-only-testing:yuedu appTests/BrowserTextInteractionTests" "-only-testing:yuedu appTests/BrowserLayoutSelectionContractTests" "-only-testing:yuedu appTests/BrowserLayoutRubyInteractionTests" "-only-testing:yuedu appTests/BrowserMediaPronunciationParityTests" "-only-testing:yuedu appTests/BrowserLayoutTextIndentTests" "-only-testing:yuedu appTests/BrowserScrollTileCellTests" "-only-testing:yuedu appTests/EPUBAuthoredFontCascadeTests" "-only-testing:yuedu appTests/CoreTextWritingModeTests" "-only-testing:yuedu appTests/EPUBAutoRoutingTests" "-only-testing:yuedu appTests/YueduCoreTextMigrationTests" "-only-testing:yuedu appTests/ReaderPerfTraceTests" "-only-testing:yuedu appTests/ReaderOverlayContentTests" -resultBundlePath /tmp/yuedu-engine-extraction/app-integration-tests.xcresult test
```

## app-corpus-after

Log: `/tmp/yuedu-engine-extraction/app-corpus-after.log`

```sh
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild -workspace Yuedu-Engine.xcworkspace -scheme Yuedu-Reader -destination "platform=iOS Simulator,id=9022EC10-D454-4270-AA9B-36D15CAD67C6" -parallel-testing-enabled NO "-only-testing:yuedu appTests/BrowserLayoutReportedTitlePageTests" "-only-testing:yuedu appTests/EPUBReportedDefaultFontTests" -resultBundlePath /tmp/yuedu-engine-extraction/app-corpus-after.xcresult test-without-building
```

## baseline-repeated

Log: `/tmp/yuedu-engine-extraction/baseline-repeated.log`

```sh
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader -destination "platform=iOS Simulator,id=9022EC10-D454-4270-AA9B-36D15CAD67C6" -parallel-testing-enabled NO "-only-testing:yuedu appTests/BrowserLayoutReportedTitlePageTests" "-only-testing:yuedu appTests/BrowserLayoutPerfTests" -test-iterations 3 -test-repetition-relaunch-enabled YES -resultBundlePath /tmp/yuedu-engine-extraction/baseline-repeated.xcresult test-without-building
```

## app-repeated-after

Log: `/tmp/yuedu-engine-extraction/app-repeated-after.log`

```sh
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild -workspace Yuedu-Engine.xcworkspace -scheme Yuedu-Reader -destination "platform=iOS Simulator,id=9022EC10-D454-4270-AA9B-36D15CAD67C6" -parallel-testing-enabled NO "-only-testing:yuedu appTests/BrowserLayoutReportedTitlePageTests" "-only-testing:yuedu appTests/BrowserLayoutPerfTests" -test-iterations 3 -test-repetition-relaunch-enabled YES -resultBundlePath /tmp/yuedu-engine-extraction/app-repeated-after.xcresult test
```
