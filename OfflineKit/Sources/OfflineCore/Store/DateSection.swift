import Foundation

/// Groups notes by age for the note list: Today, Yesterday, Previous 7 Days,
/// Previous 30 Days, then by year.
public enum DateSection {
    public static func title(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        if days <= 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        if days <= 7 { return "Previous 7 Days" }
        if days <= 30 { return "Previous 30 Days" }
        return String(calendar.component(.year, from: date))
    }

    /// Splits already-sorted items into consecutive runs sharing a title.
    public static func group<Item>(
        _ items: [Item],
        title: (Item) -> String
    ) -> [(title: String, items: [Item])] {
        var result: [(title: String, items: [Item])] = []
        for item in items {
            let itemTitle = title(item)
            if let last = result.indices.last, result[last].title == itemTitle {
                result[last].items.append(item)
            } else {
                result.append((itemTitle, [item]))
            }
        }
        return result
    }
}
