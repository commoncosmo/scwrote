-- Picks the palette for 'background' and applies it.
local M = {}

-- The choices' names are the values of scwrote's settings (and of
-- g:scwrote_light_colors / g:scwrote_dark_colors).
M.palettes = {
  warmPaper = require("scwrote.palettes.warm_paper"),
  coolSlate = require("scwrote.palettes.cool_slate"),
  softDark = require("scwrote.palettes.soft_dark"),
}

-- What each background may use, the first being its default. nvimDefault is
-- nvim's own built-in dark: no palette, just what `hi clear` restores.
local choices = {
  light = { "warmPaper", "coolSlate" },
  dark = { "softDark", "nvimDefault" },
}

-- The choice for `background`: its global's value if that's one of its
-- choices, else its default.
function M.choice(background)
  local options = choices[background] or choices.dark
  local wanted = vim.g["scwrote_" .. background .. "_colors"]
  for _, option in ipairs(options) do
    if option == wanted then return option end
  end
  return options[1]
end

-- The choice for the current 'background': what load() applies.
function M.current()
  return M.choice(vim.o.background == "light" and "light" or "dark")
end

function M.load()
  local choice = M.current()
  vim.cmd("hi clear")
  vim.g.colors_name = "scwrote"
  local palette = M.palettes[choice]
  if not palette then return end
  for name, spec in pairs(require("scwrote.groups")(palette)) do
    vim.api.nvim_set_hl(0, name, spec)
  end
end

return M
