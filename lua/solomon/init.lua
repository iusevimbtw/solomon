local M = {}

---@param opts solomon.Config|nil
function M.setup(opts)
	require("solomon.config").setup(opts)

	M.register_commands()
	M.register_keymaps()

	-- Auto-start MCP server if configured
	local config = require("solomon.config").options
	if config.mcp.enabled and config.mcp.auto_start then
		-- Defer to avoid slowing down startup
		vim.defer_fn(function()
			require("solomon.mcp.server").start()
		end, 100)
	end

	-- Clean up MCP server on exit
	vim.api.nvim_create_autocmd("VimLeavePre", {
		callback = function()
			local mcp = require("solomon.mcp.server")
			if mcp.is_running() then
				mcp.stop()
			end
		end,
	})
end

function M.register_commands()
	vim.api.nvim_create_user_command("Solomon", function(cmd)
		local args = vim.split(cmd.args, "%s+", { trimempty = true })
		local subcmd = args[1] or ""

		if subcmd == "toggle" or subcmd == "" then
			require("solomon.terminal").toggle()
		elseif subcmd == "open" then
			require("solomon.terminal").open()
		elseif subcmd == "close" then
			require("solomon.terminal").close()
		elseif subcmd == "mcp-start" then
			require("solomon.mcp.server").start()
		elseif subcmd == "mcp-stop" then
			require("solomon.mcp.server").stop()
		elseif subcmd == "mcp-status" then
			local mcp = require("solomon.mcp.server")
			if mcp.is_running() then
				local port = mcp.get_port()
				vim.notify(string.format("[solomon] MCP server running on port %d", port or 0), vim.log.levels.INFO)
			else
				vim.notify("[solomon] MCP server not running", vim.log.levels.INFO)
			end
		elseif subcmd == "review" then
			local staged = args[2] == "staged"
			require("solomon.git").review({ staged = staged })
		elseif subcmd == "review-staged" then
			require("solomon.git").review({ staged = true })
		elseif subcmd == "review-hunk" then
			require("solomon.git").review_hunk()
		elseif subcmd == "commit" then
			require("solomon.git").commit()
		elseif subcmd == "blame" then
			require("solomon.git").blame()
		elseif subcmd == "sessions" then
			require("solomon.sessions").pick()
		elseif subcmd == "sessions-project" then
			require("solomon.sessions").pick({ project_only = true })
		elseif subcmd == "continue" then
			require("solomon.sessions").continue_last()
		elseif subcmd == "resume" then
			local session_id = args[2]
			if session_id then
				require("solomon.sessions").resume(session_id)
			else
				require("solomon.sessions").pick()
			end
		else
			vim.notify("Solomon: unknown command '" .. subcmd .. "'", vim.log.levels.ERROR)
		end
	end, {
		nargs = "?",
		desc = "Solomon - Claude Code integration",
		complete = function()
			return {
				"toggle",
				"open",
				"close",
				"review",
				"review-staged",
				"review-hunk",
				"commit",
				"blame",
				"sessions",
				"sessions-project",
				"continue",
				"resume",
				"mcp-start",
				"mcp-stop",
				"mcp-status",
			}
		end,
	})
end

function M.register_keymaps()
	local config = require("solomon.config").options
	local km = config.keymaps

	local function map(mode, lhs, rhs, desc)
		if lhs and lhs ~= "" then
			vim.keymap.set(mode, lhs, rhs, { desc = desc, silent = true })
		end
	end

	map("n", km.toggle, function()
		require("solomon.terminal").toggle()
	end, "Toggle Claude Code")

	map({ "n", "v" }, km.ask, function()
		require("solomon.actions").ask()
	end, "Ask Claude")

	map({ "n", "v" }, km.explain, function()
		require("solomon.actions").explain()
	end, "Explain code")

	map({ "n", "v" }, km.refactor, function()
		require("solomon.actions").refactor()
	end, "Refactor code")

	map({ "n", "v" }, km.fix, function()
		require("solomon.actions").fix()
	end, "Fix code")

	map({ "n", "v" }, km.optimize, function()
		require("solomon.actions").optimize()
	end, "Optimize code")

	map({ "n", "v" }, km.tests, function()
		require("solomon.actions").tests()
	end, "Generate tests")

	map("n", km.sessions, function()
		require("solomon.sessions").pick()
	end, "Browse sessions")

	map("n", km.continue_session, function()
		require("solomon.sessions").continue_last()
	end, "Continue last session")

	map("n", km.review, function()
		require("solomon.git").review()
	end, "Review git diff")

	map("n", km.commit, function()
		require("solomon.git").commit()
	end, "Generate commit message")

	map({ "n", "v" }, km.blame, function()
		require("solomon.git").blame()
	end, "Explain git blame")

	-- Register which-key group with icons
	local wk_ok, wk = pcall(require, "which-key")
	if wk_ok then
		wk.add({
			{ "<leader>a", group = "Solomon (AI)", icon = "🤖", mode = { "n", "v" } },
			{ km.toggle, icon = "󰄛" },
			{ km.ask, icon = "❓", mode = { "n", "v" } },
			{ km.explain, icon = "🧠", mode = { "n", "v" } },
			{ km.refactor, icon = "♻️", mode = { "n", "v" } },
			{ km.fix, icon = "🔧", mode = { "n", "v" } },
			{ km.optimize, icon = "⚡", mode = { "n", "v" } },
			{ km.tests, icon = "🧪", mode = { "n", "v" } },
			{ km.sessions, icon = "📋" },
			{ km.continue_session, icon = "▶️" },
			{ km.review, icon = "󰊢" },
			{ km.commit, icon = "󰜘" },
			{ km.blame, icon = "󰋽", mode = { "n", "v" } },
		})
	end
end

return M
