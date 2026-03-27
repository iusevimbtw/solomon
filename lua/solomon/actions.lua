local M = {}

---@class solomon.Action
---@field name string
---@field prompt_template string Template with {context} placeholder
---@field show_input boolean Whether to show the input prompt window

---@type table<string, solomon.Action>
M.actions = {
	explain = {
		name = "Explain",
		prompt_template = "Explain this code clearly and concisely. Cover what it does, why, and any non-obvious behavior:\n\n{context}",
		show_input = false,
	},
	improve = {
		name = "Improve",
		prompt_template = "Improve this code. Fix any bugs or issues, refactor for readability and maintainability, and optimize where possible. {diagnostics}Follow the project conventions if provided. Respond with ONLY the improved code inside a single code block. No explanation before or after the code block.\n\n{project_context}{context}",
		show_input = false,
		inline = true,
	},
	tests = {
		name = "Generate Tests",
		prompt_template = "Generate comprehensive tests for this code. Use the appropriate testing framework for the language. Follow the project conventions described below if provided. Put all test code in a single code block:\n\n{project_context}{context}",
		show_input = false,
	},
	task = {
		name = "Task",
		prompt_template = "{user_prompt}\n\nFollow the project conventions if provided. Respond with ONLY the updated code inside a single code block. No explanation before or after the code block.\n\n{project_context}{context}",
		show_input = true,
		inline = true,
	},
	ask = {
		name = "Ask",
		prompt_template = nil,
		show_input = true,
	},
}

--- Execute a predefined action on the visual selection.
---@param action_name string
function M.run(action_name)
	local action = M.actions[action_name]
	if not action then
		vim.notify("[solomon] Unknown action: " .. action_name, vim.log.levels.ERROR)
		return
	end

	local utils = require("solomon.utils")

	-- Try visual selection first, fall back to treesitter context in normal mode
	local selection = utils.get_visual_selection()
	if not selection then
		selection = utils.get_treesitter_context()
	end
	if not selection then
		vim.notify("[solomon] No selection or function at cursor", vim.log.levels.WARN)
		return
	end

	-- Capture source info for later apply
	local source = {
		bufnr = vim.api.nvim_get_current_buf(),
		start_line = selection.start_line,
		end_line = selection.end_line,
		filetype = selection.filetype,
		filename = selection.filename,
	}

	if action.show_input then
		M._open_prompt(selection, action, source)
	elseif action.inline then
		M._execute_inline(selection, action, source)
	else
		M._execute(selection, action, nil, source)
	end
end

--- Open the prompt window for actions that need user input.
---@param selection table
---@param action solomon.Action
---@param source table
function M._open_prompt(selection, action, source)
	local prompt = require("solomon.prompt")

	prompt.open({
		context_lines = selection.lines,
		filetype = selection.filetype,
		filename = selection.filename,
		start_line = selection.start_line,
		on_submit = function(user_prompt, context_str)
			if action.inline and action.prompt_template then
				-- Inline prompt: build full prompt, then execute inline with spinner
				local utils = require("solomon.utils")
				local context_str_full =
					utils.format_context(selection.lines, selection.filetype, selection.filename, selection.start_line)
				local project_context = M._build_project_context()
				local diagnostics = M._build_diagnostics_context(source)
				local full_prompt = action.prompt_template
					:gsub("{user_prompt}", user_prompt)
					:gsub("{diagnostics}", diagnostics)
					:gsub("{project_context}", project_context)
					:gsub("{context}", context_str_full)
				M._execute_inline(selection, action, source, full_prompt)
			else
				local full_prompt = user_prompt .. "\n\n" .. context_str
				M._send_to_claude(full_prompt, source)
			end
		end,
	})
end

--- Execute an action directly (no prompt window needed).
---@param selection table
---@param action solomon.Action
---@param extra_prompt string|nil
---@param source table
function M._execute(selection, action, extra_prompt, source)
	local utils = require("solomon.utils")
	local context_str =
		utils.format_context(selection.lines, selection.filetype, selection.filename, selection.start_line)

	local project_context = M._build_project_context()
	local diagnostics = M._build_diagnostics_context(source)
	local full_prompt = action.prompt_template
		:gsub("{diagnostics}", diagnostics)
		:gsub("{project_context}", project_context)
		:gsub("{context}", context_str)
	if extra_prompt then
		full_prompt = full_prompt .. "\n\n" .. extra_prompt
	end

	M._send_to_claude(full_prompt, source)
end

