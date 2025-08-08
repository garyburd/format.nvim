-- show_error displays the error in lines through quick fix or the error buffer.
local function show_error(bufnr, lines, errfn)
  local qfl = {}
  for _, line in ipairs(lines) do
    local qf = errfn(line)
    if qf then
      qf.bufnr = bufnr
      qf.lnum = tonumber(qf.lnum)
      if qf.col then
        qf.col = tonumber(qf.col)
      end
      qfl[#qfl + 1] = qf
    end
  end
  if #qfl > 0 then
    vim.fn.setqflist(qfl)
    vim.api.nvim_command("cc 1")
  else
    vim.api.nvim_echo({ { table.concat(lines, "\n"), "ErrorMsg" } }, true, {})
  end
end

-- update_buffer minimally updates buffer bufnr to new_lines.
local function update_buffer(bufnr, new_lines)
  -- TODO: When I originally wrote a command to format Go code, I improved
  -- cursor positioning by applying the gofmt diff output to the buffer
  -- instead of replacing all lines. Is there still an advantage to minimal
  -- update?
  local prev_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)
  local diffs = vim.text.diff(table.concat(new_lines, "\n"), table.concat(prev_lines, "\n"), {
    algorithm = "minimal",
    ctxlen = 0,
    result_type = "indices",
  })

  -- Apply diffs in reverse order.
  for i = #diffs, 1, -1 do
    local new_start, new_count, prev_start, prev_count = unpack(diffs[i])
    local replacement = {}
    for j = new_start, new_start + new_count - 1, 1 do
      replacement[#replacement + 1] = new_lines[j]
    end
    local s, e
    if prev_count == 0 then
      s = prev_start
      e = s
    else
      s = prev_start - 1
      e = s + prev_count
    end
    vim.api.nvim_buf_set_lines(bufnr, s, e, true, replacement)
  end
end

-- Sentinel values used when building commands.
local ignore = {}

local function build_command(fn, bufnr, extra)
  local result = {}
  for _, v in ipairs(fn(bufnr, extra)) do
    if v == ignore then
    -- do nothing
    elseif type(v) == "table" then
      for _, vv in ipairs(v) do
        table.insert(result, vv)
      end
    else
      table.insert(result, tostring(v))
    end
  end
  return result
end

local formatters = {
  fennel = {
    cmd = function(_, extra)
      return { "fnlfmt", extra, "-" }
    end,
    err = function(line)
      local lnum, col = line:match("lua: %-:(%-?%d+):(%-?%d+):")
      if lnum then
        return { lnum = lnum, col = col, text = line, type = "E" }
      end
    end,
  },
  lua = {
    cmd = function(bufnr, extra)
      return {
        "stylua",
        "--indent-type",
        vim.api.nvim_get_option_value("expandtab", { buf = bufnr }) and "Spaces" or "Tabs",
        "--indent-width",
        vim.api.nvim_get_option_value("shiftwidth", { buf = bufnr }),
        "--stdin-filepath",
        vim.api.nvim_buf_get_name(bufnr),
        extra,
        "-",
      }
    end,
    err = function(line)
      local lnum, col = line:match("%(starting from line (%d+), character (%d+)")
      if lnum then
        return { lnum = lnum, col = col, text = line, type = "E" }
      end
    end,
  },
  go = {
    cmd = function(bufnr, extra)
      return { "goimports", "-srcdir", vim.api.nvim_buf_get_name(bufnr), extra }
    end,
    err = function(line)
      local lnum, col, text = line:match("^.+:(%d+):(%d+):%s+(.*)")
      if lnum ~= "" then
        return { lnum = lnum, col = col, text = text, type = "E" }
      end
    end,
  },
  zig = {
    cmd = function(bufnr, extra)
      return { "zig", "fmt", "--stdin", vim.api.nvim_buf_get_name(bufnr), extra }
    end,
    err = function(line)
      local lnum, col, text = line:match("^.+:(%d+):(%d+):%s+(.*)")
      if lnum ~= "" then
        return { lnum = lnum, col = col, text = text, type = "E" }
      end
    end,
  },
  python = {
    cmd = function(bufnr, extra)
      return { "ruff", "format", "--stdin-filename", vim.api.nvim_buf_get_name(bufnr), extra }
    end,
    err = function(line)
      local m1, lnum, col, m2 = line:match("^[^:]+:[^:]+:([^:]+:%s+)(%d+):(%d+):%s+(.*)")
      if lnum then
        return { lnum = lnum, col = col, text = m1 .. m2, type = "E" }
      end
    end,
  },
}

local M = {}

local config = {}
function M.setup(c)
  config = c
end

function M.run()
  local ft = vim.opt_local.filetype:get()
  local fmt = formatters[ft]
  if not fmt then
    vim.api.nvim_echo({ { "No formatter for " .. ft, 'ErrorMsg' } }, true, {})
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local cmd = build_command(fmt.cmd, bufnr, config[ft] or ignore)
  local lines = vim.fn.systemlist(cmd, bufnr)
  if vim.v.shell_error == 0 then
    update_buffer(bufnr, lines)
  else
    show_error(bufnr, lines, fmt.err)
  end
end

return M
