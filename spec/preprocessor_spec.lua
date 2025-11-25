package.path = "build/?.lua;build/?/init.lua;src/?.lua;src/?/init.lua;" .. package.path

local lexer = require("lexer.lexer")
local Preprocessor = require("pp.preprocessor")
local Reporter = require("diag.reporter")

local function collect_tokens(pp)
   local tokens = {}
   while true do
      local tok = pp.next()
      tokens[#tokens + 1] = tok
      if tok.kind == lexer.K_EOF then
         break
      end
   end
   return tokens
end

local function lexemes(pp, tokens)
   local mgr = assert(pp.mgr, "preprocessor did not expose source manager")
   local out = {}
   for _, t in ipairs(tokens) do
      if t.kind == lexer.K_EOF then break end
      out[#out + 1] = Preprocessor.lexeme_to_string(Preprocessor.get_lexeme(mgr, t))
   end
   return out
end

local function render_text(pp, tokens)
   local mgr = assert(pp.mgr, "preprocessor did not expose source manager")
   local out = {}
   local prev = nil

   local function should_insert_space(prev_tok, cur_tok)
      if prev_tok.kind == lexer.K_PUNCT or cur_tok.kind == lexer.K_PUNCT then
         return prev_tok.kind == lexer.K_IDENTIFIER and cur_tok.kind == lexer.K_IDENTIFIER
      end
      return true
   end

   for _, t in ipairs(tokens) do
      if t.kind == lexer.K_EOF then break end
      if prev and should_insert_space(prev, t) then
         out[#out + 1] = " "
      end
      out[#out + 1] = Preprocessor.lexeme_to_string(Preprocessor.get_lexeme(mgr, t))
      prev = t
   end

   return table.concat(out)
end

describe("preprocessor", function()
   it("replaces trigraphs and expands object macros", function()
      local rep = Reporter.new()
      local src = table.concat({
         "??=define X 3",
         "int a = X;",
      }, "\n")
      local pp = Preprocessor.preprocess(src, 1, rep)
      local tokens = collect_tokens(pp)

      assert.are.equal(0, #rep.diagnostics)
      assert.are.equal("int a=3;", render_text(pp, tokens))
      assert.are.same({ "int", "a", "=", "3", ";" }, lexemes(pp, tokens))
   end)

   it("normalizes newlines and preserves tokens", function()
      local rep = Reporter.new()
      local pp = Preprocessor.preprocess("int a;\r\nint b;\rint c;", 2, rep)
      local tokens = collect_tokens(pp)

      assert.are.equal("int a;int b;int c;", render_text(pp, tokens))
      assert.are.same({ "int", "a", ";", "int", "b", ";", "int", "c", ";" }, lexemes(pp, tokens))
   end)

   it("joins line splices", function()
      local rep = Reporter.new()
      local pp = Preprocessor.preprocess("int x = 1\\\n+2;", 3, rep)
      local tokens = collect_tokens(pp)

      assert.are.equal("int x=1+2;", render_text(pp, tokens))
      assert.are.equal(0, #rep.diagnostics)
   end)

   it("expands function-like macros with parameters", function()
      local rep = Reporter.new()
      local src = table.concat({
         "#define ADD(a,b) ( (a) + (b) )",
         "int y = ADD(1, 2);",
      }, "\n")
      local pp = Preprocessor.preprocess(src, 4, rep)
      local tokens = collect_tokens(pp)

      assert.are.same({ "int", "y", "=", "(", "(", "1", ")", "+", "(", "2", ")", ")", ";" }, lexemes(pp, tokens))
   end)

   it("expands includes from provided paths", function()
      local rep = Reporter.new()
      local pp = Preprocessor.preprocess('#include "inc1.h"\nint main();', 6, rep, { search_paths = { "spec/fixtures" } })
      local tokens = collect_tokens(pp)

      assert.are.same({ "int", "incval", ";", "int", "main", "(", ")", ";" }, lexemes(pp, tokens))
   end)

   it("parses include targets containing keywords", function()
      local rep = Reporter.new()
      local pp = Preprocessor.preprocess('#include <bits/long-double.h>\nint main();', 6, rep, { search_paths = { "spec/fixtures" } })
      local tokens = collect_tokens(pp)

      assert.are.same({ "int", "ld_marker", ";", "int", "main", "(", ")", ";" }, lexemes(pp, tokens))
   end)

   it("expands variadic macros with __VA_ARGS__", function()
      local rep = Reporter.new()
      local src = table.concat({
         "#define LOG(fmt, ...) fmt __VA_ARGS__",
         "int x = LOG(\"v\", +1);",
      }, "\n")
      local pp = Preprocessor.preprocess(src, 9, rep)
      local tokens = collect_tokens(pp)

      assert.are.same({ "int", "x", "=", "\"v\"", "+", "1", ";" }, lexemes(pp, tokens))
   end)

   it("treats macros with whitespace before '(' as object-like", function()
      local rep = Reporter.new()
      local src = table.concat({
         "#define OBJ (1 + 2)",
         "int x = OBJ + 3;",
      }, "\n")
      local pp = Preprocessor.preprocess(src, 15, rep)
      local tokens = collect_tokens(pp)

      assert.are.equal(0, #rep.diagnostics)
      assert.are.same({ "int", "x", "=", "(", "1", "+", "2", ")", "+", "3", ";" }, lexemes(pp, tokens))
   end)

   it("supports stringizing and token pasting", function()
      local rep = Reporter.new()
      local src = table.concat({
         "#define CAT(a,b) a##b",
         "#define STR(x) #x",
         "int CAT(my,Var) = 1;",
         "const char* s = STR(hello world);",
      }, "\n")
      local pp = Preprocessor.preprocess(src, 16, rep)
      local tokens = collect_tokens(pp)
      assert.are.same({ "int", "myVar", "=", "1", ";", "const", "char", "*", "s", "=", "\"hello world\"", ";" }, lexemes(pp, tokens))
   end)

   it("removes macros with #undef", function()
      local rep = Reporter.new()
      local src = table.concat({
         "#define TEMP 42",
         "#undef TEMP",
         "int v = TEMP;",
      }, "\n")
      local pp = Preprocessor.preprocess(src, 16, rep)
      local tokens = collect_tokens(pp)
      assert.are.same({ "int", "v", "=", "TEMP", ";" }, lexemes(pp, tokens))
   end)

   it("honors #pragma once to avoid duplicate includes", function()
      local rep = Reporter.new()
      local src = '#include "inc_once.h"\n#include "inc_once.h"\nint main();'
      local pp = Preprocessor.preprocess(src, 17, rep, { search_paths = { "spec/fixtures" } })
      local tokens = collect_tokens(pp)
      assert.are.same({ "int", "onceval", ";", "int", "main", "(", ")", ";" }, lexemes(pp, tokens))
   end)

   it("expands builtins and #line overrides", function()
      local rep = Reporter.new()
      local src = table.concat({
         "int a = __LINE__;",
         "#line 200 \"virt.c\"",
         "const char* f = __FILE__;",
         "int b = __LINE__;",
      }, "\n")
      local pp = Preprocessor.preprocess(src, 18, rep, { source_path = "spec/fixtures/main.c" })
      local toks = collect_tokens(pp)
      local lxs = lexemes(pp, toks)
      assert.are.same({ "int", "a", "=", "1", ";", "const", "char", "*", "f", "=", "\"virt.c\"", ";", "int", "b", "=", "201", ";" }, lxs)
   end)

   it("evaluates conditionals with defined and numeric macros", function()
      local rep = Reporter.new()
      local src = table.concat({
         "#define FOO 0",
         "#define BAR 1",
         "#if defined(FOO) && FOO",
         "int skip;",
         "#elif BAR",
         "int keep;",
         "#else",
         "int nope;",
         "#endif",
      }, "\n")
      local pp = Preprocessor.preprocess(src, 19, rep)
      local tokens = collect_tokens(pp)
      assert.are.same({ "int", "keep", ";", }, lexemes(pp, tokens))
   end)

   it("skips expansions inside inactive branches", function()
      local rep = Reporter.new()
      local src = table.concat({
         "#define INC #include \"inc1.h\"",
         "#if 0",
         "INC",
         "#endif",
         "int x;",
      }, "\n")
      local pp = Preprocessor.preprocess(src, 20, rep, { search_paths = { "spec/fixtures" } })
      local tokens = collect_tokens(pp)
      assert.are.same({ "int", "x", ";" }, lexemes(pp, tokens))
   end)

   it("handles #error diagnostics", function()
      local rep = Reporter.new()
      local src = "#error fail here\nint x;"
      local pp = Preprocessor.preprocess(src, 21, rep)
      local tokens = collect_tokens(pp)
      assert.are.equal(1, #rep.diagnostics)
      assert.are.equal("PP300", rep.diagnostics[1].code)
      assert.are.same({ "int", "x", ";" }, lexemes(pp, tokens))
   end)
end)
