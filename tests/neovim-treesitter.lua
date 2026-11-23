local site = assert(vim.env.NVIM_TREESITTER_GRAMMARS)
vim.opt.runtimepath:prepend(site)

local function check(lang, source, capture)
  local file = "parser/" .. lang .. ".so"
  assert(vim.api.nvim_get_runtime_file(file, false)[1] == site .. "/" .. file, file)
  local root = vim.treesitter.get_string_parser(source, lang):parse()[1]:root()
  assert(not root:has_error(), lang .. ": parse error")
  local query = assert(vim.treesitter.query.get(lang, "highlights"), lang)
  for id in query:iter_captures(root, source) do
    if query.captures[id] == capture then return end
  end
  error(lang .. ": missing @" .. capture)
end

check("nix", "{ a = 1; }", "number")
check("go", "package main", "module")
check("python", "x = 1", "number")
check("javascript", "42", "number")
check("tsx", "<p />", "tag.delimiter")
check("html", "<p></p>", "tag")
