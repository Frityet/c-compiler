local ast = require("parser.ast")
local Reporter = require("diag.reporter")
local Diagnostic = require("diag.diagnostics")
local Span = require("util.span")
local token_mod = require("lexer.token")
local scopes = require("sema.scopes")
local symbols = require("sema.symbols")
local types = require("sema.types")
local type_ops_raw = require("sema.type_ops")
local type TypeCtx = type_ops_raw.TypeCtx

local function qualifier_span(ty: types.TypeNode): Span
   return ty.span
end

local type TranslationUnit = ast.TranslationUnit
local type Scope = scopes.Scope
local type Symbol = symbols.Symbol

local record CheckedTranslationUnit
   tu: TranslationUnit
   globals: Scope
   expr_info: {types.ExpressionRef: ExprInfo}
end

local record ExprInfo
   type: types.TypeNode
   is_lvalue: boolean
   is_constant: boolean
   const_value: integer | nil
end

local record SwitchContext
   cases: {integer: boolean}
   has_default: boolean
end

local record Context
   rep: Reporter
   globals: Scope
   scope: Scope
   expr_info: {types.ExpressionRef: ExprInfo}
   allow_incomplete_params: boolean
   current_function: types.FunctionType | nil
   current_function_name: string | nil
   current_function_span: Span | nil
   loop_depth: integer
   switch_stack: {SwitchContext}
   labels_defined: {string: Span}
   labels_used: {string: Span}
end

local function resolve_type(ctx: Context, ty: types.TypeNode, seen?: {string:boolean}): types.TypeNode
   return type_ops_raw.resolve_type(ctx as TypeCtx, ty, seen)
end

local function strip_qualifiers(ty: types.TypeNode): (types.TypeNode, {types.TypeQualifier})
   return type_ops_raw.strip_qualifiers(ty)
end

local function is_void_type(ctx: Context, ty: types.TypeNode): boolean
   return type_ops_raw.is_void_type(ctx as TypeCtx, ty)
end

local function is_integer_type(ctx: Context, ty: types.TypeNode): boolean
   return type_ops_raw.is_integer_type(ctx as TypeCtx, ty)
end

local function is_arithmetic_type(ctx: Context, ty: types.TypeNode): boolean
   return type_ops_raw.is_arithmetic_type(ctx as TypeCtx, ty)
end

local function is_pointer_type(ctx: Context, ty: types.TypeNode): boolean
   return type_ops_raw.is_pointer_type(ctx as TypeCtx, ty)
end

local function is_scalar_type(ctx: Context, ty: types.TypeNode): boolean
   return type_ops_raw.is_scalar_type(ctx as TypeCtx, ty)
end

local function is_incomplete_type(ctx: Context, ty: types.TypeNode): boolean
   return type_ops_raw.is_incomplete_type(ctx as TypeCtx, ty)
end

local function decay_for_value(ctx: Context, ty: types.TypeNode): types.TypeNode
   return type_ops_raw.decay_for_value(ctx as TypeCtx, ty)
end

local function integer_promote(ctx: Context, ty: types.TypeNode): types.TypeNode
   return type_ops_raw.integer_promote(ctx as TypeCtx, ty)
end

local function usual_arithmetic_conversion(ctx: Context, lhs: types.TypeNode, rhs: types.TypeNode): types.TypeNode | nil
   return type_ops_raw.usual_arithmetic_conversion(ctx as TypeCtx, lhs, rhs)
end

local function types_compatible(ctx: Context, lhs: types.TypeNode, rhs: types.TypeNode): boolean
   return type_ops_raw.types_compatible(ctx as TypeCtx, lhs, rhs)
end

local function make_builtin(name: types.BuiltinName, span: Span, is_signed?: boolean): types.BuiltinType
   return type_ops_raw.make_builtin(name, span, is_signed)
end

local function wrap_qualified(base: types.TypeNode, quals: {types.TypeQualifier}): types.TypeNode
   return type_ops_raw.wrap_qualified(base, quals)
end

local function missing_name(rep: Reporter, decl: ast.DeclNode)
   rep:report(Diagnostic.new("error", "missing identifier in declaration", decl.span, "SEM001"))
end

local function has_storage(specs: ast.DeclSpecifiers, name: ast.StorageClass): boolean
   for _, s in ipairs(specs.storage) do
      if s == name then
         return true
      end
   end
   return false
end

local function storage_duration_for(specs: ast.DeclSpecifiers, is_file_scope: boolean): symbols.StorageDuration
   if has_storage(specs, "static") or has_storage(specs, "extern") then
      return "static"
   end
   if is_file_scope then
      return "static"
   end
   return "auto"
end

local function linkage_for(specs: ast.DeclSpecifiers, is_file_scope: boolean): symbols.Linkage
   if has_storage(specs, "static") then
      return "internal"
   end
   if has_storage(specs, "extern") then
      return "external"
   end
   if is_file_scope then
      return "external"
   end
   return "none"
end

local function type_contains_vla(ty: types.TypeNode): boolean
   if ty is types.ArrayType then
      if ty.is_vla then
         return true
      end
      local sz = ty.size_expr
      if sz ~= nil then
         local s: types.ExpressionRef = sz
         if s.kind ~= "number_literal" then
            return true
         end
      end
      return type_contains_vla(ty.of)
   elseif ty is types.PointerType then
      return type_contains_vla(ty.to)
   elseif ty is types.FunctionType then
      if type_contains_vla(ty.returns) then
         return true
      end
      for _, p in ipairs(ty.params) do
         if type_contains_vla(p.type) then
            return true
         end
      end
   elseif ty is types.QualifiedType then
      return type_contains_vla(ty.of)
   elseif ty is types.StructType then
      for _, f in ipairs(ty.fields) do
         if type_contains_vla(f.type) then
            return true
         end
      end
   elseif ty is types.UnionType then
      for _, f in ipairs(ty.fields) do
         if type_contains_vla(f.type) then
            return true
         end
      end
   end
   return false
end

local function record_expr(ctx: Context, expr: types.ExpressionRef, info: ExprInfo)
   ctx.expr_info[expr] = info
end

local function is_const_qualified(ty: types.TypeNode): boolean
   local base = ty
   while base is types.QualifiedType do
      for _, q in ipairs(base.qualifiers) do
         if q == "const" then
            return true
         end
      end
      base = base.of
   end
   return false
end

