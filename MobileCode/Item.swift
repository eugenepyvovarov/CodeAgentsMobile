//
//  Item.swift
//  MobileCode
//
//  Created by Eugene Pyvovarov on 2025-06-10.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
