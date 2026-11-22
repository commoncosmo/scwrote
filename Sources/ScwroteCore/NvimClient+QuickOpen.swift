import Foundation

/// Open and recently opened files under the folder, absolute and in nvim's
/// form.
public struct RecentFiles: Equatable, Sendable {
    public let open: [String]
    public let history: [String]

    public init(open: [String], history: [String]) {
        self.open = open
        self.history = history
    }
}

/// What quick open needs from nvim: the files it has open or remembers, and a
/// way to open one that leaves the search state alone. Paths travel as Lua
/// arguments, never spliced into a command.
extension NvimClient {
    /// `open`: listed, normal (`buftype == ""`) buffers whose name is under
    /// `root` (nvim's form): the alternate buffer first, then by last use,
    /// newest first, then by buffer number, highest first, and the current
    /// buffer last. `history`: `v:oldfiles` resolved through symlinks, kept
    /// when under `root`, in nvim's order.
    public func recentFiles(under root: String) throws -> RecentFiles {
        let trimmed = root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root
        guard case let .array(lists) = try request("nvim_exec_lua", [
            .string(Self.recentFilesLua),
            .array([.string(trimmed)]),
        ]), lists.count == 2 else { return RecentFiles(open: [], history: []) }
        func strings(_ value: MessagePackValue) -> [String] {
            guard case let .array(items) = value else { return [] }
            return items.compactMap { item in
                guard case let .string(text) = item else { return nil }
                return text
            }
        }
        return RecentFiles(open: strings(lists[0]), history: strings(lists[1]))
    }

    /// Edits `path` unless it's the current buffer. With a `line` (1-based) the
    /// cursor goes there, at column 0, centered (`zz`); a line past the end
    /// lands on the last line. Without one nothing else happens. The `/`
    /// register, `v:searchforward` and `v:hlsearch` are never touched.
    public func openFile(_ path: String, line: Int?) throws {
        _ = try request("nvim_exec_lua", [
            .string(Self.openFileLua),
            .array([.string(path), line.map { .int(Int64($0)) } ?? .nil]),
        ])
    }

    private static let recentFilesLua = """
        local root = ...
        local prefix = root == "/" and "/" or root .. "/"
        local function under(name)
          return name:sub(1, #prefix) == prefix
        end
        local current = vim.api.nvim_get_current_buf()
        local alternate = vim.fn.bufnr("#")
        local entries = {}
        for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
          if vim.bo[info.bufnr].buftype == "" and info.name ~= "" and under(info.name) then
            table.insert(entries, info)
          end
        end
        local function rank(info)
          if info.bufnr == current then return 2 end
          if info.bufnr == alternate then return 0 end
          return 1
        end
        table.sort(entries, function(a, b)
          local ra, rb = rank(a), rank(b)
          if ra ~= rb then return ra < rb end
          if a.lastused ~= b.lastused then return a.lastused > b.lastused end
          return a.bufnr > b.bufnr
        end)
        local open = {}
        for _, info in ipairs(entries) do table.insert(open, info.name) end
        local history = {}
        for _, old in ipairs(vim.v.oldfiles) do
          local resolved = vim.fn.resolve(old)
          if under(resolved) then table.insert(history, resolved) end
        end
        return { open, history }
        """

    private static let openFileLua = """
        local path, line = ...
        if vim.api.nvim_buf_get_name(0) ~= path then
          vim.cmd.edit(vim.fn.fnameescape(path))
        end
        if line ~= nil and line ~= vim.NIL then
          local last = vim.api.nvim_buf_line_count(0)
          vim.api.nvim_win_set_cursor(0, { math.max(1, math.min(line, last)), 0 })
          vim.cmd("normal! zz")
        end
        """
}