local function is_modifiable_lvalue(ctx: Context, info: ExprInfo): boolean
   if not info.is_lvalue then
      return false
   end
   local ty = info.type
   if is_const_qualified(ty) then
      return false
   end
   local base, _ = strip_qualifiers(resolve_type(ctx, ty))
   if base is types.ArrayType then
      return false
   end
   if base is types.FunctionType then
      return false
   end
   if is_incomplete_type(ctx, ty) then
      return false
   end
   return true
end

local function sizeof_type(ctx: Context, ty: types.TypeNode): integer | nil
   local resolved = resolve_type(ctx, ty)
   local base, _ = strip_qualifiers(resolved)
   if base is types.BuiltinType then
      if base.name == "bool" or base.name == "char" or base.name == "schar" or base.name == "uchar" then
         return 1
      elseif base.name == "short" or base.name == "ushort" then
         return 2
      elseif base.name == "int" or base.name == "uint" then
         return 4
      elseif base.name == "long" or base.name == "ulong" or base.name == "long_long" or base.name == "ulong_long" then
         return 8
      elseif base.name == "float" then
         return 4
      elseif base.name == "double" then
         return 8
      elseif base.name == "long_double" then
         return 16
      end
   elseif base is types.PointerType then
      return 8
   elseif base is types.ArrayType then
      if base.size then
         local elem = sizeof_type(ctx, base.of)
         if elem then
            return elem * base.size
         end
      end
   end
   return nil
end

local function validate_array_param(ctx: Context, arr: types.ArrayType)
   if arr.is_static then
      local sz = arr.size_expr
      if arr.is_vla or sz == nil then
         ctx.rep:report(Diagnostic.new("error", "static array parameter requires a constant bound", arr.span, "SEM011"))
         return
      end
      if not (sz is ast.NumberLiteralExpr) then
         ctx.rep:report(Diagnostic.new("error", "static array parameter requires a constant bound", arr.span, "SEM011"))
         return
      end
      local num = tonumber(sz.token.lexeme)
      if num is nil or num <= 0 then
         ctx.rep:report(Diagnostic.new("error", "static array parameter bound must be a positive constant", arr.span, "SEM012"))
      end
   end
end

local function validate_incomplete(ctx: Context, ty: types.TypeNode)
   if ctx.allow_incomplete_params then
      return
   end
   if ty is types.StructType or ty is types.UnionType then
      if not ty.complete then
         ctx.rep:report(Diagnostic.new("error", "incomplete type in parameter declaration", ty.span, "SEM013"))
      end
   end
end

local function validate_restrict(ctx: Context, ty: types.TypeNode)
   if ty is types.QualifiedType then
      for _, q in ipairs(ty.qualifiers) do
         if q == "restrict" then
            local inner = ty.of
            if not (inner is types.PointerType) and not (inner is types.ArrayType) then
               ctx.rep:report(Diagnostic.new("error", "'restrict' qualifier requires a pointer type", ty.span, "SEM014"))
            end
         end
      end
      validate_restrict(ctx, ty.of)
   elseif ty is types.PointerType then
      validate_restrict(ctx, ty.to)
   elseif ty is types.ArrayType then
      validate_restrict(ctx, ty.of)
   elseif ty is types.FunctionType then
      validate_restrict(ctx, ty.returns)
      for _, p in ipairs(ty.params) do
         validate_restrict(ctx, p.type)
      end
   end
end

local function adjust_param_type(ty: types.TypeNode): types.TypeNode
   if ty is types.ArrayType then
       return {
         tag = "pointer",
         span = ty.span,
         to = ty.of,
         qualifiers = ty.qualifiers,
      }
   elseif ty is types.FunctionType then
      return {
         tag = "pointer",
         span = ty.span,
         to = ty,
         qualifiers = {},
      }
   elseif ty is types.QualifiedType then
      return {
         tag = "qualified",
         span = ty.span,
         of = adjust_param_type(ty.of),
         qualifiers = ty.qualifiers,
      }
   end
   return ty
end

local function validate_param_type(ctx: Context, ty: types.TypeNode)
   if ty is types.ArrayType then
      validate_array_param(ctx, ty)
      validate_param_type(ctx, ty.of)
   elseif ty is types.PointerType then
      -- Pointers may refer to incomplete types; skip validating the pointee here.
   elseif ty is types.FunctionType then
      validate_param_type(ctx, ty.returns)
      for _, p in ipairs(ty.params) do
         validate_param_type(ctx, p.type)
      end
   elseif ty is types.QualifiedType then
      validate_param_type(ctx, ty.of)
   end
   validate_incomplete(ctx, ty)
end

local function validate_function(ctx: Context, fn: types.FunctionType)
   for _, p in ipairs(fn.params) do
      validate_param_type(ctx, p.type)
      validate_restrict(ctx, p.type)
      local adj = adjust_param_type(p.type)
      p.type = adj
   end
end

local function validate_storage(ctx: Context, ty: types.TypeNode, storage: symbols.StorageDuration)
   if storage == "static" and type_contains_vla(ty) then
      ctx.rep:report(Diagnostic.new("error", "variable length arrays are not permitted with static storage duration", ty.span, "SEM010"))
   end
end

local function report_conflict(ctx: Context, name: string, span: Span, code: string, message: string)
   ctx.rep:report(Diagnostic.new("error", string.format("%s '%s'", message, name), span, code))
end

local consteval = require("sema.consteval")

local function note_enum_constants(ctx: Context, ty: types.EnumType)
   if not ty.complete then
      return
   end
   local value_map: {string: integer | nil} = {}
   for _, ev in ipairs(ty.values) do
      value_map[ev.name] = ev.value
      local sym: Symbol = {
         name = ev.name,
         kind = "enum_const",
         type = ty.underlying,
         storage = nil,
         linkage = "none",
         span = ev.span,
         is_tentative = false,
         is_defined = true,
         enum_value = ev.value,
      }
      ctx.scope:define(sym)
   end
end

