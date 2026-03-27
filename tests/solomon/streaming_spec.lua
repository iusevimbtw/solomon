describe("solomon.streaming", function()
  local streaming

  before_each(function()
    package.loaded["solomon.streaming"] = nil
    package.loaded["solomon.config"] = nil
    require("solomon.config").setup()
    streaming = require("solomon.streaming")
  end)

  describe("_handle_event", function()
    local accumulated, result_data, tokens

    before_each(function()
      accumulated = ""
      result_data = {}
      tokens = {}
    end)

    local function handle(event)
      streaming._handle_event(event, {
        on_token = function(text)
          table.insert(tokens, text)
        end,
      }, accumulated, result_data, function(new_text)
        accumulated = new_text
      end)
    end

    it("extracts text from content_block_delta", function()
      handle({
        type = "content_block_delta",
        delta = { type = "text_delta", text = "hello" },
      })
      assert.equals("hello", accumulated)
    end)

    it("accumulates multiple deltas", function()
      handle({
        type = "content_block_delta",
        delta = { type = "text_delta", text = "hello " },
      })
      handle({
        type = "content_block_delta",
        delta = { type = "text_delta", text = "world" },
      })
      assert.equals("hello world", accumulated)
    end)

    it("captures model from message_start", function()
      handle({
        type = "message_start",
        message = { model = "claude-sonnet-4-6-20250320" },
      })
      assert.equals("claude-sonnet-4-6-20250320", result_data.model)
    end)

    it("captures input tokens from message_start", function()
      handle({
        type = "message_start",
        message = { model = "claude-sonnet-4-6-20250320", usage = { input_tokens = 100 } },
      })
      assert.equals(100, result_data.input_tokens)
    end)

    it("captures output tokens from message_delta", function()
      handle({
        type = "message_delta",
        usage = { output_tokens = 50 },
      })
      assert.equals(50, result_data.output_tokens)
    end)

    it("captures cost from result event", function()
      handle({
        type = "result",
        cost_usd = 0.0042,
        model = "claude-sonnet-4-6-20250320",
      })
      assert.equals(0.0042, result_data.cost_usd)
      assert.equals("claude-sonnet-4-6-20250320", result_data.model)
    end)

    it("ignores unknown event types", function()
      handle({ type = "unknown_event", data = "test" })
      assert.equals("", accumulated)
    end)

    it("ignores content_block_delta with non-text type", function()
      handle({
        type = "content_block_delta",
        delta = { type = "input_json_delta", partial_json = "{}" },
      })
      assert.equals("", accumulated)
    end)
  end)

  describe("_estimate_cost", function()
    it("estimates sonnet cost", function()
      local cost = streaming._estimate_cost({ input_tokens = 1000, output_tokens = 500 }, "claude-sonnet-4-6")
      -- sonnet: 3.0/M input + 15.0/M output
      local expected = (1000 * 3.0 + 500 * 15.0) / 1e6
      assert.is_near(expected, cost, 0.000001)
    end)

    it("estimates opus cost", function()
      local cost = streaming._estimate_cost({ input_tokens = 1000, output_tokens = 500 }, "claude-opus-4-6")
      local expected = (1000 * 15.0 + 500 * 75.0) / 1e6
      assert.is_near(expected, cost, 0.000001)
    end)

    it("estimates haiku cost", function()
      local cost = streaming._estimate_cost({ input_tokens = 1000, output_tokens = 500 }, "claude-haiku-3-5")
      local expected = (1000 * 0.25 + 500 * 1.25) / 1e6
      assert.is_near(expected, cost, 0.000001)
    end)

    it("defaults to sonnet for unknown model", function()
      local cost = streaming._estimate_cost({ input_tokens = 1000, output_tokens = 500 }, "unknown-model")
      local expected = (1000 * 3.0 + 500 * 15.0) / 1e6
      assert.is_near(expected, cost, 0.000001)
    end)

    it("returns nil for nil usage", function()
      assert.is_nil(streaming._estimate_cost(nil, "claude-sonnet"))
    end)

    it("handles zero tokens", function()
      local cost = streaming._estimate_cost({ input_tokens = 0, output_tokens = 0 }, "claude-sonnet")
      assert.equals(0, cost)
    end)
  end)
end)
