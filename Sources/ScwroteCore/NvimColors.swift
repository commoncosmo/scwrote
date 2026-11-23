/// The colors nvim reports for the highlight groups scwrote draws with, decoded
/// from the `scwrote_colors` notification.
public struct NvimColors: Equatable, Codable, Sendable {
    /// What nvim sent for one group; a color it left unset is nil.
    public struct Group: Equatable, Codable, Sendable {
        public var fg: RGBColor?
        public var bg: RGBColor?
        /// `gui=reverse`: nvim draws the group with fg and bg swapped.
        public var reverse: Bool

        public init(fg: RGBColor?, bg: RGBColor?, reverse: Bool = false) {
            self.fg = fg
            self.bg = bg
            self.reverse = reverse
        }

        private enum CodingKeys: String, CodingKey { case fg, bg, reverse }

        /// `reverse` is optional: files saved before it existed lack it.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            fg = try container.decodeIfPresent(RGBColor.self, forKey: .fg)
            bg = try container.decodeIfPresent(RGBColor.self, forKey: .bg)
            reverse = try container.decodeIfPresent(Bool.self, forKey: .reverse) ?? false
        }

        /// `reverse` only when set.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(fg, forKey: .fg)
            try container.encodeIfPresent(bg, forKey: .bg)
            if reverse { try container.encode(true, forKey: .reverse) }
        }
    }

    /// nvim's `background` option: "dark" or "light".
    public var background: String
    /// Only the groups nvim sent; one sent without colors is present and empty.
    public var groups: [String: Group]

    public static let method = "scwrote_colors"
    public static let groupNames = [
        "Normal", "Visual", "Directory", "WarningMsg", "DiagnosticWarn", "WinSeparator", "VertSplit",
    ]

    public init(background: String, groups: [String: Group]) {
        self.background = background
        self.groups = groups
    }

    /// nil for params that don't fit the contract: one map with a string
    /// `background` and a `groups` map of name to `{fg?, bg?}` ints and an
    /// optional `reverse` bool.
    public init?(params: [MessagePackValue]) {
        guard params.count == 1, case let .map(fields) = params[0],
            case let .string(background)? = fields[.string("background")]
        else { return nil }
        var groups: [String: Group] = [:]
        switch fields[.string("groups")] {
        case let .map(pairs)?:
            for (key, value) in pairs {
                guard case let .string(name) = key else { continue }
                // An empty Lua table arrives as an empty array or an empty map.
                guard case let .map(colors) = value else {
                    if case let .array(items) = value, items.isEmpty { groups[name] = Group(fg: nil, bg: nil) }
                    continue
                }
                let reverse = if case .bool(true)? = colors["reverse"] { true } else { false }
                groups[name] = Group(fg: Self.color(colors["fg"]), bg: Self.color(colors["bg"]), reverse: reverse)
            }
        case let .array(items)? where items.isEmpty:
            break
        default:
            return nil
        }
        self.init(background: background, groups: groups)
    }

    private static func color(_ value: MessagePackValue?) -> RGBColor? {
        if case let .int(rgb)? = value { RGBColor(rgb: Int(rgb)) } else { nil }
    }
}

private extension Dictionary where Key == MessagePackValue {
    subscript(_ key: String) -> Value? { self[.string(key)] }
}
