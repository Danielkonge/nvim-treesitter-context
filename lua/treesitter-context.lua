local api = vim.api
local ts_utils = require'nvim-treesitter.ts_utils'
local highlighter = vim.treesitter.highlighter
-- local ts_query = require('nvim-treesitter.query')
local parsers = require'nvim-treesitter.parsers'
local utils = require'treesitter-context.utils'
local slice = utils.slice
local word_pattern = utils.word_pattern

local defaultConfig = {
  enable = true,
  throttle = false,
  max_lines = 0, -- no limit
}

local config = {}

local has_textoff = vim.fn.has('nvim-0.6')

local ffi = nil
if not has_textoff then
  ffi = require("ffi")
  ffi.cdef'int curwin_col_off(void);'
end

-- Constants

-- Tells us at which node type to stop when highlighting a multi-line
-- node. If not specified, the highlighting stops after the first line.
local last_types = {
  [word_pattern('function')] = {
    c = 'function_declarator',
    cpp = 'function_declarator',
    lua = 'parameters',
    python = 'parameters',
    rust = 'parameters',
    javascript = 'formal_parameters',
    typescript = 'formal_parameters',
  },
}

-- Tells us which leading child node type to skip when highlighting a
-- multi-line node.
local skip_leading_types = {
  [word_pattern('class')] = {
    php = 'attribute_list',
  },
  [word_pattern('method')] = {
    php = 'attribute_list',
  },
}

-- There are language-specific
local DEFAULT_TYPE_PATTERNS = {
  -- These catch most generic groups, eg "function_declaration" or "function_block"
  default = {
    'class',
    'function',
    'method',
    'for',
    'while',
    'if',
    'switch',
    'case',
  },
  rust = {
    'impl_item',
  },
  vhdl = {
    'process_statement',
    'architecture_body',
    'entity_declaration',
  },
  exact_patterns = {},
}
local INDENT_PATTERN = '^%s+'

-- Script variables

local didSetup = false
local enabled
local context_winid
local gutter_winid
local gutter_bufnr, context_bufnr -- Don't access directly, use get_bufs()
local ns = api.nvim_create_namespace('nvim-treesitter-context')
local context_nodes = {}
local context_types = {}
local previous_nodes

local get_target_node = function()
  local tree = parsers.get_parser():parse()[1]
  return tree:root()
end

local is_valid = function(node, filetype)
  local node_type = node:type()
  for _, rgx in ipairs(config.patterns.default) do
    if node_type:find(rgx) then
      return true, rgx
    end
  end
  local filetype_patterns = config.patterns[filetype]
  if filetype_patterns ~= nil then
    for _, rgx in ipairs(filetype_patterns) do
      if node_type:find(rgx) then
        return true, rgx
      end
    end
  end
  return false
end

local get_type_pattern = function(node, type_patterns)
  local node_type = node:type()
  for _, rgx in ipairs(type_patterns) do
    if node_type:find(rgx) then
      return rgx
    end
  end
end

local function find_node(node, type)
  local children = ts_utils.get_named_children(node)
  for _, child in ipairs(children) do
    if child:type() == type then
      return child
    end
  end
  for _, child in ipairs(children) do
    local deep_child = find_node(child, type)
    if deep_child ~= nil then
      return deep_child
    end
  end
end

