import Foundation

/// How loading a folder's nvim session went.
public enum SessionRestore: Equatable, Sendable {
    /// The session loaded.
    case restored
    /// There was no session file.
    case missing
    /// A session was already loaded (the user's `-S`, or a session plugin),
    /// so scwrote left nvim alone.
    case skipped
    /// The session loaded with an error; whatever loaded stays.
    case failed(String)
}

/// nvim's side of reopening a folder where the user left off: a narrow
/// `:mksession` (files, splits, sizes, tabs, cursors, nothing of the user's
/// configuration), written when nvim exits or on request, and loaded back
/// after nvim starts without overriding the user's options. Paths travel as
/// Lua arguments, never spliced into a command.
extension NvimClient {
    /// Returns once nvim has finished starting (`v:vim_did_enter`): the user's
    /// config ran and the files on its command line are loaded. nvim can
    /// answer requests before that, whenever its startup lets events through
    /// (a config's `:sleep`, a plugin manager waiting), so an answer alone
    /// doesn't mean it's done. Asks every `interval`; a request that times out
    /// (nvim busy in a long config) is asked again. Throws when nvim can't be
    /// reached, e.g. because it exited.
    public func waitUntilStarted(interval: TimeInterval = 0.05) throws {
        while true {
            do {
                if case let .int(entered) = try request("nvim_get_vvar", [.string("vim_did_enter")]), entered != 0 {
                    return
                }
            } catch Failure.connectionLost {
                // Timed out (or the connection broke): try again, reconnecting.
            }
            Thread.sleep(forTimeInterval: interval)
        }
    }

    /// Installs a `ScwroteSession` augroup (replacing an earlier one) with a
    /// `VimLeavePre` autocommand that saves the session to `path`, as
    /// `saveSession(to:)` does. Errors then are dropped: a message at exit
    /// could hold nvim at a prompt.
    public func installSessionSaver(path: String) throws {
        _ = try request("nvim_exec_lua", [
            .string(Self.saveFunctionLua + Self.installSaverLua),
            .array([.string(path)]),
        ])
    }

    /// Saves the session to `path` now, for a window closing on a running
    /// nvim. If no listed buffer has a file name, deletes `path` instead (no
    /// error if it's missing), so an empty session never replaces a real one.
    /// Otherwise `:mksession!` with `'sessionoptions'` set, for the write
    /// only, to `buffers,tabpages,winsize`; the user's value, and
    /// `v:this_session`, are put back even if the write fails.
    public func saveSession(to path: String) throws {
        _ = try request("nvim_exec_lua", [
            .string(Self.saveFunctionLua + "save(...)"),
            .array([.string(path)]),
        ])
    }

    /// Loads the session at `path` right after nvim starts. `.skipped` if
    /// `v:this_session` is already set (someone else's session is loaded:
    /// scwrote doesn't stack a second one on it); `.missing` if there's no
    /// file. Otherwise `:silent! source` it, so an error (the session's, or a
    /// plugin's autocommand as a file loads) doesn't stop the rest loading,
    /// with the global options a session file sets as they were at save time
    /// put back to the user's values after. Whatever loaded stays; an error
    /// makes the result `.failed` with nvim's (last) message, for logging.
    /// `v:this_session` is left empty either way, so nothing of the user's
    /// writes over scwrote's file.
    ///
    /// After a load either way: unmodified listed buffers whose file no longer
    /// exists are wiped, unless named in `namedFiles` (the launch's named
    /// files, absolute; they may include values of nvim's flags). Then the
    /// first of `namedFiles` that nvim has as a buffer is shown in the current
    /// window, the others nvim has are kept listed, and the argument list is
    /// exactly the ones nvim has, in order; entries nvim doesn't have are
    /// ignored.
    public func restoreSession(from path: String, namedFiles: [String]) throws -> SessionRestore {
        let result = try request("nvim_exec_lua", [
            .string(Self.restoreLua),
            .array([.string(path), .array(namedFiles.map { .string($0) })]),
        ])
        guard case let .array(parts) = result, case let .string(kind)? = parts.first else {
            return .failed("unexpected answer from nvim: \(result)")
        }
        switch kind {
        case "restored": return .restored
        case "missing": return .missing
        case "skipped": return .skipped
        default:
            if parts.count > 1, case let .string(message) = parts[1] { return .failed(message) }
            return .failed("unknown error")
        }
    }

