//
//  AttributeContainerUtils.swift
//	LNSwiftUIUtils
//
//  Created by Léo Natan on 2023-10-21.
//  Copyright © 2023-2024 Léo Natan. All rights reserved.
//

import Foundation
import SwiftUI

@available(iOS 15, *)
public extension AttributeContainer {
	var swiftUIToUIKit: AttributeContainer {
		var rv = self
		if let font = rv.swiftUI.font, rv.uiKit.font == nil {
			rv.uiKit.font = font.uiFont
		}
		if let foregroundColor = rv.swiftUI.foregroundColor, rv.uiKit.foregroundColor == nil {
			rv.uiKit.foregroundColor = UIColor(foregroundColor)
		}
		if let backgroundColor = rv.swiftUI.backgroundColor, rv.uiKit.backgroundColor == nil {
			rv.uiKit.backgroundColor = UIColor(backgroundColor)
		}
		if let strikethroughStyle = rv.swiftUI.strikethroughStyle {
			let mirror = Mirror(reflecting: strikethroughStyle)
			let style = mirror.descendant("nsUnderlineStyle") as? NSUnderlineStyle
			let color = mirror.descendant("color") as? SwiftUI.Color
			rv.uiKit.strikethroughStyle = style
			if let color {
				rv.uiKit.strikethroughColor = UIColor(color)
			}
		}
		if let underlineStyle = rv.swiftUI.underlineStyle {
			let mirror = Mirror(reflecting: underlineStyle)
			let style = mirror.descendant("nsUnderlineStyle") as? NSUnderlineStyle
			let color = mirror.descendant("color") as? SwiftUI.Color
			
			rv.uiKit.underlineStyle = style
			if let color {
				rv.uiKit.underlineColor = UIColor(color)
			}
		}
		if let kern = rv.swiftUI.kern {
			rv.uiKit.kern = kern
		}
		if let tracking = rv.swiftUI.tracking {
			rv.uiKit.tracking = tracking
		}
		if let baselineOffset = rv.swiftUI.baselineOffset {
			rv.uiKit.baselineOffset = baselineOffset
		}
		
		return rv
	}
}

@available(iOS 15, *)
public extension AttributedString {
	var swiftUIToUIKit: AttributedString {
		var uikit = self
		
		runs.forEach { uikit[$0.range].setAttributes($0.attributes.swiftUIToUIKit) }
		
		return uikit
	}
}
