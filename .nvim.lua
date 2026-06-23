-- Project-local Neovim config for Hyper.
--
-- This file is loaded only when `exrc` is enabled in your main config
-- (`vim.o.exrc = true`). The first time it's seen, Neovim prompts you to
-- `:trust` it. Because exrc loads from the cwd, Neovim's working directory is
-- the project root here, so the `mix format` fallback resolves `.formatter.exs`.
--
-- Behaviour: format Elixir and Rust buffers on save. Prefer an attached LSP
-- (elixir-ls / lexical / next-ls for Elixir, rust-analyzer for Rust) since it's
-- instant; otherwise pipe the buffer through `mix format` / `rustfmt`.

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

-- Pipe the buffer through `cmd` (a list), replacing it with stdout on success.
local function pipe_format(bufnr, cmd)
  local input = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  local out = vim.fn.system(cmd, input)

  if vim.v.shell_error ~= 0 then
    vim.notify(cmd[1] .. " failed:\n" .. out, vim.log.levels.WARN)
    return
  end

  out = out:gsub("\n$", "")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(out, "\n"))
end

-- Fallback formatters keyed by file extension.
local function fallback_format(bufnr)
  local file = vim.api.nvim_buf_get_name(bufnr)
  if file:match("%.rs$") then
    -- rustfmt defaults to edition 2015; the crate is 2021.
    pipe_format(bufnr, { "rustfmt", "--emit", "stdout", "--edition", "2021" })
  else
    pipe_format(bufnr, { "mix", "format", "--stdin-filename", file, "-" })
  end
end

vim.api.nvim_create_autocmd("BufWritePre", {
  group = group,
  pattern = { "*.ex", "*.exs", "*.heex", "*.rs" },
  callback = function(args)
    if has_lsp_formatter(args.buf) then
      vim.lsp.buf.format({ bufnr = args.buf, async = false, timeout_ms = 5000 })
    else
      fallback_format(args.buf)
    end
  end,
})

-- Line-length guides for Elixir: wrap target 97, ruler at 98.
vim.api.nvim_create_autocmd("FileType", {
  group = group,
  pattern = "elixir",
  callback = function()
    vim.opt_local.textwidth = 97
    vim.opt_local.colorcolumn = "98"
  end,
})
