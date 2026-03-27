--- Statusline components for lualine.nvim integration.

local M = {}

-- Track cumulative cost across requests in this session
M._total_cost = 0
M._request_count = 0
M._last_model = nil

--- Record a completed request's cost.
---@param result solomon.StreamingResult
function M.record_request(result)
  M._request_count = M._request_count + 1
  if result.cost_usd then
    M._total_cost = M._total_cost + result.cost_usd
  end
  if result.model then
    M._last_model = result.model
  end
end

--- Reset cost tracking.
function M.reset()
  M._total_cost = 0
  M._request_count = 0
  M._last_model = nil
end

--- Main statusline component function.
--- Usage in lualine: `require("solomon.statusline").component()`
---@return function
function M.component()
  return function()
    local parts = {}

    -- MCP status indicator
    local mcp_ok, mcp = pcall(require, "solomon.mcp.server")
    if mcp_ok and mcp.is_running() then
      table.insert(parts, "MCP")
    end

    -- Model
    if M._last_model then
      local short = M._last_model:match("claude%-([%w%.%-]+)") or M._last_model
      table.insert(parts, short)
    end

    -- Cost
    if M._total_cost > 0 then
      table.insert(parts, string.format("$%.3f", M._total_cost))
    end

    if #parts == 0 then
      return ""
    end

    return table.concat(parts, " | ")
  end
end

--- Condition function — only show when solomon has been active.
---@return function
function M.condition()
  return function()
    local mcp_ok, mcp = pcall(require, "solomon.mcp.server")
    local mcp_running = mcp_ok and mcp.is_running()
    return mcp_running or M._request_count > 0
  end
end

--- Lualine component config for easy drop-in.
--- Add to your lualine config:
---   lualine_x = { require("solomon.statusline").lualine() }
---@return table
function M.lualine()
  return {
    M.component(),
    cond = M.condition(),
    color = { fg = "#7aa2f7" },
  }
end

return M
