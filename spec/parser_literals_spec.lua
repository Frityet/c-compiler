package.path = "build/?.lua;build/?/init.lua;src/?.lua;src/?/init.lua;" .. package.path

local parser = require("parser.parser")
local lexer = require("lexer.lexer")
local Reporter = require("diag.reporter")

local function parse_with_rep(src)
   local rep = Reporter.new()
   local lex = lexer.new_lexer(src, 100)
   local function iter()
      return lexer.next_token(lex)
   end
   local tu = parser.parse(lex.src_ptr, iter, rep, { [100] = lex.src_ptr })
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
