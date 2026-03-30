describe("solomon.review", function()
  local review

  before_each(function()
    package.loaded["solomon.review"] = nil
    review = require("solomon.review")
  end)

  after_each(function()
    if review.is_active() then
      review.quit()
    end
  end)

  describe("_parse_hunks", function()
    it("parses a single-file single-hunk diff", function()
      local diff = table.concat({
        "diff --git a/test.lua b/test.lua",
        "index abc1234..def5678 100644",
        "--- a/test.lua",
        "+++ b/test.lua",
        "@@ -1,3 +1,4 @@",
        " line1",
        "-line2",
        "+line2_modified",
        "+line2b",
        " line3",
      }, "\n")

      local hunks = review._parse_hunks(diff)
      assert.equals(1, #hunks)
      assert.equals("test.lua", hunks[1].file)
      assert.equals(1, hunks[1].old_start)
      assert.equals(3, hunks[1].old_count)
      assert.equals(1, hunks[1].new_start)
      assert.equals(4, hunks[1].new_count)
      assert.is_true(#hunks[1].diff_lines > 0)
      assert.is_true(#hunks[1].patch > 0)
    end)

    it("parses multiple hunks in one file", function()
      local diff = table.concat({
        "diff --git a/test.lua b/test.lua",
        "index abc1234..def5678 100644",
        "--- a/test.lua",
        "+++ b/test.lua",
        "@@ -1,3 +1,3 @@",
        " line1",
        "-old",
        "+new",
        " line3",
        "@@ -10,3 +10,3 @@",
        " line10",
        "-old10",
        "+new10",
        " line12",
      }, "\n")

      local hunks = review._parse_hunks(diff)
      assert.equals(2, #hunks)
      assert.equals(1, hunks[1].old_start)
      assert.equals(10, hunks[2].old_start)
    end)

    it("parses multiple files", function()
      local diff = table.concat({
        "diff --git a/a.lua b/a.lua",
        "index 1111..2222 100644",
        "--- a/a.lua",
        "+++ b/a.lua",
        "@@ -1,2 +1,2 @@",
        "-old_a",
        "+new_a",
        " ctx",
        "diff --git a/b.lua b/b.lua",
        "index 3333..4444 100644",
        "--- a/b.lua",
        "+++ b/b.lua",
        "@@ -5,2 +5,2 @@",
        "-old_b",
        "+new_b",
        " ctx",
      }, "\n")

      local hunks = review._parse_hunks(diff)
      assert.equals(2, #hunks)
      assert.equals("a.lua", hunks[1].file)
      assert.equals("b.lua", hunks[2].file)
    end)

    it("returns empty table for empty diff", function()
      local hunks = review._parse_hunks("")
      assert.equals(0, #hunks)
    end)

    it("handles hunk count without comma", function()
      local diff = table.concat({
        "diff --git a/test.lua b/test.lua",
        "index abc..def 100644",
        "--- a/test.lua",
        "+++ b/test.lua",
        "@@ -1 +1 @@",
        "-old",
        "+new",
      }, "\n")

      local hunks = review._parse_hunks(diff)
      assert.equals(1, #hunks)
      assert.equals(1, hunks[1].old_count)
      assert.equals(1, hunks[1].new_count)
    end)

    it("handles mnemonic prefixes (i/ w/ instead of a/ b/)", function()
      local diff = table.concat({
        "diff --git i/test.lua w/test.lua",
        "index abc..def 100644",
        "--- i/test.lua",
        "+++ w/test.lua",
        "@@ -1,2 +1,2 @@",
        "-old",
        "+new",
        " ctx",
      }, "\n")

      local hunks = review._parse_hunks(diff)
      assert.equals(1, #hunks)
      assert.equals("test.lua", hunks[1].file)
    end)
  end)

  describe("_extract_content", function()
    it("separates old and new lines from diff", function()
      local hunk = {
        diff_lines = {
          " context",
          "-removed",
          "+added",
          " more context",
        },
      }

      local old, new = review._extract_content(hunk)
      assert.equals(3, #old)
      assert.equals("context", old[1])
      assert.equals("removed", old[2])
      assert.equals("more context", old[3])

      assert.equals(3, #new)
      assert.equals("context", new[1])
      assert.equals("added", new[2])
      assert.equals("more context", new[3])
    end)

    it("handles additions only", function()
      local hunk = {
        diff_lines = {
          " ctx",
          "+new1",
          "+new2",
          " ctx",
        },
      }

      local old, new = review._extract_content(hunk)
      assert.equals(2, #old)
      assert.equals(4, #new)
    end)

    it("handles deletions only", function()
      local hunk = {
        diff_lines = {
          " ctx",
          "-old1",
          "-old2",
          " ctx",
        },
      }

      local old, new = review._extract_content(hunk)
      assert.equals(4, #old)
      assert.equals(2, #new)
    end)
  end)

  describe("is_active", function()
    it("returns false when not in review", function()
      assert.is_false(review.is_active())
    end)
  end)
end)
