describe("solomon.git", function()
  local git

  before_each(function()
    package.loaded["solomon.git"] = nil
    git = require("solomon.git")
  end)

  describe("_git", function()
    it("returns output for successful commands", function()
      local result, err = git._git({ "rev-parse", "--is-inside-work-tree" })
      -- We're running in the solomon repo, so this should work
      assert.is_nil(err)
      assert.equals("true", result)
    end)

    it("returns error for failed commands", function()
      local result, err = git._git({ "log", "--oneline", "-1", "--no-walk", "0000000000000000000000000000000000000000" })
      assert.is_nil(result)
      assert.is_string(err)
    end)
  end)

  describe("is_git_repo", function()
    it("returns true in a git repo", function()
      -- solomon is a git repo
      assert.is_true(git.is_git_repo())
    end)
  end)
end)
