-- https://github.com/neovim/neovim/blob/bccae5a05aef24e6b94d1433172897b3661c05d9/runtime/lua/vim/lsp/codelens.lua

local util = require('vim.lsp.util')
local hi = require('jg.highlight')

local api = vim.api
local active_requests = {}
local M = {}
local namespaces = setmetatable({}, {
  __index = function(t, key)
    local value = api.nvim_create_namespace('vim-lsp-codelenses:' .. key)
    rawset(t, key, value)
    return value
  end;
})

local function bufid(b)
 return b > 0 and b or api.nvim_get_current_buf()
end

local lenses = {}
local function set_lenses(client_id, bufnr, buf_lenses)
  if not lenses[client_id] then
    lenses[client_id] = { [bufnr] = buf_lenses }
  else
    lenses[client_id][bufnr] = buf_lenses
  end
end

local function get_lenses(client_id, bufnr)
  if not lenses[client_id] then
    lenses[client_id] = { [bufnr] = {} }
  elseif not lenses[client_id][bufnr] then
    lenses[client_id][bufnr] = {}
  end

  return lenses[client_id][bufnr]
end

local function get_lenses_by_client(bufnr)
  local by_client = {}

  for client_id in pairs(lenses or {}) do
    by_client[client_id] = get_lenses(client_id, bufnr)
  end

  return by_client
end

local function group_by_line(result)
  local lenses_by_line = {}

  for _, lens in pairs(result or {}) do
    local line = lens.range.start.line

    if not lenses_by_line[line] then
      lenses_by_line[line] = { lens }
    else
      table.insert(lenses_by_line[line], lens)
    end
  end

  return lenses_by_line
end

local function set_virtual_text(bufnr, ns, line, line_lenses)
  local chunks = {}

  for _, lens in pairs(line_lenses) do
    if lens.command then
      if #chunks == 0 then
        table.insert(chunks, { '‣ ', 'LspCodeLensTextSign'})
      else
        table.insert(chunks, { ' | ', 'LspCodeLensTextSeparator'})
      end
      table.insert(chunks, { lens.command.title, 'LspCodeLensText'})
    end
  end

  api.nvim_buf_set_virtual_text(bufnr, ns, line, chunks, {})
end

local function set_sign(line)
  vim.fn.sign_place(
    new_line, SIGN_GROUP, "LspCodeLensSign", "%",
    { lnum = line, priority = 1 }
  )
end


local function render_lenses(client_id, bufnr)
  local ns = namespaces[client_id]

  api.nvim_buf_clear_namespace(bufnr, ns, 1, -1)

  local buf_lenses = get_lenses(client_id, bufnr)

  for line, line_lenses in pairs(group_by_line(buf_lenses)) do
    set_virtual_text(bufnr, ns, line, line_lenses)
  end
end

local function resolve(bufnr, lens, done)
  local cancel = vim.lsp.buf_request(bufnr, 'codeLens/resolve', lens, function(err, _, result, _, _)
    assert(not err, vim.inspect(err))
    if result and result.command then done(result) end
  end)

  table.insert(active_requests, cancel)
end

local function on_codelens(err, _, result, client_id, bufnr)
  if err ~= nil and err.code == vim.lsp.protocol.ErrorCodes.MethodNotFound then
    -- none of the running lamguage servers support code lenses
    return
  end

  assert(not err, vim.inspect(err))

  bufnr = bufid(bufnr)

  set_lenses(client_id, bufnr, result or {})
  render_lenses(client_id, bufnr)

  for idx, lens in pairs(result or {}) do
    if not lens.command then
      resolve(bufnr, lens, function(lens_result)
        result[idx] = lens_result
        set_lenses(client_id, bufnr, result or {})
        render_lenses(client_id, bufnr)
      end)
    end
  end
end

local function execute_codelens_command(bufnr, line, client_id, command)
  api.nvim_buf_clear_namespace(bufnr, namespaces[client_id], line - 1, line)
  vim.lsp.buf.execute_command(command)
end

local function select(title, options, displayName)
  if #options == 0 then
    print('No code lenses available')
    return

  elseif #options == 1 then
    return options[1]
  end

  local options_strings = { title }
  for i, option in ipairs(options) do
     table.insert(options_strings, string.format('%d. %s', i, displayName(option)))
  end
  local choice = vim.fn.inputlist(options_strings)
  if choice < 1 or choice > #options then return end
  return options[choice]
end

local function cancel_active_requests()
  for _, cancel in pairs(active_requests) do cancel() end
  active_requests = {}
end

--- Refresh codelenses for the current buffer
function M.buf_codelenses_refresh()
  cancel_active_requests()

  local _, cancel = vim.lsp.buf_request(0, 'textDocument/codeLens', {
    textDocument = util.make_text_document_params()
  })

  table.insert(active_requests, cancel)
end

function M.setup()
  vim.lsp.handlers['textDocument/codeLens'] = on_codelens

  vim.cmd('highlight! link LspCodeLensText Comment')
  vim.cmd('highlight! link LspCodeLensTextSign LspCodeLensText')
  vim.cmd('highlight! link LspCodeLensTextSeparator LspCodeLensText')

  vim.cmd('augroup jg.lsp.codelenses')
  vim.cmd('  autocmd!')
  vim.cmd('  autocmd BufEnter,InsertLeave,CursorHold * :lua require("jg.lsp.codelenses").buf_codelenses_refresh()')
  vim.cmd('augroup end')
end

function M.buf_codelens_action()
  local line = api.nvim_win_get_cursor(0)[1]
  local bufnr = api.nvim_get_current_buf()
  local options = {}

  local lenses_by_client = get_lenses_by_client(bufnr)
  for client_id, client_lenses in pairs(lenses_by_client) do
    for _, lens in pairs(client_lenses) do
      if lens.range.start.line == (line - 1) then
        table.insert(options, {client=client_id, lens=lens})
      end
    end
  end

  local option = select('Code lenses:', options, function(option) return option.lens.command.title end)
  if option then
    execute_codelens_command(bufnr, line, option.client, option.lens.command)
  end
end

return M
