-- Turns a palette into highlight groups: { [name] = nvim_set_hl spec }.
--
-- It covers every group nvim's built-in default gives its own colors.
-- Treesitter, LSP and diagnostic groups that nvim links to these base groups
-- (`@keyword` -> Keyword -> Statement, `@property` -> Identifier,
-- DiagnosticSignError -> DiagnosticError, LspReferenceText -> Visual...)
-- keep those links, which `hi clear` restores, so they follow the palette.
return function(p)
  return {
    -- The editor and scwrote's file browser.
    Normal = { fg = p.fg, bg = p.bg },
    NormalNC = { link = "Normal" },
    MsgArea = { link = "Normal" },
    StdoutMsg = { link = "Normal" },
    -- Its fg is the browser's dim text (headers, prompts).
    ScwroteBrowser = { fg = p.browser_dim, bg = p.browser },
    -- Plain, as in nvim's default: completed text keeps the colors under it.
    ComplMatchIns = {},

    -- Syntax.
    Comment = { fg = p.comment, italic = true },
    Constant = { fg = p.number },
    String = { fg = p.string },
    Identifier = { fg = p.property },
    ["@variable"] = { fg = p.fg },
    Function = { fg = p.func },
    Statement = { fg = p.keyword },
    Operator = { fg = p.fg },
    PreProc = { fg = p.special },
    Type = { fg = p.type },
    Special = { fg = p.special },
    Delimiter = { fg = p.fg2 },
    Underlined = { underline = true },
    Error = { fg = p.error, bg = p.error_bg },
    Todo = { fg = p.warn, bold = true },
    Title = { fg = p.title, bold = true },
    Directory = { fg = p.directory },
    ["@markup.strong"] = { bold = true },
    ["@markup.italic"] = { italic = true },
    ["@markup.strikethrough"] = { strikethrough = true },
    ["@markup.underline"] = { underline = true },
    -- Help files' heading rules: the text hidden, the rule drawn under it.
    ["@markup.heading.1.delimiter.vimdoc"] = { fg = p.bg, bg = p.bg, sp = p.fg, underdouble = true, nocombine = true },
    ["@markup.heading.2.delimiter.vimdoc"] = { fg = p.bg, bg = p.bg, sp = p.fg, underline = true, nocombine = true },

    -- The gutter, cursor and selection.
    LineNr = { fg = p.line_nr },
    CursorLineNr = { fg = p.fg2, bold = true },
    SignColumn = { fg = p.line_nr },
    CursorLine = { bg = p.cursorline },
    CursorColumn = { bg = p.cursorline },
    ColorColumn = { bg = p.cursorline },
    Cursor = { fg = p.bg, bg = p.fg },
    lCursor = { fg = p.bg, bg = p.fg },
    TermCursor = { reverse = true },
    Visual = { bg = p.selection },
    MatchParen = { bg = p.match, bold = true },
    NonText = { fg = p.nontext },
    Conceal = { fg = p.nontext },
    Folded = { fg = p.fg2, bg = p.float },
    WinSeparator = { fg = p.divider },

    -- Search.
    Search = { fg = p.fg, bg = p.search },
    CurSearch = { fg = p.cur_search_fg, bg = p.cur_search },
    QuickFixLine = { fg = p.func, bold = true },

    -- Popup menus and floats.
    NormalFloat = { fg = p.fg, bg = p.float },
    FloatBorder = { fg = p.border, bg = p.float },
    FloatShadow = { bg = p.shadow, blend = 80 },
    FloatShadowThrough = { bg = p.shadow, blend = 100 },
    Pmenu = { fg = p.fg, bg = p.pmenu },
    PmenuSel = { fg = p.fg, bg = p.pmenu_sel },
    PmenuThumb = { bg = p.border },
    PmenuMatch = { fg = p.func, bold = true },
    PmenuMatchSel = { fg = p.func, bold = true },

    -- Status, tab and window bars.
    StatusLine = { fg = p.fg, bg = p.status },
    StatusLineNC = { fg = p.status_nc_fg, bg = p.status_nc },
    TabLineSel = { fg = p.fg, bg = p.bg, bold = true },
    WinBar = { fg = p.fg2, bg = p.bg, bold = true },
    WinBarNC = { fg = p.comment, bg = p.bg },

    -- Messages.
    ErrorMsg = { fg = p.error },
    WarningMsg = { fg = p.warn },
    ModeMsg = { fg = p.ok },
    OkMsg = { fg = p.ok },
    MoreMsg = { fg = p.func },
    Question = { fg = p.func },

    -- Diffs, and the signs and text that mark changes.
    DiffAdd = { bg = p.diff_add },
    DiffChange = { bg = p.diff_change },
    DiffDelete = { fg = p.diff_delete_fg, bg = p.diff_delete },
    DiffText = { bg = p.diff_text },
    Added = { fg = p.ok },
    Changed = { fg = p.info },
    Removed = { fg = p.error },

    -- Diagnostics.
    DiagnosticError = { fg = p.error },
    DiagnosticWarn = { fg = p.warn },
    DiagnosticInfo = { fg = p.info },
    DiagnosticHint = { fg = p.hint },
    DiagnosticOk = { fg = p.ok },
    DiagnosticUnderlineError = { sp = p.error, undercurl = true },
    DiagnosticUnderlineWarn = { sp = p.warn, undercurl = true },
    DiagnosticUnderlineInfo = { sp = p.info, undercurl = true },
    DiagnosticUnderlineHint = { sp = p.hint, undercurl = true },
    DiagnosticUnderlineOk = { sp = p.ok, undercurl = true },
    DiagnosticDeprecated = { sp = p.error, strikethrough = true },

    -- Spelling.
    SpellBad = { sp = p.error, undercurl = true },
    SpellCap = { sp = p.warn, undercurl = true },
    SpellLocal = { sp = p.ok, undercurl = true },
    SpellRare = { sp = p.info, undercurl = true },

    -- nvim's own debugging aids.
    NvimInternalError = { fg = p.error, bg = p.error },
    RedrawDebugNormal = { reverse = true },
    RedrawDebugClear = { bg = p.search },
    RedrawDebugComposed = { bg = p.diff_add },
    RedrawDebugRecompose = { bg = p.diff_delete },
  }
end
