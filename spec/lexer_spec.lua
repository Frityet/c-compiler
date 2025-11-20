package.path = "build/?.lua;build/?/init.lua;src/?.lua;src/?/init.lua;" .. package.path

local lexer = require("lexer.lexer")
local Reporter = require("diag.reporter")

describe("lexer", function()
   it("tokenizes a simple function", function()
      local rep = Reporter.new()
      local tokens = lexer.lex("int main() { return 0; }", 1, rep)
      assert.are.equal(0, #rep.diagnostics)
      local kinds = {}
      for _, t in ipairs(tokens) do
         table.insert(kinds, t.kind)
      end
      assert.are.same({
         "keyword",
         "identifier",
         "punctuator",
         "punctuator",
         "punctuator",
         "keyword",
         "number",
         "punctuator",
         "punctuator",
         "eof",
      }, kinds)
   end)
end)

describe("lexer wide/string prefixes", function()
   it("lexes wide strings and chars", function()
      local rep = Reporter.new()
      local tokens = lexer.lex('L"hello" L\'c\'', 2, rep)
      assert.are.equal(0, #rep.diagnostics)
      local kinds = {}
      local lexemes = {}
      for _, t in ipairs(tokens) do
         table.insert(kinds, t.kind)
         table.insert(lexemes, t.lexeme)
         if t.kind == "eof" then break end
      end
      assert.are.same({ "string", "char", "eof" }, { kinds[1], kinds[2], kinds[#kinds] })
      assert.are.equal('L"hello"', lexemes[1])
      assert.are.equal("L'c'", lexemes[2])
   end)
end)
