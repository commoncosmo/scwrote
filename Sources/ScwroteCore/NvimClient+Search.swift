import Foundation

/// What project search needs from nvim: the text of unsaved buffers, so
/// search covers edits not yet on disk, and a way to open a match. Paths and
/// the query travel as Lua arguments, never spliced into a command.
extension NvimClient {
    /// Loaded, modified, normal (`buftype == ""`) buffers whose name is under
    /// `root` (nvim's form), text joined with "\n" plus a final "\n" when the
    /// buffer's 'eol' is set, so it reads like the file would on disk.
    public func unsavedBuffers(under root: String) throws -> [UnsavedBuffer] {
        let trimmed = root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root
        guard case let .array(found) = try request("nvim_exec_lua", [
            .string(Self.unsavedBuffersLua),
            .array([.string(trimmed)]),
        ]) else { return [] }
        return found.compactMap { entry in
            guard case let .array(pair) = entry, pair.count == 2,
                  case let .string(path) = pair[0], case let .string(text) = pair[1]
            else { return nil }
            return UnsavedBuffer(path: path, text: text)
        }
    }

    /// Edits `path` unless it's the current buffer (so unsaved changes in it
    /// never block the jump), puts the cursor at `line` (1-based) and byte
    /// `column`, centers it (`zz`), and sets the `/` register to `\V\c` +
    /// query with `\` and `/` escaped, so `n` finds the query literally and
    /// ignoring case. A line the file no longer has lands on the last line.
    public func open(_ path: String, line: Int, column: Int, query: String) throws {
        _ = try request("nvim_exec_lua", [
            .string(Self.openLua),
            .array([.string(path), .int(Int64(line)), .int(Int64(column)), .string(query)]),
        ])
    }

    private static let unsavedBuffersLua = """
        local root = ...
        local found = {}
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          local name = vim.api.nvim_buf_get_name(buf)
          if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified and vim.bo[buf].buftype == ""
              and name:sub(1, #root + 1) == root .. "/" then
            local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\\n")
            if vim.bo[buf].eol then text = text .. "\\n" end
            table.insert(found, { name, text })
          end
        end
        return found
        """

    private static let openLua = #"""
        local path, line, column, query = ...
        if vim.api.nvim_buf_get_name(0) ~= path then
          vim.cmd.edit(vim.fn.fnameescape(path))
        end
        local last = vim.api.nvim_buf_line_count(0)
        if not pcall(vim.api.nvim_win_set_cursor, 0, { line, column }) then
          vim.api.nvim_win_set_cursor(0, { math.max(1, math.min(line, last)), 0 })
        end
        vim.cmd("normal! zz")
        vim.fn.setreg("/", [[\V\c]] .. vim.fn.escape(query, [[\/]]))
        if vim.o.hlsearch then vim.v.hlsearch = 1 end
        """#
}
