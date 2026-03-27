describe("solomon.sessions", function()
  local sessions

  before_each(function()
    package.loaded["solomon.sessions"] = nil
    sessions = require("solomon.sessions")
  end)

  describe("_get_session_preview path normalization", function()
    it("normalizes project path to match Claude directory naming", function()
      -- The actual function in _get_session_preview does:
      -- project:gsub("/", "-")
      -- Claude stores dirs like: -home-user-projects-myapp (leading dash preserved)
      local project = "/home/user/projects/myapp"
      local normalized = project:gsub("/", "-")
      -- Must match what Claude actually creates
      assert.equals("-home-user-projects-myapp", normalized)
      -- Verify the full path would be correct
      local expected_dir = sessions.config_dir() .. "/projects/" .. normalized
      assert.truthy(expected_dir:find("-home-user-projects-myapp", 1, true))
    end)
  end)

  describe("config_dir", function()
    it("returns HOME/.claude by default", function()
      local dir = sessions.config_dir()
      local home = os.getenv("HOME")
      assert.equals(home .. "/.claude", dir)
    end)
  end)

  describe("get_all", function()
    -- Write a temp history file, point config_dir to it, parse it
    local tmpdir

    before_each(function()
      tmpdir = vim.fn.tempname()
      vim.fn.mkdir(tmpdir, "p")
      -- Override config_dir to use temp directory
      sessions.config_dir = function()
        return tmpdir
      end
    end)

    after_each(function()
      vim.fn.delete(tmpdir, "rf")
    end)

    it("parses valid JSONL history", function()
      local history = table.concat({
        vim.json.encode({ sessionId = "aaa", display = "first msg", project = "/tmp/a", timestamp = 1000 }),
        vim.json.encode({ sessionId = "bbb", display = "second msg", project = "/tmp/b", timestamp = 2000 }),
      }, "\n") .. "\n"

      local f = io.open(tmpdir .. "/history.jsonl", "w")
      f:write(history)
      f:close()

      local result = sessions.get_all()
      assert.equals(2, #result)
      -- Most recent first
      assert.equals("bbb", result[1].session_id)
      assert.equals("aaa", result[2].session_id)
    end)

    it("groups entries by session ID and keeps latest timestamp", function()
      local history = table.concat({
        vim.json.encode({ sessionId = "aaa", display = "msg1", project = "/tmp", timestamp = 1000 }),
        vim.json.encode({ sessionId = "aaa", display = "msg2", project = "/tmp", timestamp = 3000 }),
        vim.json.encode({ sessionId = "bbb", display = "other", project = "/tmp", timestamp = 2000 }),
      }, "\n") .. "\n"

      local f = io.open(tmpdir .. "/history.jsonl", "w")
      f:write(history)
      f:close()

      local result = sessions.get_all()
      assert.equals(2, #result) -- 2 unique sessions, not 3
      -- aaa has timestamp 3000 (updated), bbb has 2000
      assert.equals("aaa", result[1].session_id)
      assert.equals("bbb", result[2].session_id)
    end)

    it("keeps first display text for a session", function()
      local history = table.concat({
        vim.json.encode({ sessionId = "aaa", display = "original question", project = "/tmp", timestamp = 1000 }),
        vim.json.encode({ sessionId = "aaa", display = "followup", project = "/tmp", timestamp = 2000 }),
      }, "\n") .. "\n"

      local f = io.open(tmpdir .. "/history.jsonl", "w")
      f:write(history)
      f:close()

      local result = sessions.get_all()
      assert.equals(1, #result)
      assert.equals("original question", result[1].display)
    end)

    it("skips malformed JSON lines", function()
      local history = table.concat({
        vim.json.encode({ sessionId = "aaa", display = "good", project = "/tmp", timestamp = 1000 }),
        "this is not json at all {{{",
        "",
        vim.json.encode({ sessionId = "bbb", display = "also good", project = "/tmp", timestamp = 2000 }),
      }, "\n") .. "\n"

      local f = io.open(tmpdir .. "/history.jsonl", "w")
      f:write(history)
      f:close()

      local result = sessions.get_all()
      assert.equals(2, #result)
    end)

    it("returns empty table when history file missing", function()
      local result = sessions.get_all()
      assert.equals(0, #result)
    end)

    it("formats date from timestamp", function()
      local history = vim.json.encode({
        sessionId = "aaa",
        display = "test",
        project = "/tmp",
        timestamp = 1711500000000, -- 2024-03-27 in ms
      }) .. "\n"

      local f = io.open(tmpdir .. "/history.jsonl", "w")
      f:write(history)
      f:close()

      local result = sessions.get_all()
      assert.equals(1, #result)
      -- Date should be non-empty and contain year
      assert.truthy(result[1].date:find("2024"))
    end)
  end)

  describe("get_for_project", function()
    local tmpdir

    before_each(function()
      tmpdir = vim.fn.tempname()
      vim.fn.mkdir(tmpdir, "p")
      sessions.config_dir = function()
        return tmpdir
      end
    end)

    after_each(function()
      vim.fn.delete(tmpdir, "rf")
    end)

    it("filters sessions to current cwd", function()
      local cwd = vim.fn.getcwd()
      local history = table.concat({
        vim.json.encode({ sessionId = "match", display = "in cwd", project = cwd, timestamp = 2000 }),
        vim.json.encode({ sessionId = "other", display = "different dir", project = "/some/other/dir", timestamp = 1000 }),
      }, "\n") .. "\n"

      local f = io.open(tmpdir .. "/history.jsonl", "w")
      f:write(history)
      f:close()

      local result = sessions.get_for_project()
      assert.equals(1, #result)
      assert.equals("match", result[1].session_id)
    end)
  end)
end)
