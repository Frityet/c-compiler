package.path = "build/?.lua;build/?/init.lua;src/?.lua;src/?/init.lua;" .. package.path

local lexer = require("lexer.lexer")
local Preprocessor = require("pp.preprocessor")
local Reporter = require("diag.reporter")

local function lexemes(tokens)
   local out = {}
   for _, t in ipairs(tokens) do
      if t.kind == lexer.K_EOF then break end
      table.insert(out, t.lexeme)
   end
   return out
end

describe("preprocessor", function()
   it("replaces trigraphs and expands object macros", function()
      local rep = Reporter.new()
      local src = table.concat({
         "??=define X 3",
         "int a = X;",
      }, "\n")
      local pp = Preprocessor.preprocess(src, 1, rep)

      assert.are.equal("int a=3;", pp.text)
      assert.are.equal(0, #rep.diagnostics)
      assert.are.same({ "int", "a", "=", "3", ";" }, lexemes(pp.tokens))
   end)

   it("normalizes newlines and preserves tokens", function()
      local rep = Reporter.new()
      local pp = Preprocessor.preprocess("int a;\r\nint b;\rint c;", 2, rep)

      assert.are.equal("int a;int b;int c;", pp.text)
      assert.is_nil(pp.text:match("\r"))
      assert.are.same({ "int", "a", ";", "int", "b", ";", "int", "c", ";" }, lexemes(pp.tokens))
   end)

   it("reports line splices as a note", function()
      local rep = Reporter.new()
      local pp = Preprocessor.preprocess("int x = 1\\\n+2;", 3, rep)

      assert.are.equal("int x=1+2;", pp.text)
      assert.are.equal(1, #rep.diagnostics)
      local diag = rep.diagnostics[1]
      assert.are.equal("PP001", diag.code)
      assert.are.equal("note", diag.severity)
   end)

   it("expands builtins __FILE__ and __LINE__", function()
      local rep = Reporter.new()
      local cfg = {
         search_paths = {},
         defines = {},
         undefs = {},
         current_dir = ".",
         source_path = "spec/fixtures/main.c",
      }
      local src = 'const char* f = __FILE__;\nint n = __LINE__;\n'
      local pp = Preprocessor.preprocess(src, 10, rep, cfg)
      -- line numbers start at 1, so __LINE__ on second line should be 2
      assert.are.same({ "const", "char", "*", "f", "=", '"spec/fixtures/main.c"', ";", "int", "n", "=", "2", ";", }, lexemes(pp.tokens))
   end)

   it("applies #line to override file and line", function()
      local rep = Reporter.new()
      local src = table.concat({
         '#line 100 "virt.c"',
         "int a = __LINE__;",
         "const char* f = __FILE__;",
      }, "\n")
      local pp = Preprocessor.preprocess(src, 11, rep, { search_paths = {}, defines = {}, undefs = {}, current_dir = ".", source_path = "real.c" })
      assert.are.same({ "int", "a", "=", "100", ";", "const", "char", "*", "f", "=", '"virt.c"', ";" }, lexemes(pp.tokens))
   end)

   it("emits diagnostics for #error", function()
      local rep = Reporter.new()
      local src = "#error fail here\nint x;"
      local pp = Preprocessor.preprocess(src, 12, rep)
      assert.are.equal(1, #rep.diagnostics)
      assert.are.equal("error", rep.diagnostics[1].severity)
      assert.are.equal("PP300", rep.diagnostics[1].code)
      assert.are.same({ "int", "x", ";" }, lexemes(pp.tokens))
   end)

   it("expands function-like macros with parameters", function()
      local rep = Reporter.new()
      local src = table.concat({
         "#define ADD(a,b) ( (a) + (b) )",
         "int y = ADD(1, 2);",
      }, "\n")
      local pp = Preprocessor.preprocess(src, 4, rep)

      assert.are.equal("int y=((1)+(2));", pp.text)
      assert.are.same({ "int", "y", "=", "(", "(", "1", ")", "+", "(", "2", ")", ")", ";" }, lexemes(pp.tokens))
   end)

   it("handles conditional compilation branches", function()
      local rep = Reporter.new()
      local src = table.concat({
         "#if 0",
         "int a;",
         "#else",
         "int b;",
         "#endif",
      }, "\n")
      local pp = Preprocessor.preprocess(src, 5, rep)

      assert.are.same({ "int", "b", ";" }, lexemes(pp.tokens))
   end)

   it("expands includes from search paths", function()
      local rep = Reporter.new()
      local cfg = {
         search_paths = { "spec/fixtures" },
         defines = {},
         undefs = {},
         current_dir = ".",
      }
      local pp = Preprocessor.preprocess('#include "inc1.h"\nint main();', 6, rep, cfg)
      assert.are.equal("int incval;int main();", pp.text)
      assert.are.same({ "int", "incval", ";", "int", "main", "(", ")", ";" }, lexemes(pp.tokens))
   end)

   it("honors #pragma once to prevent duplicate includes", function()
      local rep = Reporter.new()
      local cfg = {
         search_paths = { "spec/fixtures" },
         defines = {},
         undefs = {},
         current_dir = ".",
      }
      local src = '#include "inc_once.h"\n#include "inc_once.h"\nint main();'
      local pp = Preprocessor.preprocess(src, 7, rep, cfg)
      assert.are.same({ "int", "onceval", ";", "int", "main", "(", ")", ";" }, lexemes(pp.tokens))
   end)

   it("supports token pasting and stringizing", function()
      local rep = Reporter.new()
      local src = table.concat({
         "#define CAT(a,b) a##b",
         "#define STR(x) #x",
         "int CAT(my,Var) = 1;",
         "const char* s = STR(hello world);",
      }, "\n")
      local pp = Preprocessor.preprocess(src, 8, rep)

      assert.are.same({ "int", "myVar", "=", "1", ";", "const", "char", "*", "s", "=", "\"hello world\"", ";", }, lexemes(pp.tokens))
   end)

   it("expands variadic macros with __VA_ARGS__", function()
      local rep = Reporter.new()
      local src = table.concat({
         "#define LOG(fmt, ...) fmt __VA_ARGS__",
         "int x = LOG(\"v\", +1);",
      }, "\n")
      local pp = Preprocessor.preprocess(src, 9, rep)
      assert.are.same({ "int", "x", "=", "\"v\"", "+", "1", ";", }, lexemes(pp.tokens))
   end)

   it("treats macros with whitespace before '(' as object-like", function()
      local rep = Reporter.new()
      local src = table.concat({
         "#define OBJ (1 + 2)",
         "int x = OBJ + 3;",
      }, "\n")
      local pp = Preprocessor.preprocess(src, 15, rep)
      assert.are.equal(0, #rep.diagnostics)
      assert.are.same({ "int", "x", "=", "(", "1", "+", "2", ")", "+", "3", ";" }, lexemes(pp.tokens))
   end)

   it("emits diagnostics for #error", function()
      local rep = Reporter.new()
      local src = "#error fail here\nint x;"
      Preprocessor.preprocess(src, 12, rep)
      assert.are.equal(1, #rep.diagnostics)
      assert.are.equal("error", rep.diagnostics[1].severity)
      assert.are.equal("PP300", rep.diagnostics[1].code)
      assert.are.same({ "int", "x", ";" }, lexemes(Preprocessor.preprocess(src, 12, Reporter.new()).tokens))
   end)

   it("reports unterminated conditionals at EOF", function()
      local rep = Reporter.new()
      local src = "#if 1\nint x;"
      Preprocessor.preprocess(src, 13, rep)
      assert.are.equal(1, #rep.diagnostics)
      assert.are.equal("PP400", rep.diagnostics[1].code)
   end)
end)