    /// Defines a local `save(path)`.
    private static let saveFunctionLua = """
        local function save(path)
          local has_file = false
          for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
            if info.name ~= "" and vim.bo[info.bufnr].buftype == "" then
              has_file = true
              break
            end
          end
          if not has_file then
            os.remove(path)
            return
          end
          -- :mksession points v:this_session at the file it writes; left so,
          -- the user's own "save to v:this_session" code would write over
          -- scwrote's file with the user's full 'sessionoptions'.
          local users = vim.o.sessionoptions
          local this_session = vim.v.this_session
          vim.o.sessionoptions = "buffers,tabpages,winsize"
          local ok, err = pcall(vim.cmd.mksession, { vim.fn.fnameescape(path), bang = true })
          vim.o.sessionoptions = users
          vim.v.this_session = this_session
          if not ok then error(err, 0) end
        end

        """

    private static let installSaverLua = """
        local path = ...
        local group = vim.api.nvim_create_augroup("ScwroteSession", { clear = true })
        vim.api.nvim_create_autocmd("VimLeavePre", {
          group = group,
          callback = function() pcall(save, path) end,
        })
        """

    private static let restoreLua = """
        local path, named = ...
        if vim.v.this_session ~= "" then return { "skipped" } end
        if vim.fn.filereadable(path) == 0 then return { "missing" } end

        -- A session file sets these as they were at save time; the user's
        -- config wins. 'winminheight' and 'winminwidth' are 0 while the
        -- session loads and while the others are put back, so no
        -- 'winheight' or 'winwidth' can fail against them (a session sets
        -- the saved 'winheight', which errors below a larger 'winminheight'
        -- than the saving nvim had); then back to the user's values, which
        -- fit the user's 'winheight' and 'winwidth'.
        local names = { "winheight", "winwidth", "showtabline", "shortmess", "hlsearch",
          "splitbelow", "splitright", "scrolloff", "sidescrolloff" }
        local users = {}
        for _, name in ipairs(names) do users[name] = vim.go[name] end
        local users_wmh, users_wmw = vim.go.winminheight, vim.go.winminwidth
        vim.go.winminheight = 0
        vim.go.winminwidth = 0

        -- silent!: an error (the session's, or a plugin's autocommand while a
        -- file loads) doesn't stop the rest of the session loading. v:errmsg
        -- then holds the last one.
        local users_errmsg = vim.v.errmsg
        vim.v.errmsg = ""
        local ok, err = pcall(vim.cmd, { cmd = "source", args = { vim.fn.fnameescape(path) },
          mods = { emsg_silent = true } })
        if ok and vim.v.errmsg ~= "" then ok, err = false, vim.v.errmsg end
        if ok then vim.v.errmsg = users_errmsg end

        pcall(function() vim.go.winminheight = 0 end)
        pcall(function() vim.go.winminwidth = 0 end)
        for _, name in ipairs(names) do
          pcall(function() vim.go[name] = users[name] end)
        end
        pcall(function() vim.go.winminheight = users_wmh end)
        pcall(function() vim.go.winminwidth = users_wmw end)

        -- The session points v:this_session at scwrote's file; left so, the
        -- user's own "save to v:this_session" code would write over it.
        vim.v.this_session = ""
        -- Set while a session loads, for plugins; the session's last line
        -- clears it, unless it never got there.
        vim.g.SessionLoad = nil

        -- Named files: as given and in nvim's full form.
        local is_named = {}
        for _, name in ipairs(named) do
          is_named[name] = true
          is_named[vim.fn.fnamemodify(name, ":p")] = true
        end
        local by_name = {}
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          local name = vim.api.nvim_buf_get_name(buf)
          if name ~= "" then by_name[name] = buf end
        end

        -- Files deleted since the save don't come back as empty buffers.
        for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
          if info.name ~= "" and vim.bo[info.bufnr].buftype == "" and not vim.bo[info.bufnr].modified
              and not is_named[info.name] and vim.uv.fs_stat(info.name) == nil then
            pcall(vim.api.nvim_buf_delete, info.bufnr, {})
          end
        end

        local known = {}
        for _, name in ipairs(named) do
          local buf = by_name[name] or by_name[vim.fn.fnamemodify(name, ":p")]
          if buf and vim.api.nvim_buf_is_valid(buf) then
            vim.bo[buf].buflisted = true
            table.insert(known, buf)
          end
        end
        if #known > 0 then
          vim.cmd.buffer(tostring(known[1]))
          -- The session empties the argument list; a launch on files has
          -- them as its arguments.
          vim.cmd("silent! %argdelete")
          for _, buf in ipairs(known) do
            vim.cmd.argadd(vim.fn.fnameescape(vim.api.nvim_buf_get_name(buf)))
          end
        end

        if ok then return { "restored" } end
        return { "failed", tostring(err) }
        """
}
