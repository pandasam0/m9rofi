import Foundation

public struct CategoryDecision: Sendable, Equatable {
    public var category: Category
    public var source: CategorySource
    public var confidence: Double
}

/// Optional external classifier (e.g. Apple Foundation Models on-device LLM). Only consulted when
/// deterministic layers fail. Must not invent amounts — only returns a category.
public protocol CategoryClassifier: Sendable {
    func classify(merchant: String, note: String?) async -> (Category, Double)?
}

/// Layered categoriser, highest priority first:
/// 1. User-learned rules (from corrections)          — confidence 1.0
/// 2. Kind defaults (transfers, cash, salary)         — confidence 1.0
/// 3. Built-in Saudi merchant dictionary              — 0.95
/// 4. MCC code                                        — 0.9
/// 5. Keyword rules (Arabic / English)                — 0.75
/// 6. Fallback `.other`                               — 0
public struct Categorizer: Sendable {
    public var rules: [String: Category]

    public init(rules: [CategoryRule]) {
        var map: [String: Category] = [:]
        for r in rules.sorted(by: { $0.createdAt < $1.createdAt }) { map[r.merchantKey] = r.category }
        self.rules = map
    }

    public func categorize(_ tx: Transaction) -> CategoryDecision {
        switch tx.kind {
        case .income: return .init(category: .salary, source: .kindDefault, confidence: 1)
        case .cashWithdrawal: return .init(category: .cash, source: .kindDefault, confidence: 1)
        case .cardPayment: return .init(category: .internalTransfer, source: .kindDefault, confidence: 1)
        case .cashDeposit: return .init(category: .otherIncome, source: .kindDefault, confidence: 0.6)
        case .fee where tx.merchantRaw == nil: return .init(category: .bills, source: .kindDefault, confidence: 0.8)
        default: break
        }
        if tx.isInternalTransfer { return .init(category: .internalTransfer, source: .kindDefault, confidence: 1) }

        let name = tx.merchantRaw ?? tx.counterparty ?? tx.note ?? ""
        let key = tx.merchantKey ?? TextNormalizer.merchantKey(name)
        if !key.isEmpty, let c = rules[key] { return .init(category: c, source: .learnedRule, confidence: 1) }

        if tx.kind == .transferOut || tx.kind == .transferIn {
            return .init(category: tx.kind == .transferOut ? .transfers : .otherIncome, source: .kindDefault, confidence: 0.9)
        }

        if let c = Self.dictionaryMatch(key) { return .init(category: c, source: .merchantDictionary, confidence: 0.95) }
        if let mcc = tx.mcc, let c = Self.mccCategory(mcc) { return .init(category: c, source: .mcc, confidence: 0.9) }
        let lower = TextNormalizer.normalizeDigits(name + " " + (tx.note ?? "")).lowercased()
        for (c, words) in Self.keywords where SMSParser.has(lower, words) {
            return .init(category: c, source: .keyword, confidence: 0.75)
        }
        if tx.kind == .billPayment { return .init(category: .bills, source: .kindDefault, confidence: 0.8) }
        if tx.direction == .credit && tx.kind != .refund { return .init(category: .otherIncome, source: .kindDefault, confidence: 0.5) }
        return .init(category: .other, source: .none, confidence: 0)
    }

    static func dictionaryMatch(_ key: String) -> Category? {
        guard !key.isEmpty else { return nil }
        if let exact = merchantDictionary[key] { return exact }
        // Whole-token sequence match: "dr cafe" matches "dr cafe olaya", "h m" does not match "smith mart".
        let padded = " " + key + " "
        for (k, c) in merchantDictionaryList where padded.contains(" " + k + " ") { return c }
        return nil
    }