local function merge_tag(ctx: Context, ty: types.TypeNode)
   local name: string | nil = nil
   local complete = false
   if ty is types.StructType then
      name = ty.name
      complete = ty.complete
   elseif ty is types.UnionType then
      name = ty.name
      complete = ty.complete
   elseif ty is types.EnumType then
      name = ty.name
      complete = ty.complete
   end

   if not name then
      return
   end

   local existing = ctx.scope:lookup(name, "tag")
   if existing is nil then
      local sym: Symbol = {
         name = name,
         kind = "tag",
         type = ty,
         storage = nil,
         linkage = "none",
         span = qualifier_span(ty),
         is_tentative = not complete,
         is_defined = complete,
         enum_value = nil,
      }
      ctx.scope:define(sym, "tag")
      if ty is types.EnumType then
         note_enum_constants(ctx, ty)
      end
      return
   end

   local existing_sym: Symbol = existing

   if existing_sym.kind ~= "tag" then
      report_conflict(ctx, name, qualifier_span(ty), "SEM004", "conflicting tag for")
      return
   end

   if not types.equals(existing_sym.type, ty) then
      report_conflict(ctx, name, qualifier_span(ty), "SEM004", "conflicting tag definition for")
      return
   end

   if existing_sym.is_defined and complete then
      report_conflict(ctx, name, qualifier_span(ty), "SEM005", "redefinition of tag")
      return
   end

   if complete and not existing_sym.is_defined then
      existing_sym.is_defined = true
      existing_sym.is_tentative = false
      existing_sym.type = ty
      ctx.scope:define(existing_sym, "tag")
      if ty is types.EnumType then
         note_enum_constants(ctx, ty)
      end
   end
end

local function collect_tags(ctx: Context, ty: types.TypeNode, seen?: {types.TypeNode: boolean})
   local visited = seen or {}
   if visited[ty] then
      return
   end
   visited[ty] = true

   if ty is types.StructType or ty is types.UnionType or ty is types.EnumType then
      merge_tag(ctx, ty)
      if ty is types.StructType or ty is types.UnionType then
         for _, f in ipairs(ty.fields) do
            collect_tags(ctx, f.type, visited)
         end
      end
   elseif ty is types.PointerType then
      collect_tags(ctx, ty.to, visited)
   elseif ty is types.ArrayType then
      collect_tags(ctx, ty.of, visited)
   elseif ty is types.FunctionType then
      collect_tags(ctx, ty.returns, visited)
      for _, p in ipairs(ty.params) do
         collect_tags(ctx, p.type, visited)
      end
   elseif ty is types.QualifiedType then
      collect_tags(ctx, ty.of, visited)
   end
end

local check_expr: function(ctx: Context, expr: ast.ExprNode): ExprInfo
local check_stmt: function(ctx: Context, stmt: ast.StmtNode)
local process_decl: function(ctx: Context, decl: ast.DeclNode, is_file_scope: boolean)

local function number_literal_type(tok: token_mod.Token): types.BuiltinType
   local lex = tok.lexeme
   if lex:find("%.") or lex:find("[eE]") then
      return make_builtin("double", tok.span, true)
   end
   return make_builtin("int", tok.span, true)
end

local function find_field(st: types.StructType | types.UnionType, name: string): types.Field | nil
   for _, f in ipairs(st.fields) do
      if f.name == name then
         return f
      end
   end
   return nil
end

local function ensure_object_type(ctx: Context, ty: types.TypeNode, span: Span)
   if is_void_type(ctx, ty) then
      ctx.rep:report(Diagnostic.new("error", "variable has incomplete type 'void'", span, "SEM021"))
      return
   end
   if ty is types.FunctionType then
      ctx.rep:report(Diagnostic.new("error", "function type is not valid for objects", span, "SEM021"))
      return
   end
   if is_incomplete_type(ctx, ty) then
      ctx.rep:report(Diagnostic.new("error", "incomplete type in object declaration", span, "SEM031"))
   end
end

local function define_symbol(ctx: Context, sym: Symbol, namespace?: string)
   local ns = namespace or "object"
   if sym.kind == "tag" then
      ns = "tag"
   elseif sym.kind == "label" then
      ns = "label"
   end
   local existing = ctx.scope:lookup_here(sym.name, ns)
   if existing is nil then
      ctx.scope:define(sym, ns)
      return
   end
   local existing_sym: Symbol = existing

   if existing_sym.kind ~= sym.kind then
      report_conflict(ctx, sym.name, sym.span, "SEM002", "conflicting declaration for")
      return
   end

   if not types_compatible(ctx, existing_sym.type, sym.type) then
      report_conflict(ctx, sym.name, sym.span, "SEM002", "conflicting type for")
      return
   end

   if sym.kind == "typedef" then
      report_conflict(ctx, sym.name, sym.span, "SEM003", "redefinition of")
      return
   end

   if existing_sym.is_defined and sym.is_defined then
      report_conflict(ctx, sym.name, sym.span, "SEM003", "redefinition of")
      return
   end

   local combined_defined = existing_sym.is_defined or sym.is_defined
   local combined_tentative = (existing_sym.is_tentative or sym.is_tentative) and not combined_defined

   existing_sym.is_defined = combined_defined
   existing_sym.is_tentative = combined_tentative
   existing_sym.linkage = sym.linkage
   existing_sym.storage = sym.storage
   existing_sym.span = sym.span
   if sym.enum_value ~= nil then
      existing_sym.enum_value = sym.enum_value
   end
   ctx.scope:define(existing_sym, ns)
end

local function check_binary_arith(ctx: Context, expr: ast.BinaryExpr, lhs: ExprInfo, rhs: ExprInfo): types.TypeNode | nil
   local lty = lhs.type
   local rty = rhs.type
   local res = usual_arithmetic_conversion(ctx, lty, rty)
   if res is nil then
      ctx.rep:report(Diagnostic.new("error", "invalid operands to binary expression", expr.span, "SEM040"))
      return nil
   end
   return res
end

local function check_assignment_compat(ctx: Context, target: types.TypeNode, value: types.TypeNode, span: Span, rhs_info?: ExprInfo)
   local target_res = resolve_type(ctx, target)
   local value_res = resolve_type(ctx, value)
   if target_res is types.PointerType then
      local val_base, _ = strip_qualifiers(value_res)
      if val_base is types.PointerType then
         local target_to = resolve_type(ctx, target_res.to)
         local val_to = resolve_type(ctx, val_base.to)
         if is_void_type(ctx, target_to) or is_void_type(ctx, val_to) or types_compatible(ctx, target_to, val_to) then
            return
         end
      end
      if rhs_info and rhs_info.is_constant and rhs_info.const_value == 0 then
         return
      end
   elseif target_res is types.ArrayType then
      ctx.rep:report(Diagnostic.new("error", "cannot assign to array value", span, "SEM030"))
      return
   elseif is_arithmetic_type(ctx, target_res) and is_arithmetic_type(ctx, value_res) then
      return
   elseif (target_res is types.StructType or target_res is types.UnionType) and (value_res is types.StructType or value_res is types.UnionType) then
      if types.equals(target_res, value_res) then
         return
      end
      ctx.rep:report(Diagnostic.new("error", "incompatible struct/union assignment", span, "SEM030"))
      return
   elseif is_incomplete_type(ctx, target_res) then
      ctx.rep:report(Diagnostic.new("error", "assignment to incomplete type", span, "SEM030"))
      return
   elseif types.equals(target_res, value_res) then
      return
   end
   ctx.rep:report(Diagnostic.new("error", "incompatible types in assignment", span, "SEM030"))
