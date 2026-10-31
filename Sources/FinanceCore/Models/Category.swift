import Foundation

/// Spending / income categories. Raw values are stable storage keys — never rename.
public enum Category: String, Codable, CaseIterable, Sendable, Hashable {
    // Expense categories
    case dining          // المطاعم والمقاهي
    case coffee          // القهوة
    case groceries       // البقالة والسوبرماركت
    case shopping        // التسوق والملابس
    case auto            // السيارات والبنزين
    case transport       // المواصلات
    case subscriptions   // الاشتراكات الشهرية
    case entertainment   // الترفيه والألعاب
    case travel          // السفر والفنادق
    case health          // الصحة والرياضة
    case bills           // الفواتير والخدمات
    case transfers       // التحويلات المالية (to third parties)
    case cash            // السحب النقدي / مصروف نقدي
    case personal        // المصروفات الشخصية
    case other           // أخرى
    // Income categories
    case salary          // الراتب
    case otherIncome     // دخل آخر
    // Non-economic
    case internalTransfer // تحويل داخلي بين حساباتي

    public static let expenseCategories: [Category] = [
        .dining, .coffee, .groceries, .shopping, .auto, .transport, .subscriptions,
        .entertainment, .travel, .health, .bills, .transfers, .cash, .personal, .other
    ]

    public var isExpense: Bool { Category.expenseCategories.contains(self) }

    public var arabicName: String {
        switch self {
        case .dining: return "المطاعم والمقاهي"
        case .coffee: return "القهوة"
        case .groceries: return "البقالة والسوبرماركت"
        case .shopping: return "التسوق والملابس"
        case .auto: return "السيارات والبنزين"
        case .transport: return "المواصلات"
        case .subscriptions: return "الاشتراكات"
        case .entertainment: return "الترفيه والألعاب"
        case .travel: return "السفر والفنادق"
        case .health: return "الصحة والرياضة"
        case .bills: return "الفواتير والخدمات"
        case .transfers: return "التحويلات المالية"
        case .cash: return "السحب النقدي"
        case .personal: return "المصروفات الشخصية"
        case .other: return "أخرى"
        case .salary: return "الراتب"
        case .otherIncome: return "دخل آخر"
        case .internalTransfer: return "تحويل داخلي"
        }
    }

    public var englishName: String {
        switch self {
        case .dining: return "Restaurants & Cafés"
        case .coffee: return "Coffee"
        case .groceries: return "Groceries"
        case .shopping: return "Shopping & Clothing"
        case .auto: return "Car & Fuel"
        case .transport: return "Transport"
        case .subscriptions: return "Subscriptions"
        case .entertainment: return "Entertainment & Games"
        case .travel: return "Travel & Hotels"
        case .health: return "Health & Fitness"
        case .bills: return "Bills & Utilities"
        case .transfers: return "Transfers"
        case .cash: return "Cash"
        case .personal: return "Personal"
        case .other: return "Other"
        case .salary: return "Salary"
        case .otherIncome: return "Other Income"
        case .internalTransfer: return "Internal Transfer"
        }
    }

    public func displayName(arabic: Bool) -> String { arabic ? arabicName : englishName }

    /// SF Symbol name for UI.
    public var symbol: String {
        switch self {
        case .dining: return "fork.knife"
        case .coffee: return "cup.and.saucer.fill"
        case .groceries: return "cart.fill"
        case .shopping: return "bag.fill"
        case .auto: return "fuelpump.fill"
        case .transport: return "car.fill"
        case .subscriptions: return "arrow.triangle.2.circlepath"
        case .entertainment: return "gamecontroller.fill"
        case .travel: return "airplane"
        case .health: return "heart.fill"
        case .bills: return "doc.text.fill"
        case .transfers: return "arrow.left.arrow.right"
        case .cash: return "banknote.fill"
        case .personal: return "person.fill"
        case .other: return "ellipsis.circle.fill"
        case .salary: return "briefcase.fill"
        case .otherIncome: return "plus.circle.fill"
        case .internalTransfer: return "arrow.triangle.swap"
        }
    }
}