--- Execute an inline action — show loader in buffer, replace selection with result.
---@param selection table
---@param action solomon.Action
---@param source table
---@param pre_built_prompt string|nil If provided, skip prompt building
function M._execute_inline(selection, action, source, pre_built_prompt)
	local utils = require("solomon.utils")
	local streaming = require("solomon.streaming")

	local full_prompt
	if pre_built_prompt then
		full_prompt = pre_built_prompt
	else
		local context_str =
			utils.format_context(selection.lines, selection.filetype, selection.filename, selection.start_line)
		local project_context = M._build_project_context()
		local diagnostics = M._build_diagnostics_context(source)
		full_prompt = action.prompt_template
			:gsub("{diagnostics}", diagnostics)
			:gsub("{project_context}", project_context)
			:gsub("{context}", context_str)
	end
	local bufnr = source.bufnr

	-- Create unique namespaces per invocation so concurrent actions don't interfere
	local ns = vim.api.nvim_create_namespace("solomon_inline_" .. vim.uv.hrtime())
	local track_ns = vim.api.nvim_create_namespace("solomon_track_" .. vim.uv.hrtime())

	-- Place tracking extmarks that auto-adjust when lines above shift
	local mark_start = vim.api.nvim_buf_set_extmark(bufnr, track_ns, source.start_line - 1, 0, {})
	local mark_end = vim.api.nvim_buf_set_extmark(bufnr, track_ns, source.end_line - 1, 0, {
		right_gravity = false, -- stays at end of range, not pushed down by edits at this line
	})

	-- Helper to read current tracked positions (0-indexed)
	local function get_tracked_range()
		local s = vim.api.nvim_buf_get_extmark_by_id(bufnr, track_ns, mark_start, {})
		local e = vim.api.nvim_buf_get_extmark_by_id(bufnr, track_ns, mark_end, {})
		return s[1], e[1] -- 0-indexed rows
	end

	-- Add "Thinking..." virtual lines before and after the selection
	local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
	local frame_idx = 1
	local extmark_above = nil
	local extmark_below = nil

	local function set_loader_extmarks()
		local start_row, end_row = get_tracked_range()
		local spinner = spinner_frames[frame_idx]
		local above_opts = {
			virt_lines = { { { spinner .. " Thinking...", "Comment" } } },
			virt_lines_above = true,
		}
		local below_opts = {
			virt_lines = { { { spinner .. " Thinking...", "Comment" } } },
		}
		if extmark_above then
			above_opts.id = extmark_above
		end
		if extmark_below then
			below_opts.id = extmark_below
		end
		extmark_above = vim.api.nvim_buf_set_extmark(bufnr, ns, start_row, 0, above_opts)
		extmark_below = vim.api.nvim_buf_set_extmark(bufnr, ns, end_row, 0, below_opts)
	end

	set_loader_extmarks()

	-- Animate the spinner
	local timer = vim.uv.new_timer()
	timer:start(
		80,
		80,
		vim.schedule_wrap(function()
			if not vim.api.nvim_buf_is_valid(bufnr) then
				timer:stop()
				timer:close()
				return
			end
			frame_idx = (frame_idx % #spinner_frames) + 1
			pcall(set_loader_extmarks)
		end)
	)

	local function stop_spinner()
		timer:stop()
		if not timer:is_closing() then
			timer:close()
		end
		vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
	end

	local function cleanup_tracking()
		pcall(vim.api.nvim_buf_del_extmark, bufnr, track_ns, mark_start)
		pcall(vim.api.nvim_buf_del_extmark, bufnr, track_ns, mark_end)
	end

	-- Accumulate the full response
	local accumulated = ""

	local job = streaming.send({
		prompt = full_prompt,
		on_token = function(token)
			accumulated = accumulated .. token
		end,
		on_done = function(result)
			stop_spinner()
			require("solomon.statusline").record_request(result)

			-- Extract code from the response (find first code block)
			local code = M._extract_code_block(accumulated)
			if not code then
				cleanup_tracking()
				vim.notify("[solomon] No code block found in response — opening response window", vim.log.levels.WARN)
				M._send_to_claude(full_prompt, source)
				return
			end

			local new_lines = vim.split(code, "\n", { plain = true })

			-- Match indentation of the original selection
			local original_indent = utils.detect_indent(selection.lines)
			new_lines = utils.reindent(new_lines, original_indent)

			-- Read current tracked positions (adjusted for any line changes above)
			if vim.api.nvim_buf_is_valid(bufnr) then
				local start_row, end_row = get_tracked_range()
				local orig_count = end_row - start_row + 1
				local line_delta = #new_lines - orig_count

				-- Capture cursor before replacement
				local cursor = vim.api.nvim_win_get_cursor(0)
				local cursor_row = cursor[1] -- 1-indexed
				local cursor_col = cursor[2]
				local replace_end_1 = end_row + 1 -- 1-indexed end of replaced range

				vim.api.nvim_buf_set_lines(bufnr, start_row, end_row + 1, false, new_lines)

				-- Adjust cursor if it was below the replaced range
				if cursor_row > replace_end_1 then
					local new_row = cursor_row + line_delta
					new_row = math.max(1, math.min(new_row, vim.api.nvim_buf_line_count(bufnr)))
					pcall(vim.api.nvim_win_set_cursor, 0, { new_row, cursor_col })
				end

				vim.notify(
					string.format("[solomon] %s: %d → %d lines", action.name, orig_count, #new_lines),
					vim.log.levels.INFO
				)
			end

			cleanup_tracking()
		end,
		on_error = function(err)
			stop_spinner()
			cleanup_tracking()
			vim.notify("[solomon] " .. err, vim.log.levels.ERROR)
		end,
	})
end

--- Build diagnostics context string for the source range.
---@param source table
---@return string
function M._build_diagnostics_context(source)
	local utils = require("solomon.utils")
	local diag_text = utils.get_diagnostics_for_range(source.bufnr, source.start_line, source.end_line)
	if diag_text then
		return "The following LSP diagnostics were found in this code:\n" .. diag_text .. "\n\n"
	end
	return ""
end

--- Build project context string from CLAUDE.md if it exists.
---@return string
function M._build_project_context()
	local utils = require("solomon.utils")
	local claude_md = utils.read_claude_md()
	if claude_md then
		return "Project conventions (from CLAUDE.md):\n```\n" .. claude_md .. "\n```\n\n"
	end
	return ""
end

--- Extract the first code block from a markdown response.
---@param text string
---@return string|nil
function M._extract_code_block(text)
	-- Match content between first ``` fence pair
	local code = text:match("```%S*\n(.-)\n```")
	if code then
		return code
	end
	-- Try without language tag
	code = text:match("```\n(.-)\n```")
	return code
end

--- Send a prompt to Claude and display the streaming response.
---@param prompt string
---@param source table|nil Source buffer info for apply
function M._send_to_claude(prompt, source)
	local streaming = require("solomon.streaming")
	local response = require("solomon.response")

	local win = response.open(source)
	response.set_status("Solomon (streaming...)")

	-- Progress notification (noice.nvim will render this as a spinner)
	local notif_id = "solomon_streaming"
	vim.notify("Waiting for Claude...", vim.log.levels.INFO, {
		title = "Solomon",
		id = notif_id,
		timeout = false,
	})

	local token_count = 0

	local job = streaming.send({
		prompt = prompt,
		on_token = function(token)
			response.append_token(token)
			token_count = token_count + 1
			-- Update progress every 10 tokens to avoid spamming
			if token_count % 10 == 0 then
				vim.notify("Streaming... (" .. token_count .. " chunks)", vim.log.levels.INFO, {
					title = "Solomon",
					id = notif_id,
					timeout = false,
				})
			end
		end,
		on_done = function(result)
			response.show_result_info(result)
			require("solomon.statusline").record_request(result)
			if win then
				win.job = nil
			end

			-- Final notification
			local parts = {}
			if result.duration_ms then
				table.insert(parts, string.format("%.1fs", result.duration_ms / 1000))
			end
			if result.cost_usd then
				table.insert(parts, string.format("$%.4f", result.cost_usd))
			end
			vim.notify(
				"Done" .. (#parts > 0 and " (" .. table.concat(parts, ", ") .. ")" or ""),
				vim.log.levels.INFO,
				{ title = "Solomon", id = notif_id, timeout = 3000 }
			)
		end,
		on_error = function(err)
			response.set_status("Solomon (error)")
			response.append_token("\n\n**Error:** " .. err)
			vim.notify("Error: " .. err, vim.log.levels.ERROR, {
				title = "Solomon",
				id = notif_id,
				timeout = 5000,
			})
		end,
	})

	win.job = job
end

-- Public action shortcuts
function M.ask()
	M.run("ask")
end

function M.explain()
	M.run("explain")
end

function M.improve()
	M.run("improve")
end

function M.task()
	M.run("task")
end

function M.tests()
	M.run("tests")
end

return M
