-- Project-local Neovim config for Hyper.
--
-- This file is loaded only when `exrc` is enabled in your main config
-- (`vim.o.exrc = true`). The first time it's seen, Neovim prompts you to
-- `:trust` it. Because exrc loads from the cwd, Neovim's working directory is
-- the project root here, so the `mix format` fallback resolves `.formatter.exs`.
--
-- Behaviour: format Elixir buffers on save. Prefer an attached Elixir LSP
-- (elixir-ls / lexical / next-ls) since it's instant; otherwise pipe the buffer
-- through `mix format`.

local group = vim.api.nvim_create_augroup("hyper_autoformat", { clear = true })
local get_clients = vim.lsp.get_clients or vim.lsp.get_active_clients

local function has_lsp_formatter(bufnr)
  for _, client in ipairs(get_clients({ bufnr = bufnr })) do
    local caps = client.server_capabilities or {}
    if caps.documentFormattingProvider then
      return true
    end
  end
  return false
end

local function mix_format(bufnr)
  local file = vim.api.nvim_buf_get_name(bufnr)
  local input = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  local out = vim.fn.system({ "mix", "format", "--stdin-filename", file, "-" }, input)

  if vim.v.shell_error ~= 0 then
    vim.notify("mix format failed:\n" .. out, vim.log.levels.WARN)
    return
  end

  out = out:gsub("\n$", "")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(out, "\n"))
end

vim.api.nvim_create_autocmd("BufWritePre", {
  group = group,
  pattern = { "*.ex", "*.exs", "*.heex" },
  callback = function(args)
    if has_lsp_formatter(args.buf) then
      vim.lsp.buf.format({ bufnr = args.buf, async = false, timeout_ms = 5000 })
    else
      mix_format(args.buf)
    end
  end,
})