local get_text_for_node = function(node)
  local type = get_type_pattern(node, config.patterns.default) or node:type()
  local filetype = api.nvim_buf_get_option(0, 'filetype')

  local skip_leading_type = (skip_leading_types[type] or {})[filetype]
  if skip_leading_type then
    local children = ts_utils.get_named_children(node)
    for _, child in ipairs(children) do
      if child:type() ~= skip_leading_type then
        node = child
        break
      end
    end
  end

  local start_row, start_col = node:start()
  local end_row, end_col     = node:end_()

  local lines = ts_utils.get_node_text(node)

  if start_col ~= 0 then
    lines[1] = api.nvim_buf_get_lines(0, start_row, start_row + 1, false)[1]
  end
  start_col = 0

  local last_type = (last_types[type] or {})[filetype]
  local last_position = nil

  if last_type ~= nil then
    local child = find_node(node, last_type)

    if child ~= nil then
      last_position = {child:end_()}

      end_row = last_position[1]
      end_col = last_position[2]
      local last_index = end_row - start_row
      lines = slice(lines, 1, last_index + 1)
      lines[#lines] = slice(lines[#lines], 1, end_col)
    end
  end

  if last_position == nil then
    lines = slice(lines, 1, 1)
    end_row = start_row
    end_col = #lines[1]
  end

  local range = {start_row, start_col, end_row, end_col}

  return lines, range
end

-- Merge lines, removing the indentation after 1st line
local merge_lines = function(lines)
  local text = { lines[1] }
  for i = 2, #lines do
    text[i] = lines[i]:gsub(INDENT_PATTERN, '')
  end
  return table.concat(text, ' ')
end

-- Get indentation for lines except first
local get_indents = function(lines)
  local indents = vim.tbl_map(function(line)
    local indent = line:match(INDENT_PATTERN)
    return indent and #indent or 0
  end, lines)
  -- Dont skip first line indentation
  indents[1] = 0
  return indents
end

local get_gutter_width = function()
  if not has_textoff then
    return ffi.C.curwin_col_off();
  else
    return vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].textoff
  end
end

local nvim_augroup = function(group_name, definitions)
  vim.cmd('augroup ' .. group_name)
  vim.cmd('autocmd!')
  for _, def in ipairs(definitions) do
    local command = table.concat({'autocmd', unpack(def)}, ' ')
    if api.nvim_call_function('exists', {'##' .. def[1]}) ~= 0 then
      vim.cmd(command)
    end
  end
  vim.cmd('augroup END')
end

local cursor_moved_vertical
do
  local line
  cursor_moved_vertical = function()
    local newline =  vim.api.nvim_win_get_cursor(0)[1]
    if newline ~= line then
      line = newline
      return true
    end
    return false
  end
end

local function get_bufs()
  if not context_bufnr or not api.nvim_buf_is_valid(context_bufnr) then
    context_bufnr = api.nvim_create_buf(false, true)
  end

  if not gutter_bufnr or not api.nvim_buf_is_valid(gutter_bufnr) then
    gutter_bufnr = api.nvim_create_buf(false, true)
  end

  return gutter_bufnr, context_bufnr
end

local function delete_bufs()
  if context_bufnr and api.nvim_buf_is_valid(context_bufnr) then
    api.nvim_buf_delete(context_bufnr, { force = true })
  end
  context_bufnr = nil

  if gutter_bufnr and api.nvim_buf_is_valid(gutter_bufnr) then
    api.nvim_buf_delete(gutter_bufnr, { force = true })
  end
  gutter_bufnr = nil
end

local function display_window(bufnr, winid, width, height, col, ty, hl)
  if not winid or not api.nvim_win_is_valid(winid) then
    winid = api.nvim_open_win(bufnr, false, {
      relative = 'win',
      width = width,
      height = height,
      row = 0,
      col = col,
      focusable = false,
      style = 'minimal',
      noautocmd = true,
    })
    api.nvim_win_set_var(winid, ty, true)
    api.nvim_win_set_option(winid, 'winhl', 'NormalFloat:'..hl)
    api.nvim_win_set_option(winid, 'foldenable', false)
  else
    api.nvim_win_set_config(winid, {
      win = api.nvim_get_current_win(),
      relative = 'win',
      width = width,
      height = height,
      row = 0,
      col = col,
    })
  end
  return winid
end

-- Exports

local M = {
  config = config,
}

function M.do_au_cursor_moved_vertical()
  if cursor_moved_vertical() then
    vim.cmd [[doautocmd <nomodeline> User CursorMovedVertical]]
  end
end

function M.get_context(_)
  if not parsers.has_parser() then return nil end

  local cursor_node = ts_utils.get_node_at_cursor()
  if not cursor_node then return nil end

  local matches = {}
  local expr = cursor_node

  local filetype = api.nvim_buf_get_option(0, 'filetype')
  while expr do
    local is_match, type = is_valid(expr, filetype)
    if is_match then
      table.insert(matches, 1, {expr, type})
    end
    expr = expr:parent()
  end

  if #matches == 0 then
    return nil
  end

  return matches
end

