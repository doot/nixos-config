local site = assert(vim.env.NVIM_TREESITTER_GRAMMARS)
vim.opt.runtimepath:prepend(site)
for lang, source in pairs({ nix = "{ a = 1; }", go = "package main", python = "x = 1" }) do
  local file = "parser/" .. lang .. ".so"
  assert(vim.api.nvim_get_runtime_file(file, false)[1] == site .. "/" .. file, file)
  local root = vim.treesitter.get_string_parser(source, lang):parse()[1]:root()
  assert(not root:has_error(), lang .. ": parse error")
  local query = assert(vim.treesitter.query.get(lang, "highlights"), lang)
  assert(query:iter_captures(root, source)(), lang .. ": no highlight captures")
end