    // Keys are already `TextNormalizer.merchantKey` normalised.
    static let merchantDictionary: [String: Category] = Dictionary(merchantDictionaryList, uniquingKeysWith: { a, _ in a })
    static let merchantDictionaryList: [(String, Category)] = [
        // Coffee
        ("starbucks", .coffee), ("dr cafe", .coffee), ("barns", .coffee), ("half million", .coffee), ("tim hortons", .coffee),
        ("caribou", .coffee), ("costa", .coffee), ("dunkin", .coffee), ("brew", .coffee), ("camel step", .coffee),
        ("overdose", .coffee), ("kyan", .coffee), ("elixir bunn", .coffee), ("ستاربكس", .coffee), ("بارنز", .coffee),
        ("دكتور كيف", .coffee), ("هاف مليون", .coffee), ("كوفي", .coffee), ("كافيه", .coffee), ("قهوة", .coffee),
        // Dining & delivery
        ("albaik", .dining), ("al baik", .dining), ("البيك", .dining), ("mcdonalds", .dining), ("mcdonald", .dining), ("kfc", .dining),
        ("burger king", .dining), ("hardees", .dining), ("herfy", .dining), ("هرفي", .dining), ("kudu", .dining), ("كودو", .dining),
        ("shawarmer", .dining), ("شاورمر", .dining), ("maestro pizza", .dining), ("dominos", .dining), ("pizza hut", .dining),
        ("subway", .dining), ("jahez", .dining), ("جاهز", .dining), ("hungerstation", .dining), ("هنقرستيشن", .dining),
        ("the chefz", .dining), ("chefz", .dining), ("toyou", .dining), ("mrsool", .dining), ("مرسول", .dining), ("keeta", .dining),
        ("nandos", .dining), ("five guys", .dining), ("shake shack", .dining), ("مطعم", .dining), ("restaurant", .dining),
        // Groceries
        ("panda", .groceries), ("بنده", .groceries), ("هايبر بنده", .groceries), ("tamimi", .groceries), ("التميمي", .groceries),
        ("danube", .groceries), ("الدانوب", .groceries), ("othaim", .groceries), ("العثيم", .groceries), ("lulu", .groceries),
        ("لولو", .groceries), ("carrefour", .groceries), ("كارفور", .groceries), ("nesto", .groceries), ("farm superstores", .groceries),
        ("manuel", .groceries), ("ninja", .groceries), ("nana", .groceries), ("نعناع", .groceries), ("bindawood", .groceries),
        ("بن داود", .groceries), ("سوبرماركت", .groceries), ("supermarket", .groceries), ("تموينات", .groceries), ("بقالة", .groceries),
        // Fuel & car
        ("aldrees", .auto), ("الدريس", .auto), ("sasco", .auto), ("ساسكو", .auto), ("petromin", .auto), ("بترومين", .auto),
        ("naft", .auto), ("نفط", .auto), ("almaha", .auto), ("المها", .auto), ("gasoline", .auto), ("محطة", .auto),
        ("محطات", .auto), ("petrol", .auto), ("najm", .auto), ("نجم", .auto), ("tawuniya", .auto), ("مغسلة", .auto),
        // Transport
        ("uber", .transport), ("careem", .transport), ("كريم", .transport), ("bolt", .transport), ("jeeny", .transport),
        ("riyadh metro", .transport), ("sapt", .transport), ("darb", .transport), ("parking", .transport), ("مواقف", .transport),
        // Subscriptions
        ("netflix", .subscriptions), ("نتفلكس", .subscriptions), ("shahid", .subscriptions), ("شاهد", .subscriptions),
        ("spotify", .subscriptions), ("anghami", .subscriptions), ("أنغامي", .subscriptions), ("osn", .subscriptions),
        ("disney", .subscriptions), ("apple com bill", .subscriptions), ("apple services", .subscriptions), ("icloud", .subscriptions),
        ("youtube premium", .subscriptions), ("google one", .subscriptions), ("chatgpt", .subscriptions), ("openai", .subscriptions),
        ("anthropic", .subscriptions), ("claude ai", .subscriptions), ("amazon prime", .subscriptions), ("microsoft", .subscriptions),
        ("adobe", .subscriptions), ("starzplay", .subscriptions), ("tod", .subscriptions),
        // Entertainment & games
        ("playstation", .entertainment), ("steam", .entertainment), ("xbox", .entertainment), ("nintendo", .entertainment),
        ("vox cinemas", .entertainment), ("vox", .entertainment), ("muvi", .entertainment), ("amc", .entertainment),
        ("webook", .entertainment), ("boulevard", .entertainment), ("بوليفارد", .entertainment), ("riyadh season", .entertainment),
        // Travel
        ("saudia", .travel), ("السعودية للطيران", .travel), ("flynas", .travel), ("طيران ناس", .travel), ("flyadeal", .travel),
        ("almosafer", .travel), ("المسافر", .travel), ("booking com", .travel), ("airbnb", .travel), ("agoda", .travel),
        ("expedia", .travel), ("marriott", .travel), ("hilton", .travel), ("hotel", .travel), ("فندق", .travel), ("emirates", .travel),
        ("qatar airways", .travel), ("sar train", .travel), ("haramain", .travel),
        // Health & sport
        ("nahdi", .health), ("النهدي", .health), ("al dawaa", .health), ("الدواء", .health), ("whites", .health), ("صيدلية", .health),
        ("pharmacy", .health), ("fitness time", .health), ("وقت اللياقة", .health), ("leejam", .health), ("gold gym", .health),
        ("hospital", .health), ("مستشفى", .health), ("clinic", .health), ("عيادة", .health), ("dallah", .health), ("sulaiman al habib", .health),
        ("الحبيب", .health),
        // Bills & utilities
        ("stc", .bills), ("mobily", .bills), ("موبايلي", .bills), ("zain", .bills), ("زين", .bills), ("salam", .bills),
        ("saudi electricity", .bills), ("الكهرباء", .bills), ("nwc", .bills), ("المياه الوطنية", .bills), ("sadad", .bills),
        ("absher", .bills), ("أبشر", .bills), ("ejar", .bills), ("إيجار", .bills), ("tamm", .bills), ("muqeem", .bills),
        // Shopping
        ("amazon", .shopping), ("أمازون", .shopping), ("noon", .shopping), ("نون", .shopping), ("namshi", .shopping),
        ("shein", .shopping), ("jarir", .shopping), ("جرير", .shopping), ("extra", .shopping), ("اكسترا", .shopping),
        ("ikea", .shopping), ("ايكيا", .shopping), ("h m", .shopping), ("zara", .shopping), ("centrepoint", .shopping),
        ("max fashion", .shopping), ("nike", .shopping), ("adidas", .shopping), ("apple store", .shopping), ("virgin megastore", .shopping),
        ("saco", .shopping), ("ساكو", .shopping), ("ounass", .shopping), ("trendyol", .shopping), ("aliexpress", .shopping),
        // Personal
        ("barber", .personal), ("حلاق", .personal), ("salon", .personal), ("صالون", .personal), ("laundry", .personal), ("مغسلة ملابس", .personal),
    ]