function M.get_parent_matches()
  if not parsers.has_parser() then return nil end

  -- FIXME: use TS queries when possible
  -- local matches = ts_query.get_capture_matches(0, '@scope.node', 'locals')

  local current = ts_utils.get_node_at_cursor()
  if not current then return end

  local parent_matches = {}
  local filetype = api.nvim_buf_get_option(0, 'filetype')
  local lines = 0
  local last_row = -1
  local first_visible_line = api.nvim_call_function('line', { 'w0' })

  while current ~= nil do
    local position = {current:start()}
    local row = position[1]

    if is_valid(current, filetype)
        and row > 0
        and row < (first_visible_line - 1)
        and row ~= last_row then
      table.insert(parent_matches, current)

      if row ~= last_row then
        lines = lines + 1
        last_row = position[1]
      end
      if config.max_lines > 0 and lines >= config.max_lines then
        break
      end
    end
    current = current:parent()
  end

  return parent_matches
end

function M.update_context()
  if api.nvim_get_option('buftype') ~= '' or
      vim.fn.getwinvar(0, '&previewwindow') ~= 0 then
    M.close()
    return
  end

  local context = M.get_parent_matches()

  context_nodes = {}
  context_types = {}

  if context then
    for i = #context, 1, -1 do
      local node = context[i]
      local type = get_type_pattern(node, config.patterns.default) or node:type()

      table.insert(context_nodes, node)
      table.insert(context_types, type)
    end
  end

  if #context_nodes ~= 0 then
    M.open()
  else
    M.close()
  end
end

do
  local running = false

  function M.throttled_update_context()
    if running then return end
    running = true
    vim.defer_fn(function()
      local status, err = pcall(M.update_context)

      if not status then
        print('Failed to get context: ' .. err)
      end

      running = false
    end, 100)
  end
end

function M.close()
  previous_nodes = nil

  if context_winid ~= nil and api.nvim_win_is_valid(context_winid) then
    -- Can't close other windows when the command-line window is open
    if api.nvim_call_function('getcmdwintype', {}) ~= '' then
      return
    end

    api.nvim_win_close(context_winid, true)
  end
  context_winid = nil

  if gutter_winid and api.nvim_win_is_valid(gutter_winid) then
    -- Can't close other windows when the command-line window is open
    if api.nvim_call_function('getcmdwintype', {}) ~= '' then
      return
    end

    api.nvim_win_close(gutter_winid, true)
  end
  gutter_winid = nil
end

local function set_lines(bufnr, lines)
  local clines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local redraw = false
  if #clines ~= #lines then
    redraw = true
  else
    for i, l in ipairs(clines) do
      if l ~= lines[i] then
        redraw = true
        break
      end
    end
  end

  if redraw then
    api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  end

  return redraw
end

