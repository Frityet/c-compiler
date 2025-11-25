package.path = "build/?.lua;build/?/init.lua;src/?.lua;src/?/init.lua;" .. package.path

local lexer = require("lexer.lexer")
local ffi = require("ffi")

local function collect_tokens(src, file_id)
   local state = lexer.new_lexer(src, file_id)
   local tokens = {}
   while true do
      local tok = lexer.next_token(state)
      tokens[#tokens + 1] = tok
      if tok.kind == lexer.K_EOF then
         break
      end
   end
   return state, tokens
end

local function view_to_string(v)
   return ffi.string(v.ptr, v.len)
end

describe("lexer", function()
   it("tokenizes a simple function", function()
      local _, tokens = collect_tokens("int main() { return 0; }", 1)
      local kinds = {}
      for _, t in ipairs(tokens) do
         table.insert(kinds, t.kind)
      end
      assert.are.same({
         lexer.K_KEYWORD,
         lexer.K_IDENTIFIER,
         lexer.K_PUNCT,
         lexer.K_PUNCT,
         lexer.K_PUNCT,
         lexer.K_KEYWORD,
         lexer.K_NUMBER,
         lexer.K_PUNCT,
         lexer.K_PUNCT,
         lexer.K_EOF,
      }, kinds)
   end)
end)

describe("lexer wide/string prefixes", function()
   it("lexes wide strings and chars", function()
      local state, tokens = collect_tokens('L"hello" L\'c\'', 2)
      local kinds = {}
      local lexemes = {}
      for _, t in ipairs(tokens) do
         table.insert(kinds, t.kind)
         if t.kind == lexer.K_EOF then break end
         table.insert(lexemes, view_to_string(lexer.lexeme(t, state.src_ptr)))
      end
      assert.are.same({ lexer.K_STRING, lexer.K_CHAR, lexer.K_EOF }, { kinds[1], kinds[2], kinds[#kinds] })
      assert.are.equal('L"hello"', lexemes[1])
      assert.are.equal("L'c'", lexemes[2])
   end)
end)
