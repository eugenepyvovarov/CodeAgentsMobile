//
//  DateFormatter+Smart.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-07-11.
//

import Foundation

extension DateFormatter {
    /// Smart date formatter that shows relative dates
    static let smartTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()
    
    /// Format a date with smart timestamp logic
    static func smartFormat(_ date: Date) -> String {
        let calendar = Calendar.current
        let now = Date()
        
        // Check if same day
        if calendar.isDateInToday(date) {
            // Just show time for today
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }
        
        // Check if yesterday
        if calendar.isDateInYesterday(date) {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            let time = formatter.string(from: date)
            return "Yesterday, \(time)"
        }
        
        // Check if same year
        let dateComponents = calendar.dateComponents([.year], from: date)
        let nowComponents = calendar.dateComponents([.year], from: now)
        
        if dateComponents.year == nowComponents.year {
            // Show month and day with time for this year
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d, h:mm a"
            return formatter.string(from: date)
        } else {
            // Show full date for previous years
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d, yyyy, h:mm a"
            return formatter.string(from: date)
        }
    }
}