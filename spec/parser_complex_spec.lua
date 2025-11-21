package.path = "build/?.lua;build/?/init.lua;src/?.lua;src/?/init.lua;" .. package.path

local parser = require("parser.parser")
local Reporter = require("diag.reporter")

local function parse_with_rep(src)
   local rep = Reporter.new()
   local tu = parser.parse(src, 1, rep)
   return tu, rep
end

describe("parser complex declarators", function()
   it("handles nested function pointers returning pointers to arrays", function()
      local tu, rep = parse_with_rep("int (*(*fp1)(double, int (*)(char)))[static 3][4];")
      assert.are.equal(0, #rep.diagnostics, rep.diagnostics[1] and rep.diagnostics[1].message or "")
      local decl = tu.decls[1]
      assert.are.equal("var", decl.kind)

      local ty = decl.type
      assert.are.equal("pointer", ty.tag)
      local fn = ty.to
      assert.are.equal("function", fn.tag)
      assert.are.equal(2, #fn.params)
      assert.are.equal("double", fn.params[1].type.name)

      local p2 = fn.params[2].type
      assert.are.equal("pointer", p2.tag)
      assert.are.equal("function", p2.to.tag)
      assert.are.equal(1, #p2.to.params)
      assert.are.equal("char", p2.to.params[1].type.name)
      assert.are.equal("int", p2.to.returns.name)

      local ret_ptr = fn.returns
      assert.are.equal("pointer", ret_ptr.tag)
      local arr_outer = ret_ptr.to
      assert.are.equal("array", arr_outer.tag)
      assert.is_true(arr_outer.is_static)
      assert.are.equal("3", arr_outer.size_expr.token.lexeme)
      local arr_inner = arr_outer.of
      assert.are.equal("array", arr_inner.tag)
      assert.are.equal("4", arr_inner.size_expr.token.lexeme)
      assert.are.equal("builtin", arr_inner.of.tag)
      assert.are.equal("int", arr_inner.of.name)
   end)

   it("parses multi-dimensional VLA parameters", function()
      local tu, rep = parse_with_rep("void f(int m, int n, double a[m][n]);")
      assert.are.equal(0, #rep.diagnostics, rep.diagnostics[1] and rep.diagnostics[1].message or "")
      local func = tu.decls[1]
      local arr = func.type.params[3].type
      assert.are.equal("array", arr.tag)
      assert.are.equal("identifier", arr.size_expr.kind)
      assert.are.equal("m", arr.size_expr.name.lexeme)
      local inner = arr.of
      assert.are.equal("array", inner.tag)
      assert.are.equal("identifier", inner.size_expr.kind)
      assert.are.equal("n", inner.size_expr.name.lexeme)
      assert.are.equal("builtin", inner.of.tag)
      assert.are.equal("double", inner.of.name)
   end)

   it("skips attributes while keeping declarator shape", function()
      local tu, rep = parse_with_rep("int __attribute__((aligned(16))) *p __asm__(\"_p\");")
      assert.are.equal(0, #rep.diagnostics, rep.diagnostics[1] and rep.diagnostics[1].message or "")
      local decl = tu.decls[1]
      assert.are.equal("var", decl.kind)
      assert.are.equal("pointer", decl.type.tag)
      assert.are.equal("int", decl.type.to.name)
   end)
end)
