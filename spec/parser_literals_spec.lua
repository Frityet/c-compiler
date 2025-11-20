package.path = "build/?.lua;build/?/init.lua;src/?.lua;src/?/init.lua;" .. package.path

local parser = require("parser.parser")
local Reporter = require("diag.reporter")

local function parse_with_rep(src)
   local rep = Reporter.new()
   local tu = parser.parse(src, 100, rep)
   return tu, rep
end

describe("parser literals", function()
   it("concatenates adjacent string literals", function()
      local tu, rep = parse_with_rep('int x = 0; const char *s = "hello" " " "world";')
      assert.are.equal(0, #rep.diagnostics)
      local decl = tu.decls[2]
      assert.are.equal("var", decl.kind)
      local init = decl.init
      assert.is_not_nil(init)
      assert.are.equal("string_literal", init.expr.kind)
      assert.are.equal(3, #init.expr.parts)
   end)
end)