end

check_expr = function(ctx: Context, expr: ast.ExprNode): ExprInfo
   local expr_span = expr.span
   if expr is ast.NumberLiteralExpr then
      local ty = number_literal_type(expr.token)
      local value = tonumber(expr.token.lexeme)
      local intval: integer | nil = nil
      if value then
         intval = math.floor(value)
      end
      local info: ExprInfo = { type = ty, is_lvalue = false, is_constant = true, const_value = intval }
      record_expr(ctx, expr, info)
      return info
   elseif expr is ast.CharLiteralExpr then
      local ty = make_builtin("int", expr.span, true)
      local num = tonumber(expr.token.lexeme)
      local cint: integer | nil = nil
      if num then
         cint = math.floor(num)
      end
      local info: ExprInfo = { type = ty, is_lvalue = false, is_constant = true, const_value = cint }
      record_expr(ctx, expr, info)
      return info
   elseif expr is ast.StringLiteralExpr then
      local len = 0
      if #expr.parts > 0 then
         local tok = expr.parts[1]
         len = math.max(0, #tok.lexeme - 2) + 1
      end
      local char_ty = make_builtin("char", expr.span, true)
      local arr: types.ArrayType = {
         tag = "array",
         span = expr.span,
         of = char_ty,
         size = len,
         size_expr = nil,
         is_vla = false,
         is_static = false,
         qualifiers = { "const" },
      }
      local info: ExprInfo = { type = arr, is_lvalue = true, is_constant = false, const_value = nil }
      record_expr(ctx, expr, info)
      return info
   elseif expr is ast.IdentifierExpr then
      local name = expr.name.lexeme
      local sym = ctx.scope:lookup(name)
      if sym is nil then
         ctx.rep:report(Diagnostic.new("error", string.format("use of undeclared identifier '%s'", name), expr.span, "SEM020"))
         local ty = make_builtin("int", expr.span, true)
         local info: ExprInfo = { type = ty, is_lvalue = false, is_constant = false, const_value = nil }
         record_expr(ctx, expr, info)
         return info
      end
      if sym.kind == "enum_const" then
         local val = sym.enum_value
         local info: ExprInfo = { type = sym.type, is_lvalue = false, is_constant = true, const_value = val }
         record_expr(ctx, expr, info)
         return info
      elseif sym.kind == "typedef" then
         ctx.rep:report(Diagnostic.new("error", string.format("typedef name '%s' used as value", name), expr.span, "SEM020"))
         local info: ExprInfo = { type = sym.type, is_lvalue = false, is_constant = false, const_value = nil }
         record_expr(ctx, expr, info)
         return info
      end
      local ty = resolve_type(ctx, sym.type)
      local base, _ = strip_qualifiers(ty)
      local is_lv = true
      if base is types.FunctionType then
         is_lv = false
      end
      if base is types.ArrayType then
         is_lv = false
      end
      local info: ExprInfo = { type = ty, is_lvalue = is_lv, is_constant = false, const_value = nil }
      record_expr(ctx, expr, info)
      return info
   elseif expr is ast.UnaryExpr then
      local operand = check_expr(ctx, expr.operand)
      local op = expr.op.lexeme
      local op_type = operand.type
      if op == "&" then
         local resolved_op = resolve_type(ctx, op_type)
         if not operand.is_lvalue and not (resolved_op is types.FunctionType) then
            ctx.rep:report(Diagnostic.new("error", "operand of '&' must be an lvalue", expr.span, "SEM040"))
         end
         local ptr: types.TypeNode = {
            tag = "pointer",
            span = expr.span,
            to = op_type,
            qualifiers = {},
         }
         local info: ExprInfo = { type = ptr, is_lvalue = false, is_constant = false, const_value = nil }
         record_expr(ctx, expr, info)
         return info
      elseif op == "*" then
         local decayed = decay_for_value(ctx, op_type)
         local base, _ = strip_qualifiers(decayed)
         if not (base is types.PointerType) then
            ctx.rep:report(Diagnostic.new("error", "cannot dereference non-pointer type", expr.span, "SEM040"))
            local info: ExprInfo = { type = base, is_lvalue = true, is_constant = false, const_value = nil }
            record_expr(ctx, expr, info)
            return info
         end
         local result_ty = base.to
         local info: ExprInfo = { type = result_ty, is_lvalue = true, is_constant = false, const_value = nil }
         record_expr(ctx, expr, info)
         return info
      elseif op == "+" or op == "-" or op == "~" then
         if not is_arithmetic_type(ctx, op_type) then
            ctx.rep:report(Diagnostic.new("error", "arithmetic unary operator on non-arithmetic type", expr.span, "SEM040"))
         end
         local promoted = integer_promote(ctx, op_type)
         local info: ExprInfo = { type = promoted, is_lvalue = false, is_constant = operand.is_constant, const_value = consteval.unary(op, operand.const_value) }
         record_expr(ctx, expr, info)
         return info
      elseif op == "!" then
         if not is_scalar_type(ctx, op_type) then
            ctx.rep:report(Diagnostic.new("error", "logical not on non-scalar type", expr.span, "SEM040"))
         end
         local ty = make_builtin("int", expr.span, true)
         local info: ExprInfo = { type = ty, is_lvalue = false, is_constant = operand.is_constant, const_value = consteval.unary(op, operand.const_value) }
         record_expr(ctx, expr, info)
         return info
      elseif op == "++" or op == "--" then
         if not is_modifiable_lvalue(ctx, operand) then
            ctx.rep:report(Diagnostic.new("error", "operand of increment or decrement must be modifiable lvalue", expr.span, "SEM040"))
         end
         local info: ExprInfo = { type = operand.type, is_lvalue = false, is_constant = false, const_value = nil }
         record_expr(ctx, expr, info)
         return info
      end
   elseif expr is ast.BinaryExpr then
      local lhs = check_expr(ctx, expr.lhs)
      local rhs = check_expr(ctx, expr.rhs)
      local op = expr.op.lexeme
      if op == "+" or op == "-" then
         local ldecay = decay_for_value(ctx, lhs.type)
         local rdecay = decay_for_value(ctx, rhs.type)
         local lbase, _ = strip_qualifiers(ldecay)
         local rbase, _ = strip_qualifiers(rdecay)
         if lbase is types.PointerType and is_integer_type(ctx, rdecay) then
            local info: ExprInfo = { type = lbase, is_lvalue = false, is_constant = false, const_value = nil }
            record_expr(ctx, expr, info)
            return info
         elseif rbase is types.PointerType and is_integer_type(ctx, ldecay) and op == "+" then
            local info: ExprInfo = { type = rbase, is_lvalue = false, is_constant = false, const_value = nil }
            record_expr(ctx, expr, info)
            return info
         elseif lbase is types.PointerType and rbase is types.PointerType and op == "-" then
            local ty = make_builtin("long", expr.span, true)
            local info: ExprInfo = { type = ty, is_lvalue = false, is_constant = false, const_value = nil }
            record_expr(ctx, expr, info)
            return info
         else
            local res = check_binary_arith(ctx, expr, lhs, rhs)
            local final_ty = (res or lhs.type) as types.TypeNode
            local const_val = consteval.binary(op, lhs.const_value, rhs.const_value)
            local info: ExprInfo = { type = final_ty, is_lvalue = false, is_constant = lhs.is_constant and rhs.is_constant, const_value = const_val }
            record_expr(ctx, expr, info)
            return info
         end
      elseif op == "*" or op == "/" or op == "%" or op == "|" or op == "&" or op == "^" then
         if (op == "%" or op == "|" or op == "&" or op == "^") and (not is_integer_type(ctx, lhs.type) or not is_integer_type(ctx, rhs.type)) then
            ctx.rep:report(Diagnostic.new("error", "integer operands required", expr.span, "SEM040"))
         end
         if (op == "/" or op == "%") and rhs.is_constant and rhs.const_value == 0 then
            ctx.rep:report(Diagnostic.new("error", "division or modulo by zero", expr.span, "SEM042"))
         end
         local res = check_binary_arith(ctx, expr, lhs, rhs)
         local final_ty = (res or lhs.type) as types.TypeNode
         local const_val = consteval.binary(op, lhs.const_value, rhs.const_value)
         local info: ExprInfo = { type = final_ty, is_lvalue = false, is_constant = lhs.is_constant and rhs.is_constant, const_value = const_val }
         record_expr(ctx, expr, info)
         return info
      elseif op == "<<" or op == ">>" then
         if not is_integer_type(ctx, lhs.type) or not is_integer_type(ctx, rhs.type) then
            ctx.rep:report(Diagnostic.new("error", "shift operators require integer operands", expr.span, "SEM040"))
         end
         if rhs.is_constant and rhs.const_value ~= nil then
            if rhs.const_value < 0 then
               ctx.rep:report(Diagnostic.new("error", "shift count must be non-negative", expr.span, "SEM041"))
            elseif rhs.const_value >= 64 then
               ctx.rep:report(Diagnostic.new("error", "shift count too large", expr.span, "SEM041"))
            end
         end
         local res_ty = integer_promote(ctx, lhs.type)
         local const_val = consteval.binary(op, lhs.const_value, rhs.const_value)
         local info: ExprInfo = { type = res_ty, is_lvalue = false, is_constant = lhs.is_constant and rhs.is_constant, const_value = const_val }
         record_expr(ctx, expr, info)
         return info
      elseif op == "==" or op == "!=" or op == "<" or op == ">" or op == "<=" or op == ">=" then
         local ldecay = decay_for_value(ctx, lhs.type)
         local rdecay = decay_for_value(ctx, rhs.type)
         if not is_scalar_type(ctx, ldecay) or not is_scalar_type(ctx, rdecay) then
            ctx.rep:report(Diagnostic.new("error", "comparison requires scalar operands", expr.span, "SEM040"))
         end
        local ty = make_builtin("int", expr.span, true)
         local const_val = consteval.binary(op, lhs.const_value, rhs.const_value)
         local info: ExprInfo = { type = ty, is_lvalue = false, is_constant = lhs.is_constant and rhs.is_constant, const_value = const_val }
         record_expr(ctx, expr, info)
         return info
      elseif op == "&&" or op == "||" then
         if not is_scalar_type(ctx, lhs.type) or not is_scalar_type(ctx, rhs.type) then
            ctx.rep:report(Diagnostic.new("error", "logical operators require scalar operands", expr.span, "SEM040"))
         end
         local ty = make_builtin("int", expr.span, true)
         local const_val = consteval.binary(op, lhs.const_value, rhs.const_value)
         local info: ExprInfo = { type = ty, is_lvalue = false, is_constant = lhs.is_constant and rhs.is_constant, const_value = const_val }
         record_expr(ctx, expr, info)
         return info
      end
   elseif expr is ast.AssignmentExpr then
      local lhs = check_expr(ctx, expr.lhs)
      local rhs = check_expr(ctx, expr.rhs)
      if not is_modifiable_lvalue(ctx, lhs) then
         ctx.rep:report(Diagnostic.new("error", "left operand of assignment must be modifiable lvalue", expr.span, "SEM016"))
      end
      check_assignment_compat(ctx, lhs.type, rhs.type, expr.span, rhs)
      local info: ExprInfo = { type = lhs.type, is_lvalue = false, is_constant = false, const_value = nil }
      record_expr(ctx, expr, info)
      return info
   elseif expr is ast.ConditionalExpr then
      local cond = check_expr(ctx, expr.cond)
      if not is_scalar_type(ctx, cond.type) then
         ctx.rep:report(Diagnostic.new("error", "conditional requires scalar condition", expr.span, "SEM020"))
      end
      local texpr = check_expr(ctx, expr.then_expr)
      local eexpr = check_expr(ctx, expr.else_expr)
      local res_ty = usual_arithmetic_conversion(ctx, texpr.type, eexpr.type)
      local final_ty = (res_ty or texpr.type) as types.TypeNode
      local const_val: integer | nil = nil
      if cond.is_constant and cond.const_value ~= nil then
         const_val = (cond.const_value ~= 0 and texpr.const_value) or eexpr.const_value
      elseif texpr.is_constant and eexpr.is_constant and texpr.const_value ~= nil and eexpr.const_value ~= nil then
         -- if both constant but condition not, keep nil to avoid wrong branch choice
         const_val = nil
      end
      local info: ExprInfo = { type = final_ty, is_lvalue = false, is_constant = texpr.is_constant and eexpr.is_constant, const_value = const_val }
      record_expr(ctx, expr, info)
      return info
   elseif expr is ast.CallExpr then
      local callee = check_expr(ctx, expr.callee)
      local cty = decay_for_value(ctx, callee.type)
      local base, _ = strip_qualifiers(cty)
      if not (base is types.PointerType) then
         ctx.rep:report(Diagnostic.new("error", "called object is not a function", expr.span, "SEM028"))
         local info: ExprInfo = { type = callee.type, is_lvalue = false, is_constant = false, const_value = nil }
         record_expr(ctx, expr, info)
         return info
      end
      local target = base.to
      if not (target is types.FunctionType) then
         ctx.rep:report(Diagnostic.new("error", "called object is not a function", expr.span, "SEM028"))
         local info: ExprInfo = { type = callee.type, is_lvalue = false, is_constant = false, const_value = nil }
         record_expr(ctx, expr, info)
         return info
      end
      local fn: types.FunctionType = target
      if not fn.is_variadic and #expr.args ~= #fn.params then
         ctx.rep:report(Diagnostic.new("error", "incorrect number of arguments", expr.span, "SEM028"))
      elseif fn.is_variadic and #expr.args < #fn.params then
         ctx.rep:report(Diagnostic.new("error", "not enough arguments for variadic function", expr.span, "SEM028"))
      end
      for idx, arg_expr in ipairs(expr.args) do
         local ai = check_expr(ctx, arg_expr)
         local param = fn.params[idx]
         if param then
            check_assignment_compat(ctx, param.type, ai.type, arg_expr.span, ai)
         end
      end
      local info: ExprInfo = { type = fn.returns, is_lvalue = false, is_constant = false, const_value = nil }
      record_expr(ctx, expr, info)
      return info
   elseif expr is ast.IndexExpr then
      local arr = check_expr(ctx, expr.array)
      local idx = check_expr(ctx, expr.index)
      if not is_integer_type(ctx, idx.type) then
         ctx.rep:report(Diagnostic.new("error", "array index is not integer", expr.span, "SEM040"))
      end
      local arr_ty = decay_for_value(ctx, arr.type)
      local base, _ = strip_qualifiers(arr_ty)
      if base is types.PointerType then
         local info: ExprInfo = { type = base.to, is_lvalue = true, is_constant = false, const_value = nil }
         record_expr(ctx, expr, info)
         return info
      end
      ctx.rep:report(Diagnostic.new("error", "subscripted value is not an array or pointer", expr.span, "SEM040"))
      local info: ExprInfo = { type = arr_ty, is_lvalue = false, is_constant = false, const_value = nil }
      record_expr(ctx, expr, info)
      return info
   elseif expr is ast.FieldExpr then
      local recv = check_expr(ctx, expr.receiver)
      local recv_ty = recv.type
      if expr.is_arrow then
         local ptr_ty = decay_for_value(ctx, recv_ty)
         local base, _ = strip_qualifiers(ptr_ty)
         if base is types.PointerType then
            recv_ty = base.to
         else
            ctx.rep:report(Diagnostic.new("error", "arrow operator requires pointer operand", expr.span, "SEM027"))
         end
      end
      local resolved = resolve_type(ctx, recv_ty)
      local base, quals = strip_qualifiers(resolved)
      if not (base is types.StructType) and not (base is types.UnionType) then
         ctx.rep:report(Diagnostic.new("error", "member access on non-aggregate type", expr.span, "SEM027"))
         local info: ExprInfo = { type = resolved, is_lvalue = false, is_constant = false, const_value = nil }
         record_expr(ctx, expr, info)
         return info
      end
      local field = find_field(base, expr.field.lexeme)
      if field is nil then
         ctx.rep:report(Diagnostic.new("error", "no such field in struct/union", expr.span, "SEM027"))
         local info: ExprInfo = { type = resolved, is_lvalue = false, is_constant = false, const_value = nil }
         record_expr(ctx, expr, info)
         return info
      end
      local fty = wrap_qualified(field.type, quals)
      local info: ExprInfo = { type = fty, is_lvalue = true, is_constant = false, const_value = nil }
      record_expr(ctx, expr, info)
      return info
   elseif expr is ast.CastExpr then
      local target_ty = resolve_type(ctx, expr.type_name.type)
      local val_info = check_expr(ctx, expr.value)
      if is_void_type(ctx, target_ty) then
         -- ok, result is void
      elseif is_arithmetic_type(ctx, target_ty) and is_scalar_type(ctx, val_info.type) then
         -- ok
      elseif is_pointer_type(ctx, target_ty) then
         -- allow casts between pointers and integers
      else
         ctx.rep:report(Diagnostic.new("error", "invalid cast target type", expr.span, "SEM029"))
      end
      local info: ExprInfo = { type = target_ty, is_lvalue = false, is_constant = false, const_value = nil }
      record_expr(ctx, expr, info)
      return info
   elseif expr is ast.SizeofExpr then
      local ty: types.TypeNode
      if expr.type_name ~= nil then
         local tn = expr.type_name as ast.TypeName
         ty = tn.type
      elseif expr.expr ~= nil then
         local inner = check_expr(ctx, expr.expr as ast.ExprNode)
         ty = inner.type
      else
         ty = make_builtin("int", expr.span, true)
      end
      local sz = sizeof_type(ctx, ty)
      local info: ExprInfo = { type = make_builtin("ulong", expr.span, false), is_lvalue = false, is_constant = true, const_value = sz }
      record_expr(ctx, expr, info)
      return info
   elseif expr is ast.CompoundLiteralExpr then
      local ty = resolve_type(ctx, expr.type_name.type)
      local info: ExprInfo = { type = ty, is_lvalue = true, is_constant = false, const_value = nil }
      record_expr(ctx, expr, info)
      return info
   end

   local fallback = make_builtin("int", expr_span, true)
   local info: ExprInfo = { type = fallback, is_lvalue = false, is_constant = false, const_value = nil }
   record_expr(ctx, expr, info)
   return info
end

local function check_initializer(ctx: Context, target_ty: types.TypeNode, init: ast.Initializer)
   if init is ast.ExpressionInitializer then
      local info = check_expr(ctx, init.expr)
      check_assignment_compat(ctx, target_ty, info.type, init.span, info)
   else
      ctx.rep:report(Diagnostic.new("error", "initializer lists are not supported yet", init.span, "SEM030"))
   end
end

check_stmt = function(ctx: Context, stmt: ast.StmtNode)
   if stmt is ast.DeclStmt then
      for _, d in ipairs(stmt.decls) do
         local is_global = ctx.scope == ctx.globals
         local prev_scope = ctx.scope
         process_decl(ctx, d, is_global)
         ctx.scope = prev_scope
      end
   elseif stmt is ast.ExprStmt then
      check_expr(ctx, stmt.expr)
   elseif stmt is ast.NullStmt then
      -- nothing
   elseif stmt is ast.CompoundStmt then
      local parent = ctx.scope
      ctx.scope = scopes.Scope.new(parent)
      for _, s in ipairs(stmt.items) do
         check_stmt(ctx, s)
      end
      ctx.scope = parent
   elseif stmt is ast.IfStmt then
      local cond = check_expr(ctx, stmt.cond)
      if not is_scalar_type(ctx, cond.type) then
         ctx.rep:report(Diagnostic.new("error", "if condition must be scalar", stmt.cond.span, "SEM020"))
      end
      check_stmt(ctx, stmt.then_branch)
      if stmt.else_branch ~= nil then
         check_stmt(ctx, stmt.else_branch as ast.StmtNode)
      end
   elseif stmt is ast.WhileStmt then
      local cond = check_expr(ctx, stmt.cond)
      if not is_scalar_type(ctx, cond.type) then
         ctx.rep:report(Diagnostic.new("error", "while condition must be scalar", stmt.cond.span, "SEM020"))
      end
      ctx.loop_depth = ctx.loop_depth + 1
      check_stmt(ctx, stmt.body)
      ctx.loop_depth = ctx.loop_depth - 1
   elseif stmt is ast.DoWhileStmt then
      ctx.loop_depth = ctx.loop_depth + 1
      check_stmt(ctx, stmt.body)
      ctx.loop_depth = ctx.loop_depth - 1
      local cond = check_expr(ctx, stmt.cond)
      if not is_scalar_type(ctx, cond.type) then
         ctx.rep:report(Diagnostic.new("error", "do-while condition must be scalar", stmt.cond.span, "SEM020"))
      end
   elseif stmt is ast.ForStmt then
      local parent = ctx.scope
      ctx.scope = scopes.Scope.new(parent)
      if stmt.init ~= nil then
         check_stmt(ctx, stmt.init as ast.StmtNode)
      end
      if stmt.cond ~= nil then
         local cond_expr = stmt.cond as ast.ExprNode
         local cond = check_expr(ctx, cond_expr)
         if not is_scalar_type(ctx, cond.type) then
            ctx.rep:report(Diagnostic.new("error", "for condition must be scalar", cond_expr.span, "SEM020"))
         end
      end
      ctx.loop_depth = ctx.loop_depth + 1
      check_stmt(ctx, stmt.body)
      ctx.loop_depth = ctx.loop_depth - 1
      if stmt.step ~= nil then
         check_expr(ctx, stmt.step as ast.ExprNode)
      end
      ctx.scope = parent
   elseif stmt is ast.SwitchStmt then
      local cond = check_expr(ctx, stmt.expr)
      if not is_integer_type(ctx, cond.type) then
         ctx.rep:report(Diagnostic.new("error", "switch controlling expression must be integer", stmt.expr.span, "SEM040"))
      end
      table.insert(ctx.switch_stack, { cases = {}, has_default = false })
      check_stmt(ctx, stmt.body)
      ctx.switch_stack[#ctx.switch_stack] = nil
   elseif stmt is ast.CaseStmt then
      if #ctx.switch_stack == 0 then
         ctx.rep:report(Diagnostic.new("error", "case label not in switch statement", stmt.span, "SEM024"))
      end
      local expr_info = check_expr(ctx, stmt.expr)
      if not expr_info.is_constant or expr_info.const_value == nil then
         ctx.rep:report(Diagnostic.new("error", "case label must be an integer constant expression", stmt.expr.span, "SEM025"))
      else
         local current = ctx.switch_stack[#ctx.switch_stack]
         if current then
            local val = expr_info.const_value as integer
            if current.cases[val] then
               ctx.rep:report(Diagnostic.new("error", "duplicate case value", stmt.expr.span, "SEM026"))
            else
               current.cases[val] = true
            end
         end
      end
      check_stmt(ctx, stmt.body)
   elseif stmt is ast.DefaultStmt then
      if #ctx.switch_stack == 0 then
         ctx.rep:report(Diagnostic.new("error", "default label not in switch statement", stmt.span, "SEM024"))
      else
         local current = ctx.switch_stack[#ctx.switch_stack]
         if current.has_default then
            ctx.rep:report(Diagnostic.new("error", "duplicate default label", stmt.span, "SEM026"))
         else
            current.has_default = true
         end
      end
      check_stmt(ctx, stmt.body)
   elseif stmt is ast.ReturnStmt then
      if ctx.current_function == nil then
         ctx.rep:report(Diagnostic.new("error", "return statement not allowed here", stmt.span, "SEM019"))
         return
      end
      local fn = ctx.current_function as types.FunctionType
      local ret_ty = fn.returns
      if stmt.value == nil then
         if not is_void_type(ctx, ret_ty) then
            ctx.rep:report(Diagnostic.new("error", "non-void function should return a value", stmt.span, "SEM019"))
         end
         return
      end
      local value_expr = stmt.value as ast.ExprNode
      local val_info = check_expr(ctx, value_expr)
      if is_void_type(ctx, ret_ty) then
         ctx.rep:report(Diagnostic.new("error", "void function should not return a value", value_expr.span, "SEM019"))
      else
         check_assignment_compat(ctx, ret_ty, val_info.type, value_expr.span, val_info)
      end
   elseif stmt is ast.BreakStmt then
      if ctx.loop_depth == 0 and #ctx.switch_stack == 0 then
         ctx.rep:report(Diagnostic.new("error", "break statement not within loop or switch", stmt.span, "SEM021"))
      end
   elseif stmt is ast.ContinueStmt then
      if ctx.loop_depth == 0 then
         ctx.rep:report(Diagnostic.new("error", "continue statement not within a loop", stmt.span, "SEM021"))
      end
   elseif stmt is ast.GotoStmt then
      ctx.labels_used[stmt.name.lexeme] = stmt.span
   elseif stmt is ast.LabelStmt then
      local nm = stmt.name.lexeme
      if ctx.labels_defined[nm] then
         ctx.rep:report(Diagnostic.new("error", "duplicate label", stmt.span, "SEM023"))
      else
         ctx.labels_defined[nm] = stmt.span
      end
      check_stmt(ctx, stmt.body)
   end
end

process_decl = function(ctx: Context, decl: ast.DeclNode, is_file_scope: boolean)
   if decl is ast.VarDecl then
      local name_tok = decl.declarator.name
      if name_tok is nil then
         missing_name(ctx.rep, decl)
         return
      end
      collect_tags(ctx, decl.type, nil)
      local specs = decl.specifiers
      local linkage = linkage_for(specs, is_file_scope)
      local storage = storage_duration_for(specs, is_file_scope)
      local is_def: boolean
      if is_file_scope then
         if has_storage(specs, "extern") then
            is_def = decl.init ~= nil
         elseif has_storage(specs, "static") then
            is_def = true
         else
            is_def = decl.init ~= nil
         end
      else
         is_def = true
      end
      validate_storage(ctx, decl.type, storage)
      ensure_object_type(ctx, decl.type, decl.span)
      if not has_storage(specs, "extern") and is_incomplete_type(ctx, decl.type) then
         ctx.rep:report(Diagnostic.new("error", "incomplete type in definition", decl.span, "SEM031"))
      end
      local sym: Symbol = {
         name = name_tok.lexeme,
         kind = "object",
         type = decl.type,
         storage = storage,
         linkage = linkage,
         span = decl.span,
         is_tentative = is_file_scope and not is_def and not has_storage(specs, "extern"),
         is_defined = is_def,
         enum_value = nil,
      }
      define_symbol(ctx, sym)
      if decl.init ~= nil then
         check_initializer(ctx, decl.type, decl.init as ast.Initializer)
      end
   elseif decl is ast.FuncDecl then
      local name_tok = decl.declarator.name
      if name_tok is nil then
         missing_name(ctx.rep, decl)
         return
      end
      collect_tags(ctx, decl.type, nil)

      local specs = decl.specifiers
      local linkage = linkage_for(specs, is_file_scope)
      local fn_ty_node = decl.type
      local fn_type: types.FunctionType | nil = nil
      if fn_ty_node is types.FunctionType then
         validate_function(ctx, fn_ty_node)
         fn_type = fn_ty_node
      end
      local sym: Symbol = {
         name = name_tok.lexeme,
         kind = "function",
         type = decl.type,
         storage = has_storage(specs, "static") and "static" or nil,
         linkage = linkage,
         span = decl.span,
         is_tentative = false,
         is_defined = decl.body ~= nil,
         enum_value = nil,
      }
      define_symbol(ctx, sym)
      if decl.body ~= nil and not (fn_type is nil) then
         local saved_scope = ctx.scope
         local fn_scope = scopes.Scope.new(ctx.globals)
         ctx.scope = fn_scope
         local fn = fn_type as types.FunctionType
         ctx.current_function = fn
         ctx.current_function_name = sym.name
         ctx.current_function_span = decl.span
         ctx.labels_defined = {}
         ctx.labels_used = {}
         ctx.loop_depth = 0
         ctx.switch_stack = {}

         local param_names: {string:boolean} = {}
         local params = fn.params
         for _, p in ipairs(params) do
            local pname = p.name
            if pname then
               if param_names[pname] then
                  ctx.rep:report(Diagnostic.new("error", "duplicate parameter name", p.span, "SEM002"))
               end
               param_names[pname] = true
               local psym: Symbol = {
                  name = pname,
                  kind = "object",
                  type = p.type,
                  storage = "auto",
                  linkage = "none",
                  span = p.span,
                  is_tentative = false,
                  is_defined = true,
                  enum_value = nil,
               }
               define_symbol(ctx, psym)
            end
         end

         check_stmt(ctx, decl.body as ast.StmtNode)

         for label, span in pairs(ctx.labels_used) do
            if not ctx.labels_defined[label] then
               ctx.rep:report(Diagnostic.new("error", string.format("use of undeclared label '%s'", label), span, "SEM022"))
            end
         end

         ctx.scope = saved_scope
         ctx.current_function = nil
         ctx.current_function_name = nil
         ctx.current_function_span = nil
      end
   elseif decl is ast.TypedefDecl then
      local name_tok = decl.declarator.name
      if name_tok is nil then
         missing_name(ctx.rep, decl)
         return
      end
      collect_tags(ctx, decl.type, nil)

      local sym: Symbol = {
         name = name_tok.lexeme,
         kind = "typedef",
         type = decl.type,
         storage = nil,
         linkage = "none",
         span = decl.span,
         is_tentative = false,
         is_defined = true,
         enum_value = nil,
      }
      define_symbol(ctx, sym)
   elseif decl is ast.TagDecl then
      collect_tags(ctx, decl.type, nil)
   end
end

local record CheckOptions
   allow_incomplete_params: boolean | nil
end

local function check(tu: TranslationUnit, reporter?: Reporter, opts?: CheckOptions): CheckedTranslationUnit
   local rep = reporter or Reporter.new()
   local global_scope = scopes.Scope.new(nil)
   local ctx: Context = {
      rep = rep,
      globals = global_scope,
      scope = global_scope,
      expr_info = {},
      allow_incomplete_params = opts and opts.allow_incomplete_params or false,
      current_function = nil,
      current_function_name = nil,
      current_function_span = nil,
      loop_depth = 0,
      switch_stack = {},
      labels_defined = {},
      labels_used = {},
   }

   for _, decl in ipairs(tu.decls) do
      process_decl(ctx, decl, true)
      ctx.scope = global_scope
   end

   return { tu = tu, globals = global_scope, expr_info = ctx.expr_info }
end

return {
   CheckedTranslationUnit = CheckedTranslationUnit,
   CheckOptions = CheckOptions,
   check = check,
}
