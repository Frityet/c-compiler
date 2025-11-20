package.path = "build/?.lua;build/?/init.lua;src/?.lua;src/?/init.lua;" .. package.path

local parser = require("parser.parser")
local Checker = require("sema.checker")
local Reporter = require("diag.reporter")

local function run_check(src)
   local rep = Reporter.new()
   local tu = parser.parse(src, 1, rep)
   local checked = Checker.check(tu, rep)
   return checked, rep
end

describe("sema checker", function()
   it("allows repeated tentative definitions", function()
      local _, rep = run_check("int x; int x;")
      assert.are.equal(0, #rep.diagnostics)
   end)

   it("detects conflicting variable types", function()
      local _, rep = run_check("int x; double x;")
      assert.are.equal(1, #rep.diagnostics)
      assert.are.equal("SEM002", rep.diagnostics[1].code)
   end)

   it("detects duplicate variable definitions with initializers", function()
      local _, rep = run_check("int x = 1; int x = 2;")
      assert.are.equal(1, #rep.diagnostics)
      assert.are.equal("SEM003", rep.diagnostics[1].code)
   end)

   it("merges tentative then complete definition", function()
      local checked, rep = run_check("int x; int x = 1;")
      assert.are.equal(0, #rep.diagnostics)
      local sym = checked.globals:lookup("x")
      assert.is_not_nil(sym)
      assert.is_true(sym.is_defined)
      assert.is_false(sym.is_tentative)
   end)

   it("detects duplicate function definitions", function()
      local _, rep = run_check("int f() { return 0; } int f() { return 1; }")
      assert.are.equal(1, #rep.diagnostics)
      assert.are.equal("SEM003", rep.diagnostics[1].code)
   end)

   it("flags conflicting function declarations", function()
      local _, rep = run_check("int f(); double f();")
      assert.are.equal(1, #rep.diagnostics)
      assert.are.equal("SEM002", rep.diagnostics[1].code)
   end)

   it("completes tag definitions and errors on redefinition", function()
      local checked, rep = run_check("struct S { int a; } s1; struct S { int b; } s2;")
      assert.are.equal(1, #rep.diagnostics)
      assert.are.equal("SEM004", rep.diagnostics[1].code)
      local tag = checked.globals:lookup("S", "tag")
      assert.is_not_nil(tag)
      assert.is_true(tag.is_defined)
   end)

   it("rejects VLA with static storage", function()
      local _, rep = run_check("int n; static int a[*];")
      assert.are.equal(1, #rep.diagnostics)
      assert.are.equal("SEM010", rep.diagnostics[1].code)
   end)

   it("rejects static array parameters without constant bounds", function()
      local _, rep = run_check("void f(int n, int a[static n]);")
      assert.are.equal(1, #rep.diagnostics)
      assert.are.equal("SEM011", rep.diagnostics[1].code)
   end)

   it("allows static array parameters with constant positive bounds", function()
      local _, rep = run_check("void f(int a[static 3]);")
      assert.are.equal(0, #rep.diagnostics)
   end)

   it("adjusts array parameters to pointers with no diagnostics", function()
      local checked, rep = run_check("void f(int a[3]);")
      assert.are.equal(0, #rep.diagnostics)
      local func = checked.tu.decls[1]
      assert.are.equal("function", func.type.tag)
      assert.are.equal("pointer", func.type.params[1].type.tag)
   end)

   it("rejects restrict qualifier on non-pointer types", function()
      local _, rep = run_check("void f(restrict int x);")
      assert.are.equal(1, #rep.diagnostics)
      assert.are.equal("SEM014", rep.diagnostics[1].code)
   end)

   it("rejects incomplete types in parameters", function()
      local _, rep = run_check("struct S; void f(struct S s);")
      assert.are.equal(1, #rep.diagnostics)
      assert.are.equal("SEM013", rep.diagnostics[1].code)
   end)
end)
