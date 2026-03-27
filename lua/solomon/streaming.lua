local M = {}

---@class solomon.StreamingRequest
---@field prompt string The full prompt to send
---@field on_token fun(text: string) Called for each text token
---@field on_done fun(result: solomon.StreamingResult) Called when complete
---@field on_error fun(err: string) Called on error

---@class solomon.StreamingResult
---@field text string Full accumulated response text
---@field cost_usd number|nil Estimated cost
---@field model string|nil Model used
---@field duration_ms number|nil Duration in milliseconds
---@field input_tokens integer|nil
---@field output_tokens integer|nil

---@class solomon.StreamingJob
---@field job_id integer
---@field cancel fun()
---@field is_active fun(): boolean

--- Send a prompt to Claude via `claude -p --output-format stream-json`.
---@param request solomon.StreamingRequest
---@return solomon.StreamingJob
function M.send(request)
  local config = require("solomon.config").options
  local cmd = { config.cli.cmd, "-p", "--output-format", "stream-json", "--verbose" }

  if config.cli.model then
    table.insert(cmd, "--model")
    table.insert(cmd, config.cli.model)
  end

  for _, arg in ipairs(config.cli.args) do
    table.insert(cmd, arg)
  end

  local accumulated_text = ""
  local result_data = {}
  local start_time = vim.uv.hrtime()
  local active = true

  -- jobstart on_stdout delivers data as a list of strings split on newlines.
  -- The last element is "" if the chunk ended with a newline, or a partial
  -- line if it didn't. We keep that partial as `tail` for the next callback.
  local tail = ""

  local job_id = vim.fn.jobstart(cmd, {
    stdin = "pipe",
    stdout_buffered = false,

    on_stdout = function(_, data)
      if not data or not active then
        return
      end

      -- Prepend leftover from previous chunk to the first element
      data[1] = tail .. data[1]
      -- Last element is either "" (complete line) or partial (save for next)
      tail = table.remove(data)

      for _, line in ipairs(data) do
        if line ~= "" then
          local ok, event = pcall(vim.json.decode, line)
          if ok and event then
            M._handle_event(event, request, accumulated_text, result_data, function(new_text)
              accumulated_text = new_text
            end)
          end
        end
      end
    end,

    on_stderr = function(_, data)
      if not data then
        return
      end
      local msg = vim.trim(table.concat(data, "\n"))
      if msg ~= "" then
        result_data.stderr = (result_data.stderr or "") .. msg .. "\n"
      end
    end,

    on_exit = function(_, exit_code)
      active = false
      vim.schedule(function()
        -- Process any remaining data in tail
        if tail ~= "" then
          local ok, event = pcall(vim.json.decode, tail)
          if ok and event then
            M._handle_event(event, request, accumulated_text, result_data, function(new_text)
              accumulated_text = new_text
            end)
          end
          tail = ""
        end

        local elapsed = (vim.uv.hrtime() - start_time) / 1e6

        if exit_code ~= 0 and accumulated_text == "" then
          local err_msg = "Claude exited with code " .. exit_code
          if result_data.stderr then
            err_msg = err_msg .. "\n" .. vim.trim(result_data.stderr)
          end
          request.on_error(err_msg)
          return
        end

        request.on_done({
          text = accumulated_text,
          cost_usd = result_data.cost_usd,
          model = result_data.model,
          duration_ms = elapsed,
          input_tokens = result_data.input_tokens,
          output_tokens = result_data.output_tokens,
        })
      end)
    end,
  })

  if job_id <= 0 then
    request.on_error("Failed to start claude process")
    return {
      job_id = -1,
      cancel = function() end,
      is_active = function() return false end,
    }
  end

  -- Send the prompt via stdin and close it
  vim.fn.chansend(job_id, request.prompt)
  vim.fn.chanclose(job_id, "stdin")

  return {
    job_id = job_id,
    cancel = function()
      active = false
      pcall(vim.fn.jobstop, job_id)
    end,
    is_active = function()
      return active
    end,
  }
end

--- Handle a single streaming JSON event.
---@param event table
---@param request solomon.StreamingRequest
---@param accumulated string
---@param result_data table
---@param set_accumulated fun(text: string)
function M._handle_event(event, request, accumulated, result_data, set_accumulated)
  local event_type = event.type

  if event_type == "content_block_delta" then
    local delta = event.delta
    if delta and delta.type == "text_delta" and delta.text then
      local new_text = accumulated .. delta.text
      set_accumulated(new_text)
      vim.schedule(function()
        request.on_token(delta.text)
      end)
    end
  elseif event_type == "message_start" then
    if event.message and event.message.model then
      result_data.model = event.message.model
    end
    -- Capture input token count from initial message
    if event.message and event.message.usage then
      result_data.input_tokens = event.message.usage.input_tokens
    end
  elseif event_type == "message_delta" then
    if event.usage then
      result_data.output_tokens = event.usage.output_tokens
      result_data.cost_usd = M._estimate_cost(
        { input_tokens = result_data.input_tokens, output_tokens = result_data.output_tokens },
        result_data.model
      )
    end
  elseif event_type == "result" then
    -- Claude Code stream-json wraps the final result
    if event.cost_usd then
      result_data.cost_usd = event.cost_usd
    end
    if event.model then
      result_data.model = event.model
    end
    if event.duration_ms then
      result_data.duration_ms = event.duration_ms
    end
    if event.result then
      local text = type(event.result) == "string" and event.result or ""
      if text ~= "" and accumulated == "" then
        set_accumulated(text)
        vim.schedule(function()
          request.on_token(text)
        end)
      end
    end
  end
end

--- Rough cost estimate from usage data.
---@param usage table
---@param model string|nil
---@return number|nil
function M._estimate_cost(usage, model)
  if not usage then
    return nil
  end

  local input_tokens = usage.input_tokens or 0
  local output_tokens = usage.output_tokens or 0

  -- Approximate pricing per 1M tokens
  local rates = {
    ["claude-sonnet"] = { input = 3.0, output = 15.0 },
    ["claude-opus"] = { input = 15.0, output = 75.0 },
    ["claude-haiku"] = { input = 0.25, output = 1.25 },
  }

  local rate = rates["claude-sonnet"]
  if model then
    for key, r in pairs(rates) do
      if model:find(key, 1, true) then
        rate = r
        break
      end
    end
  end

  return (input_tokens * rate.input + output_tokens * rate.output) / 1e6
end

return M
