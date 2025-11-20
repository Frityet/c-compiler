package.path = "build/?.lua;build/?/init.lua;src/?.lua;src/?/init.lua;" .. package.path

local parser = require("parser.parser")
local Reporter = require("diag.reporter")

local function parse_with_rep(src)
   local rep = Reporter.new()
   local tu = parser.parse(src, 1, rep)
   return tu, rep
end

describe("parser", function()
   it("parses a simple function definition", function()
      local tu, rep = parse_with_rep("int main() { return 0; }")
      assert.are.equal(0, #rep.diagnostics, rep.diagnostics[1] and rep.diagnostics[1].message or "")
      assert.are.equal(1, #tu.decls)
      local f = tu.decls[1]
      assert.are.equal("func", f.kind)
      assert.are.equal("main", f.declarator.name.lexeme)
      assert.is_not_nil(f.body)
   end)

   it("parses typedefs and uses typedef name as type specifier", function()
      local tu, rep = parse_with_rep("typedef int T; T value;")
      assert.are.equal(0, #rep.diagnostics, rep.diagnostics[1] and rep.diagnostics[1].message or "")
      assert.are.equal(2, #tu.decls)

      local td = tu.decls[1]
      assert.are.equal("typedef", td.kind)
      assert.are.equal("T", td.declarator.name.lexeme)

      local var = tu.decls[2]
      assert.are.equal("var", var.kind)
      assert.are.equal("value", var.declarator.name.lexeme)
      assert.are.equal("typedef", var.type.tag)
      assert.are.equal("T", var.type.name)
   end)

   it("parses pointer and array declarators", function()
      local tu, rep = parse_with_rep("int *p; int arr[3];")
      assert.are.equal(0, #rep.diagnostics, rep.diagnostics[1] and rep.diagnostics[1].message or "")
      assert.are.equal(2, #tu.decls)

      local ptr_decl = tu.decls[1]
      assert.are.equal("pointer", ptr_decl.type.tag)
      assert.are.equal("builtin", ptr_decl.type.to.tag)
      assert.are.equal("int", ptr_decl.type.to.name)

      local arr_decl = tu.decls[2]
      assert.are.equal("array", arr_decl.type.tag)
      assert.is_not_nil(arr_decl.type.size_expr)
      assert.are.equal("3", arr_decl.type.size_expr.token.lexeme)
   end)

   it("parses struct definitions with declarators", function()
      local src = "struct S { int a; char b; } s;";
      local tu, rep = parse_with_rep(src)
      assert.are.equal(0, #rep.diagnostics, rep.diagnostics[1] and rep.diagnostics[1].message or "")
      assert.are.equal(1, #tu.decls)

      local var = tu.decls[1]
      assert.are.equal("struct", var.type.tag)
      assert.are.equal(2, #var.type.fields)
      assert.are.equal("a", var.type.fields[1].name)
      assert.are.equal("b", var.type.fields[2].name)
   end)

   it("parses function parameters and body", function()
      local src = "int add(int a, int b) { return a + b; }"
      local tu, rep = parse_with_rep(src)
      assert.are.equal(0, #rep.diagnostics, rep.diagnostics[1] and rep.diagnostics[1].message or "")
      assert.are.equal(1, #tu.decls)

      local func = tu.decls[1]
      assert.are.equal("func", func.kind)
      assert.are.equal("add", func.declarator.name.lexeme)
      assert.are.equal("function", func.type.tag)
      assert.are.equal(2, #func.type.params)
      assert.are.equal("a", func.type.params[1].name)
      assert.are.equal("b", func.type.params[2].name)
      assert.is_not_nil(func.body)
   end)

   it("parses initializer lists", function()
      local tu, rep = parse_with_rep("int arr[2] = {1, 2};")
      assert.are.equal(0, #rep.diagnostics, rep.diagnostics[1] and rep.diagnostics[1].message or "")
      local var = tu.decls[1]
      assert.are.equal("array", var.type.tag)
      assert.is_not_nil(var.init)
      assert.are.equal("list", var.init.kind)
      assert.are.equal(2, #var.init.entries)
      assert.are.equal("number_literal", var.init.entries[1].value.expr.kind)
      assert.are.equal("1", var.init.entries[1].value.expr.token.lexeme)
   end)

   it("parses for loops with declarations", function()
      local tu, rep = parse_with_rep("int main(){ for (int i = 0; i < 3; ++i) { } }")
      assert.are.equal(0, #rep.diagnostics, rep.diagnostics[1] and rep.diagnostics[1].message or "")
      local func = tu.decls[1]
      local body = func.body
      assert.are.equal("compound", body.kind)
      local stmt = body.items[1]
      assert.are.equal("for", stmt.kind)
      assert.are.equal("decl", stmt.init.kind)
      local loop_decl = stmt.init.decls[1]
      assert.are.equal("i", loop_decl.declarator.name.lexeme)
   end)

   it("parses function pointer declarators", function()
      local tu, rep = parse_with_rep("int (*fp)(int);")
      assert.are.equal(0, #rep.diagnostics, rep.diagnostics[1] and rep.diagnostics[1].message or "")
      local var = tu.decls[1]
      assert.are.equal("pointer", var.type.tag)
      assert.are.equal("function", var.type.to.tag)
      assert.are.equal(1, #var.type.to.params)
   end)

   it("parses enums with explicit and implicit values", function()
      local tu, rep = parse_with_rep("enum E { A = 1, B, C = 5 } e;")
      assert.are.equal(0, #rep.diagnostics, rep.diagnostics[1] and rep.diagnostics[1].message or "")
      assert.are.equal(1, #tu.decls)
      local enum_var = tu.decls[1]
      assert.are.equal("enum", enum_var.type.tag)
      assert.are.equal(3, #enum_var.type.values)
      assert.are.equal("A", enum_var.type.values[1].name)
      assert.are.equal("B", enum_var.type.values[2].name)
      assert.are.equal("C", enum_var.type.values[3].name)
   end)

   it("parses K&R style function definitions", function()
      local src = [[
int add(a, b)
int a;
int b;
{
   return a + b;
}
]]
      local tu, rep = parse_with_rep(src)
      assert.are.equal(0, #rep.diagnostics, rep.diagnostics[1] and rep.diagnostics[1].message or "")
      assert.are.equal(1, #tu.decls)
      local func = tu.decls[1]
      assert.are.equal("func", func.kind)
      assert.are.equal("add", func.declarator.name.lexeme)
      assert.is_not_nil(func.body)
      -- old-style params should have been captured
      assert.is_true(#func.old_param_decls > 0)
   end)

   it("parses tag-only declarations", function()
      local tu, rep = parse_with_rep("struct S;")
      assert.are.equal(0, #rep.diagnostics, rep.diagnostics[1] and rep.diagnostics[1].message or "")
      assert.are.equal(1, #tu.decls)
      local tag = tu.decls[1]
      assert.are.equal("tag", tag.kind)
      assert.are.equal("struct", tag.specifiers.type_spec.tag_kind)
   end)

   it("parses array declarators with mixed qualifier/static order", function()
      local tu, rep = parse_with_rep("int f(int a[const static 5]);")
      assert.are.equal(0, #rep.diagnostics, rep.diagnostics[1] and rep.diagnostics[1].message or "")
      local func = tu.decls[1]
      local params = func.type.params
      assert.are.equal(1, #params)
      local arr = params[1].type
      assert.are.equal("array", arr.tag)
      assert.is_true(arr.is_static)
      assert.are.equal(1, #arr.qualifiers)
      assert.are.equal("const", arr.qualifiers[1])
   end)
end)
