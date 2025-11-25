package.path = "build/?.lua;build/?/init.lua;src/?.lua;src/?/init.lua;" .. package.path

local ffi = require("ffi")
local lexer = require("lexer.lexer")

local function next_non_ws(lex)
   while true do
      local tok = lexer.next_token(lex)
      if tok.kind ~= lexer.K_WHITESPACE and tok.kind ~= lexer.K_COMMENT then
         return tok
      end
   end
end

describe("StringView", function()
   it("exposes a view without copying", function()
      local lex = lexer.new_lexer("hello world", 1)
      local tok = next_non_ws(lex)
      local view = tok:lexeme(lex.src_ptr)

      assert.are.equal("hello", tostring(view))
      assert.are.equal(5, view.len)
      assert.are.equal(lex.src_ptr + tok.start, view.ptr)
      assert.is_true(view == "hello")
      assert.is_true(view == ffi.string(view.ptr, view.len))
      assert.are.equal("hello!", view .. "!")
      assert.are.equal("->hello", "->" .. view)
   end)

   it("compares by contents across views", function()
      local lex = lexer.new_lexer("foo foo", 2)
      local first = next_non_ws(lex)
      local second = next_non_ws(lex)

      local first_view = first:lexeme(lex.src_ptr)
      local second_view = second:lexeme(lex.src_ptr)
      assert.are.equal(tostring(first_view), tostring(second_view))
      assert.are.equal(first_view.len, second_view.len)
      assert.is_not.equal(first_view.ptr, second_view.ptr)

      local other_lex = lexer.new_lexer("foobar", 3)
      local other = next_non_ws(other_lex)
      local other_view = other:lexeme(other_lex.src_ptr)
      assert.is_false(first_view == other_view)
      assert.is_false(first_view == "foo ")
   end)
end)
