//
//  Item.swift
//  LRC Extended Editor
//
//  Created by Frank Mögelin on 08.11.25.
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
