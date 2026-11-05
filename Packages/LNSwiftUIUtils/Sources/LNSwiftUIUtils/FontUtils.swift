//
//  FontUtils.swift
//  LNSwiftUIUtils
//
//  Created by Léo Natan on 2023-10-21.
//  Copyright © 2023-2024 Léo Natan. All rights reserved.
//

import SwiftUI
import UIKit

public extension EnvironmentValues {
	var uiFont: UIFont? {
		font?.uiFont(in: self)
	}
}

public extension SwiftUI.Font {
	func uiFont(in environment: EnvironmentValues) -> UIFont? {
#if compiler(>=6.2)
		if #available(iOS 26.0, *) {
			return uiFont(in: environment.fontResolutionContext)
		} else {
			return uiFont
		}
#else
		return uiFont
#endif
	}
	
	var uiFont: UIFont? {
		guard let base = Mirror(reflecting: self).descendant("provider", "base") else { return nil }
		return SwiftUI.Font.UIFontProvider(from: base)?.uiFont
	}
	
#if compiler(>=6.2)
	@available(iOS 26.0, *)
	func uiFont(in context: SwiftUI.Font.Context) -> UIFont? {
		return resolve(in: context).ctFont
	}
#endif
}

fileprivate extension UIFont {
	func with(weight: Weight? = nil, width: Width? = nil, symbolicTraits: CTFontSymbolicTraits = [], feature: [UIFontDescriptor.FeatureKey: Int]? = nil) -> UIFont {
		var mergedsymbolicTraits = CTFontGetSymbolicTraits(self)
		mergedsymbolicTraits.formUnion(symbolicTraits)
		
		let traits = NSMutableDictionary(dictionary: CTFontCopyTraits(self))
		if let weight {
			traits[kCTFontWeightTrait as String] = weight
		}
		if let width {
			traits[kCTFontWidthTrait as String] = width
		}
		traits[kCTFontSymbolicTrait as String] = mergedsymbolicTraits.rawValue
		
		var fontAttributes: [UIFontDescriptor.AttributeName: Any] = [:]
		fontAttributes[.family] = familyName
		fontAttributes[.traits] = traits
		
		if let feature {
			var mergedFeatureSettings = fontAttributes[.featureSettings] as? [[UIFontDescriptor.FeatureKey: Int]] ?? []
			mergedFeatureSettings.append(feature)
			fontAttributes[.featureSettings] = mergedFeatureSettings
		}
		
		let rv_ = UIFont(descriptor: UIFontDescriptor(fontAttributes: fontAttributes), size: pointSize)
		let rv: UIFont
		if symbolicTraits != [] {
			rv = CTFontCreateCopyWithSymbolicTraits(rv_, 0, nil, mergedsymbolicTraits, symbolicTraits) ?? rv_
		} else {
			rv = rv_
		}
		
//		print("Converted\n\t\(self)\nto\n\t\(rv)\n\n")
		
		return rv
	}
	
	func with(design: UIFontDescriptor.SystemDesign) -> UIFont? {
		guard let designedDescriptor = fontDescriptor.withDesign(design) else { return nil }
		return UIFont(descriptor: designedDescriptor, size: pointSize)
	}
	
	func with(featureType type: Int, selector: Int) -> UIFont? {
		return with(feature: [
			UIFontDescriptor.FeatureKey.featureIdentifier : type as Int,
			UIFontDescriptor.FeatureKey.typeIdentifier : selector as Int
		])
	}
	
	var bold: UIFont {
		return with(symbolicTraits: .traitBold)
	}
	
	var italic: UIFont {
		return with(symbolicTraits: .traitItalic)
	}
	
	var monospaced: UIFont {
		let weight: UIFont.Weight
		if let existingWeight = (CTFontCopyTraits(self) as NSDictionary)[kCTFontWeightTrait as String] as? CGFloat {
			weight = UIFont.Weight(rawValue: existingWeight)
		} else {
			weight = .regular
		}
		
		return with(design: .monospaced) ?? UIFont(name: "Menlo", size: pointSize)!.with(weight: weight)
	}
}

public extension UIFontDescriptor.SystemDesign {
	init?(_ design: SwiftUI.Font.Design) {
		switch design {
		case .default:
			self = .default
		case .serif:
			self = .serif
		case .rounded:
			self = .rounded
		case .monospaced:
			self = .monospaced
		@unknown default:
			self = .default
		}
	}
}

public extension UIFont.Weight {
	init?(_ weight: SwiftUI.Font.Weight) {
		guard let rawValue = Mirror(reflecting: weight).descendant("value") as? CGFloat else { return nil }
		self = UIFont.Weight(rawValue)
	}
}

