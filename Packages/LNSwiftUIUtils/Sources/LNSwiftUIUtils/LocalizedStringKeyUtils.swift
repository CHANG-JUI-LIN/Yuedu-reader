//
//  LocalizedStringKey.swift
//  LNSwiftUIUtils
//
//  Created by Léo Natan on 2023-10-21.
//  Copyright © 2023-2024 Léo Natan. All rights reserved.
//

import SwiftUI

public extension LocalizedStringKey {
	var stringKey: String {
		return Mirror(reflecting: self).descendant("key") as! String
	}
}