    static let keywords: [(Category, [String])] = [
        (.coffee, ["coffee", "cafe", "café", "قهوة", "كافيه", "كوفي", "roastery", "محمصة"]),
        (.dining, ["restaurant", "مطعم", "مطاعم", "grill", "burger", "pizza", "shawarma", "شاورما", "kitchen", "مشويات", "bakery", "مخبز", "food"]),
        (.groceries, ["market", "ماركت", "تموينات", "بقالة", "hyper", "هايبر", "grocery"]),
        (.auto, ["fuel", "petrol", "station", "محطة", "وقود", "بنزين", "car wash", "auto", "tyre", "tire", "كفرات", "قطع غيار"]),
        (.transport, ["taxi", "تاكسي", "parking", "مواقف", "metro", "مترو"]),
        (.travel, ["hotel", "فندق", "airline", "airways", "طيران", "resort", "منتجع", "شقق مفروشة"]),
        (.health, ["pharma", "صيدلية", "صيدليات", "hospital", "مستشفى", "clinic", "عيادة", "medical", "طبي", "dental", "أسنان", "gym", "نادي", "fitness"]),
        (.bills, ["electricity", "كهرباء", "water", "مياه", "telecom", "اتصالات", "internet", "انترنت", "فاتورة", "bill", "insurance", "تأمين"]),
        (.entertainment, ["cinema", "سينما", "game", "games", "ألعاب", "العاب", "tickets", "تذاكر", "park", "ملاهي"]),
        (.shopping, ["fashion", "أزياء", "mall", "مول", "electronics", "إلكترونيات", "store", "متجر", "shoes", "أحذية", "عطور", "perfume"]),
        (.personal, ["salon", "صالون", "barber", "حلاق", "spa", "سبا", "laundry", "مغسلة"]),
        (.subscriptions, ["subscription", "اشتراك", "membership", "عضوية", "premium"])
    ]

    static func mccCategory(_ mcc: String) -> Category? {
        guard let code = Int(mcc) else { return nil }
        switch code {
        case 5814: return .dining            // fast food (coffee shops share this; dictionary resolves coffee)
        case 5812, 5813: return .dining
        case 5411, 5422, 5441, 5451, 5499: return .groceries
        case 5541, 5542, 5531, 5532, 5533, 7531, 7534, 7535, 7538, 7542, 7549: return .auto
        case 4111, 4121, 4131, 4784, 7523: return .transport
        case 3000...3350, 4511, 3501...3999, 7011, 4722, 7012: return .travel
        case 4812, 4814, 4899, 4900: return .bills
        case 5815, 5816, 5817, 5818: return .subscriptions
        case 7832, 7841, 7991, 7993, 7994, 7996, 7999: return .entertainment
        case 5912, 8011, 8021, 8031, 8041, 8042, 8043, 8049, 8050, 8062, 8071, 8099, 7997, 7941: return .health
        case 5311, 5651, 5691, 5699, 5661, 5732, 5734, 5945, 5944, 5999, 5310, 5331, 5200, 5712, 5719, 5722, 5977: return .shopping
        case 7230, 7298, 7210, 7211: return .personal
        case 6011, 6010: return .cash
        default: return nil
        }
    }
}