public extension UIFont.TextStyle {
	init(_ textStyle: SwiftUI.Font.TextStyle) {
		switch textStyle {
		case .largeTitle:
			self = .largeTitle
		case .title:
			self = .title1
		case .headline:
			self = .headline
		case .subheadline:
			self = .subheadline
		case .body:
			self = .body
		case .callout:
			self = .callout
		case .footnote:
			self = .footnote
		case .caption:
			self = .caption1
		case .title2:
			self = .title2
		case .title3:
			self = .title3
		case .caption2:
			self = .caption2
		@unknown default:
			self = .body
		}
	}
}

fileprivate extension SwiftUI.Font {
	enum UIFontProvider {
		case system(size: CGFloat, weight: Font.Weight?, design: Font.Design?)
		case textStyle(Font.TextStyle, weight: Font.Weight?, design: Font.Design?)
		case platform(CTFont)
		case named(UIFont)
		
		var uiFont: UIFont? {
			switch self {
			case let .system(size, weight, design):
				let rv: UIFont
				if let weight, let fontWeight = UIFont.Weight(weight) {
					rv = UIFont.systemFont(ofSize: size, weight: fontWeight)
				} else {
					rv = UIFont.systemFont(ofSize: size)
				}
				if let design, let systemDesign = UIFontDescriptor.SystemDesign(design), let designedFont = rv.with(design: systemDesign) {
					return designedFont
				}
				return rv
			case let .textStyle(textStyle, _, _):
				return UIFont.preferredFont(forTextStyle: UIFont.TextStyle(textStyle))
			case let .platform(font):
				return font as UIFont
			case let .named(font):
				return font
			}
		}
		
		init?(from reflection: Any) {
			let desc = String(describing: type(of: reflection))
			let mirror = Mirror(reflecting: reflection)
			
			if let regex = try? NSRegularExpression(pattern: "ModifierProvider<(.*)>"), let match = regex.firstMatch(in: desc, range: NSRange(desc.startIndex..<desc.endIndex, in: desc)) {
				let modifier = desc[Range(match.range(at: 1), in: desc)!]
				
				guard let sFont = mirror.descendant("base") as? Font, var font = sFont.uiFont else { return nil }
				
//				print(modifier)
				
				switch modifier {
				case "BoldModifier":
					font = font.bold
					break
				case "ItalicModifier":
					font = font.italic
					break
				case "MonospacedModifier":
					font = font.monospaced
					break
				case "MonospacedDigitModifier":
					font = font.with(featureType: kNumberSpacingType, selector: kMonospacedNumbersSelector) ?? font
					break
				case "WeightModifier":
					if let weight = mirror.descendant("modifier", "weight", "value") as? CGFloat {
						font = font.with(weight: UIFont.Weight(rawValue: weight))
					}
					break
				case "WidthModifier":
					if let width = mirror.descendant("modifier", "width") as? CGFloat {
						font = font.with(width: UIFont.Width(rawValue: width))
					}
					break
				case "LeadingModifier":
					//Unsupported
					break
				case "FeatureSettingModifier":
					if let type = mirror.descendant("modifier", "type")as? Int, let selector = mirror.descendant("modifier", "selector") as? Int {
						font = font.with(featureType: type, selector: selector) ?? font
					}
					break
				default:
					break
				}
				
				self = .named(font)
				return
			}
			
			switch desc {
			case "SystemProvider":
				var props: (size: CGFloat?, weight: Font.Weight?, design: Font.Design?) = (nil, nil, nil)
				
				props.size = mirror.descendant("size") as? CGFloat
				props.weight = mirror.descendant("weight") as? Font.Weight
				props.design = mirror.descendant("design") as? Font.Design
				
				guard let size = props.size else { return nil }
				
				self = .system( size: size, weight: props.weight, design: props.design)
			case "TextStyleProvider":
				var props: (style: Font.TextStyle?, weight: Font.Weight?, design: Font.Design?) = (nil, nil, nil)
				
				props.style = mirror.descendant("style") as? Font.TextStyle
				props.weight = mirror.descendant("weight") as? Font.Weight
				props.design = mirror.descendant("design") as? Font.Design
				
				guard let style = props.style else { return nil }
				
				self = .textStyle(style, weight: props.weight, design: props.design)
			case "PlatformFontProvider":
				guard let font = mirror.descendant("font") as? UIFont else { return nil }
				self = .platform(font)
			case "NamedProvider":
				guard let name = mirror.descendant("name") as? String, let size = mirror.descendant("size") as? CGFloat else { return nil }
				
				let font = UIFont(name: name, size: size)
				guard var font else { return nil }
				
				if let textStyle = mirror.descendant("textStyle") as? SwiftUI.Font.TextStyle {
					font = UIFontMetrics(forTextStyle: UIFont.TextStyle(textStyle)).scaledFont(for: font)
				}
				
				self = .named(font)
				
			default:
				return nil
			}
		}
	}
}
