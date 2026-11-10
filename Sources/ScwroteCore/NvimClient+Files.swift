import Foundation

/// Keeping nvim's buffers in step with what the file browser did on disk.
/// Paths are in nvim's form (symlinks resolved) and travel as Lua arguments,
/// never spliced into a command, so any name is safe.
extension NvimClient {
    /// After the file or folder at `from` moved to `to` on disk: every loaded buffer at `from`
    /// or under it takes the matching name under `to`, keeping unsaved changes, and `:w`
    /// afterwards writes to the new name without an error. No buffer keeps the old name.
    public func renameBuffers(from: String, to: String) throws {
        _ = try request("nvim_exec_lua", [
            .string(Self.renameBuffersLua),
            .array([.string(Self.trimmingSlash(from)), .string(Self.trimmingSlash(to))]),
        ])
    }

    /// Closes every buffer at `path` or under it, discarding unsaved changes.
    public func closeBuffers(at path: String) throws {
        _ = try request("nvim_exec_lua", [
            .string(Self.closeBuffersLua),
            .array([.string(Self.trimmingSlash(path))]),
        ])
    }

    /// `/a/b/` and `/a/b` name the same folder; matching wants the latter.
    private static func trimmingSlash(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// Shared by both: the buffers at `path` or under it, with their names.
    private static let buffersUnderLua = """
        local function buffers_under(path)
          local found = {}
          for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            local name = vim.api.nvim_buf_get_name(buf)
            if name == path or name:sub(1, #path + 1) == path .. "/" then
              table.insert(found, { buf = buf, name = name })
            end
          end
          return found
        end
        """

    /// `:file` renames the buffer in place, so its text, unsaved changes, undo
    /// history and marks all stay. But it has two side effects to undo:
    ///
    /// - It leaves an unlisted, unloaded buffer with the old name behind (even
    ///   under `:keepalt`, which only stops it becoming the alternate file).
    ///   That one is wiped.
    /// - It marks the buffer "not edited", so a plain `:w` refuses with E13
    ///   because the file exists. Only re-editing the file or a write clears
    ///   that, and re-editing would throw the changes away. So the buffer gets
    ///   a write that writes nothing: a buffer-local BufWriteCmd that does
    ///   nothing intercepts a `:w!`, and nvim, taking the write as done by the
    ///   autocommand, clears the flag and records the file's timestamp. The
    ///   buffer stays modified (nvim notices the autocommand saved nothing),
    ///   and the autocommand is removed straight after, even on failure, so it
    ///   can never swallow a real `:w`.
    ///
    /// A buffer that isn't loaded is wiped instead: it holds no text, and a
    /// renamed one would keep "not edited" when loaded later (a write needs a
    /// loaded buffer).
    private static let renameBuffersLua = buffersUnderLua + """

        local from, to = ...
        local group = vim.api.nvim_create_augroup("ScwroteRename", { clear = true })

        local function rename(buf, old, new)
          vim.api.nvim_buf_call(buf, function()
            vim.cmd.file({ args = { new }, magic = { file = false }, mods = { keepalt = true, silent = true } })
          end)
          for _, other in ipairs(vim.api.nvim_list_bufs()) do
            if other ~= buf and not vim.api.nvim_buf_is_loaded(other)
                and vim.api.nvim_buf_get_name(other) == old then
              vim.api.nvim_buf_delete(other, { force = true })
            end
          end
          vim.api.nvim_create_autocmd("BufWriteCmd", { group = group, buffer = buf, callback = function() end })
          local ok, err = pcall(vim.api.nvim_buf_call, buf, function()
            vim.cmd.write({ bang = true, mods = { keepalt = true, silent = true } })
          end)
          vim.api.nvim_clear_autocmds({ group = group })
          if not ok then error(err, 0) end
        end

        local ok, err = pcall(function()
          for _, found in ipairs(buffers_under(from)) do
            if vim.api.nvim_buf_is_loaded(found.buf) then
              rename(found.buf, found.name, to .. found.name:sub(#from + 1))
            else
              vim.api.nvim_buf_delete(found.buf, { force = true })
            end
          end
        end)
        vim.api.nvim_del_augroup_by_id(group)
        if not ok then error(err, 0) end
        """

    /// Wiped, not just deleted, so no buffer keeps the name of a file that's
    /// gone. A window showing one moves to another buffer, or an empty one.
    private static let closeBuffersLua = buffersUnderLua + """

        local path = ...
        for _, found in ipairs(buffers_under(path)) do
          vim.api.nvim_buf_delete(found.buf, { force = true })
        end
        """
}
