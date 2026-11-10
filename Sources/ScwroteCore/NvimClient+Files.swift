import Foundation

/// Keeping nvim's buffers in step with what the file browser did on disk.
/// Paths are in nvim's form (symlinks resolved) and travel as Lua arguments,
/// never spliced into a command, so any name is safe.
extension NvimClient {
    /// After the file or folder at `from` moved to `to` on disk: every loaded buffer at `from`
    /// or under it takes the matching name under `to`, keeping unsaved changes. No buffer
    /// keeps the old name. `:w` afterwards writes to the new name without an error, except
    /// for a buffer whose writes another BufWriteCmd could handle (a plugin's, say): that one
    /// needs `:w!` once (see `renameBuffersLua` for why).
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
    /// That `:w!` runs every BufWriteCmd for the file, not just ours, and
    /// others write for real (stock nvim has one for `*.shada`; plugins for
    /// `*.gpg`, `*.ipynb`, ...). So when any other could apply to the buffer,
    /// the empty write is skipped: the buffer is renamed and still modified,
    /// but a plain `:w` then refuses with E13 and `:w!` is needed. Visible
    /// and safe, where the alternative would write the changes behind the
    /// user's back. Buffers with a special 'buftype' are only renamed, too:
    /// they can't be written, and nothing makes them "not edited" that matters.
    ///
    /// A buffer that isn't loaded is wiped instead: it holds no text, and a
    /// renamed one would keep "not edited" when loaded later (a write needs a
    /// loaded buffer).
    ///
    /// One buffer failing doesn't stop the rest; the failures are reported
    /// together at the end.
    private static let renameBuffersLua = buffersUnderLua + autocommandPatternLua + """

        local from, to = ...
        local group = vim.api.nvim_create_augroup("ScwroteRename", { clear = true })

        -- Whether a BufWriteCmd other than ours could run when `buf`, named
        -- `path`, is written.
        local function others_handle_writes(buf, path)
          for _, au in ipairs(vim.api.nvim_get_autocmds({ event = "BufWriteCmd" })) do
            if au.group ~= group then
              if au.buflocal then
                if au.buffer == buf then return true end
              elseif pattern_matches(au.pattern, path) then
                return true
              end
            end
          end
          return false
        end

        local function rename(buf, old, new)
          vim.api.nvim_buf_call(buf, function()
            vim.cmd.file({ args = { new }, magic = { file = false }, mods = { keepalt = true, silent = true } })
          end)
          for _, other in ipairs(vim.api.nvim_list_bufs()) do
            if other ~= buf and vim.api.nvim_buf_is_valid(other) and not vim.api.nvim_buf_is_loaded(other)
                and vim.api.nvim_buf_get_name(other) == old then
              vim.api.nvim_buf_delete(other, { force = true })
            end
          end
          if vim.bo[buf].buftype ~= "" or others_handle_writes(buf, new) then return end
          vim.api.nvim_create_autocmd("BufWriteCmd", { group = group, buffer = buf, callback = function() end })
          local ok, err = pcall(vim.api.nvim_buf_call, buf, function()
            vim.cmd.write({ bang = true, mods = { keepalt = true, silent = true } })
          end)
          vim.api.nvim_clear_autocmds({ group = group })
          if not ok then error(err, 0) end
        end

        local failures = {}
        for _, found in ipairs(buffers_under(from)) do
          -- An earlier rename can have wiped it: `:file` drops an unloaded
          -- buffer for the same file (a hard link).
          if vim.api.nvim_buf_is_valid(found.buf) then
            local ok, err = pcall(function()
              if vim.api.nvim_buf_is_loaded(found.buf) then
                rename(found.buf, found.name, to .. found.name:sub(#from + 1))
              else
                vim.api.nvim_buf_delete(found.buf, { force = true })
              end
            end)
            if not ok then table.insert(failures, found.name .. ": " .. tostring(err)) end
          end
        end
        vim.api.nvim_del_augroup_by_id(group)
        if #failures > 0 then error(table.concat(failures, "\\n"), 0) end
        """

    /// Defines `pattern_matches(pattern, path)`: whether an autocommand
    /// pattern could match the file at `path`. It errs towards yes, since a
    /// yes only costs the user a `:w!`: both the full path and the tail are
    /// tried whatever the pattern (nvim tries both for patterns without a
    /// `/`), case is ignored, `~` and `$VARS` are tried expanded too, and a
    /// pattern that can't be read counts as matching.
    static let autocommandPatternLua = #"""

        local function pattern_matches(pattern, path)
          local tail = vim.fn.fnamemodify(path, ":t")
          local globs = { pattern }
          if pattern:find("[~$]") then table.insert(globs, vim.fs.normalize(pattern)) end
          for _, glob in ipairs(globs) do
            local ok, regex = pcall(function() return vim.regex([[\c]] .. vim.fn.glob2regpat(glob)) end)
            if not ok then return true end
            if regex:match_str(path) or regex:match_str(tail) then return true end
          end
          return false
        end
        """#

    /// Wiped, not just deleted, so no buffer keeps the name of a file that's
    /// gone. A window showing one moves to another buffer, or an empty one.
    /// One failing doesn't stop the rest; the failures are reported together.
    private static let closeBuffersLua = buffersUnderLua + """

        local path = ...
        local failures = {}
        for _, found in ipairs(buffers_under(path)) do
          if vim.api.nvim_buf_is_valid(found.buf) then
            local ok, err = pcall(vim.api.nvim_buf_delete, found.buf, { force = true })
            if not ok then table.insert(failures, found.name .. ": " .. tostring(err)) end
          end
        end
        if #failures > 0 then error(table.concat(failures, "\\n"), 0) end
        """
}
