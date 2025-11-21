package.path = "build/?.lua;build/?/init.lua;src/?.lua;src/?/init.lua;" .. package.path

local Autogen = require("tooling.autogen_ffi")
local Reporter = require("diag.reporter")

describe("autogen_ffi", function()
   local tmpfiles = {}

   after_each(function()
      for _, path in ipairs(tmpfiles) do
         os.remove(path)
      end
      tmpfiles = {}
   end)

   local function tmpname()
      local name = os.tmpname()
      table.insert(tmpfiles, name)
      return name
   end

   it("generates ffi module for a simple header", function()
      local out = tmpname()
      local rep = Reporter.new()
      local err = Autogen.run({
         headers = { "spec/fixtures/autogen/simple.h" },
         output = out,
         lib_name = nil,
         ignore_system_includes = true,
      }, rep)

      assert.is_nil(err)
      assert.is_false(rep:has_errors())

      local fh = assert(io.open(out, "r"))
      local content = assert(fh:read("*a"))
      fh:close()

      assert.matches("ffi%.cdef", content)
      assert.matches("struct Foo", content)
      assert.matches("record Foo", content)
      assert.matches("int foo", content)
      assert.matches("Callback", content)
   end)

   it("keeps functions using enums completed later and ignores late forwards", function()
      local rep = Reporter.new()
      local rendered = Autogen.generate({
         headers = { "spec/fixtures/autogen/enum_forward.h" },
         output = "enum_forward.ffi.tl",
         ignore_system_includes = true,
      }, rep)

      assert.is_not_nil(rendered)
      assert.is_false(rep:has_errors())
      assert.are.same({}, rendered.warnings)

      local content = assert(rendered.content, "expected generated content")
      assert.matches("enum Kind", content)
      assert.matches("struct Later", content)
      assert.matches("enum Kind make_kind", content)
      assert.matches("int get_kind%(", content)
      assert.matches("int use_later%(", content)
   end)
end)