function M.open()
  if #context_nodes == 0 then
    return
  end

  if context_nodes == previous_nodes then
    return
  end

  previous_nodes = context_nodes

  local saved_bufnr = api.nvim_get_current_buf()

  local gutter_width = get_gutter_width()
  local win_width  = math.max(1, api.nvim_win_get_width(0) - gutter_width)
  local win_height = math.max(1, #context_nodes)

  local gbufnr, bufnr = get_bufs()

  gutter_winid = display_window(
    gbufnr, gutter_winid, gutter_width, win_height, 0,
    'treesitter_context_line_number', 'TreesitterContextLineNumber')

  context_winid = display_window(
    bufnr, context_winid, win_width, win_height, gutter_width,
    'treesitter_context', 'TreesitterContext')

  -- Set text

  local context_text = {}
  local lno_text = {}

  local contexts = {}

  for _, node in ipairs(context_nodes) do
    local lines, range = get_text_for_node(node)
    local text = merge_lines(lines)

    contexts[#contexts+1] = {
      node = node,
      lines = lines,
      range = range,
      indents = get_indents(lines),
    }

    table.insert(context_text, text)

    local linenumber_string = string.format('%d', range[1] + 1)
    local padding_string = string.rep(' ', gutter_width - 1 - string.len(linenumber_string))
    local gutter_string = padding_string .. linenumber_string .. ' '
    table.insert(lno_text, gutter_string)
  end

  if not set_lines(bufnr, context_text) then
    -- Context didn't change, can return here
    return
  end

  set_lines(gbufnr, lno_text)

  -- Highlight

  api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  local buf_highlighter = highlighter.active[saved_bufnr]

  if not buf_highlighter then
    -- Use standard highlighting when TS highlighting is not available
    local current_ft = vim.bo.filetype
    local buffer_ft  = vim.bo[bufnr].filetype
    if current_ft ~= buffer_ft then
      api.nvim_buf_set_option(bufnr, 'filetype', current_ft)
    end
    return
  end

  local buf_query = buf_highlighter:get_query(vim.bo.filetype)

  local query = buf_query:query()

  for i, context in ipairs(contexts) do
    local start_row, _, end_row, end_col = unpack(context.range)
    local indents = context.indents
    local lines = context.lines

    local target_node = get_target_node()

    local start_row_absolute = context.node:start()

    for capture, node in query:iter_captures(target_node, saved_bufnr, start_row, context.node:end_()) do
      local atom_start_row, atom_start_col, atom_end_row, atom_end_col = node:range()

      if atom_end_row > end_row or
        (atom_end_row == end_row and atom_end_col > end_col) then
        break
      end

      if atom_start_row >= start_row_absolute then
        local intended_start_row = atom_start_row - start_row_absolute

        -- Add 1 for each space added between lines when
        -- we replace "\n" with " "
        local offset = intended_start_row
        -- Add the length of each preceding lines
        for j = 1, intended_start_row do
          offset = offset + #lines[j] - indents[j]
        end
        -- Remove the indentation negative offset for current line
        offset = offset - indents[intended_start_row + 1]

        api.nvim_buf_set_extmark(bufnr, ns, i - 1, atom_start_col + offset, {
          end_line = i - 1,
          end_col = atom_end_col + offset,
          hl_group = buf_query.hl_cache[capture]
        })
      end
    end
  end
end

function M.enable()
  local throttle = config.throttle and 'throttled_' or ''
  nvim_augroup('treesitter_context_update', {
    {'WinScrolled', '*',                   'silent lua require("treesitter-context").' .. throttle .. 'update_context()'},
    {'BufEnter',    '*',                   'silent lua require("treesitter-context").' .. throttle .. 'update_context()'},
    {'WinEnter',    '*',                   'silent lua require("treesitter-context").' .. throttle .. 'update_context()'},
    {'User',        'CursorMovedVertical', 'silent lua require("treesitter-context").' .. throttle .. 'update_context()'},
    {'CursorMoved', '*',                   'silent lua require("treesitter-context").do_au_cursor_moved_vertical()'},
    {'WinLeave',    '*',                   'silent lua require("treesitter-context").close()'},
    {'VimResized',  '*',                   'silent lua require("treesitter-context").open()'},
    {'User',        'SessionSavePre',      'silent lua require("treesitter-context").close()'},
    {'User',        'SessionSavePost',     'silent lua require("treesitter-context").open()'},
  })

  M.throttled_update_context()
  enabled = true
end

function M.disable()
  nvim_augroup('treesitter_context_update', {})
  M.close()
  delete_bufs()
  enabled = false
end

function M.toggleEnabled()
  if enabled then
    M.disable()
  else
    M.enable()
  end
end

function M.onVimEnter()
  if didSetup then return end
  -- Setup with default options if user didn't call setup()
  M.setup()
end

-- Setup

function M.setup(options)
  didSetup = true

  local userOptions = options or {}

  config = vim.tbl_deep_extend("force", {}, defaultConfig, userOptions)
  config.patterns =
    vim.tbl_deep_extend("force", {}, DEFAULT_TYPE_PATTERNS, userOptions.patterns or {})
  config.exact_patterns =
    vim.tbl_deep_extend("force", {}, userOptions.exact_patterns or {})

  for filetype, patterns in pairs(config.patterns) do
    -- Map with word_pattern only if users don't need exact pattern matching
    if not config.exact_patterns[filetype] then
      config.patterns[filetype] = vim.tbl_map(word_pattern, patterns)
    end
  end

  if config.enable then
    M.enable()
  else
    M.disable()
  end
end

vim.cmd('command! TSContextEnable  lua require("treesitter-context").enable()')
vim.cmd('command! TSContextDisable lua require("treesitter-context").disable()')
vim.cmd('command! TSContextToggle  lua require("treesitter-context").toggleEnabled()')

vim.cmd('highlight default link TreesitterContext NormalFloat')
vim.cmd('highlight default link TreesitterContextLineNumber LineNr')

nvim_augroup('treesitter_context', {
  {'VimEnter', '*', 'lua require("treesitter-context").onVimEnter()'},
})

return M
