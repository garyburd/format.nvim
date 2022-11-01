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
		vim.api.nvim_err_writeln(table.concat(lines, "\n"))
	end
end

-- update_buffer minimally updates buffer bufnr to new_lines.
local function update_buffer(bufnr, new_lines)
	-- TODO: When I originally wrote a command to format Go code, I improved
	-- cursor positioning by applying the gofmt diff output to the buffer
	-- instead of replacing all lines. Is there still an advantage to minimal
	-- update?
	local prev_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)
	local diffs = vim.diff(table.concat(new_lines, "\n"), table.concat(prev_lines, "\n"), {
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
		vim.api.nvim_buf_set_lines(bufnr, s, e, 1, replacement)
	end
end

-- Sentinel values used when building commands.
local insert_extra = {} -- insert elements of array config[ft].extra
local insert_bufname = {} -- insert the buffer's name

local function build_command(bufnr, cmd, extra)
	local result = {}
	for _, x in ipairs(cmd) do
		if x == insert_extra then
			if extra then
				for _, y in ipairs(extra) do
					result[#result + 1] = y
				end
			end
		elseif x == insert_bufname then
			result[#result + 1] = vim.api.nvim_buf_get_name(bufnr)
		else
			result[#result + 1] = x
		end
	end
	return result
end

local formatters = {
	lua = {
		cmd = { "stylua", "--stdin-filepath", insert_bufname, insert_extra, "-" },
		err = function(line)
			local lnum, col = line:match("%(starting from line (%d+), character (%d+)")
			if lnum then
				return { lnum = lnum, col = col, text = line, type = "E" }
			end
		end,
	},
	go = {
		cmd = { "goimports", "-srcdir", insert_bufname, insert_extra },
		err = function(line)
			local lnum, col, text = line:match("^.+:(%d+):(%d+):%s+(.*)")
			if lnum ~= "" then
				return { lnum = lnum, col = col, text = text, type = "E" }
			end
		end,
	},
	zig = {
		cmd = { "zig", "fmt", "--stdin", insert_extra },
		err = function(line)
			local lnum, col, text = line:match("^.+:(%d+):(%d+):%s+(.*)")
			if lnum ~= "" then
				return { lnum = lnum, col = col, text = text, type = "E" }
			end
		end,
	},
	python = {
		cmd = { "black", "--quiet", insert_extra, "-" },
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
		vim.api.nvim_err_writeln("No formatter for " .. ft)
		return
	end
	local bufnr = vim.api.nvim_get_current_buf()
	local cmd = build_command(bufnr, fmt.cmd, config[ft])
	local lines = vim.fn.systemlist(cmd, bufnr)
	if vim.v.shell_error == 0 then
		update_buffer(bufnr, lines)
	else
		show_error(bufnr, lines, fmt.err)
	end
end

return M
