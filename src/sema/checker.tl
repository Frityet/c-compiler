local ast = require("parser.ast")
local Reporter = require("diag.reporter")
local Diagnostic = require("diag.diagnostics")
local Span = require("util.span")
local token_mod = require("lexer.token")
local scopes = require("sema.scopes")
local symbols = require("sema.symbols")
local types = require("sema.types")

local type TranslationUnit = ast.TranslationUnit
local type Scope = scopes.Scope
local type Symbol = symbols.Symbol

local record CheckedTranslationUnit
   tu: TranslationUnit
   globals: Scope
end

local record Context
   rep: Reporter
   globals: Scope
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

local function storage_duration_for(specs: ast.DeclSpecifiers): symbols.StorageDuration
   if has_storage(specs, "static") or has_storage(specs, "extern") then
      return "static"
   end
   return "auto"
end

local function linkage_for(specs: ast.DeclSpecifiers): symbols.Linkage
   if has_storage(specs, "static") then
      return "internal"
   end
   if has_storage(specs, "extern") then
      return "external"
   end
   return "external"
end

local function qualifier_span(ty: types.TypeNode): Span
   return ty.span
end

local function number_literal_value(expr: types.ExpressionRef): number | nil
   if expr is ast.NumberLiteralExpr then
      local num = tonumber(expr.token.lexeme)
      if num is nil then
         return nil
      end
      return num
   end
   return nil
end

local function size_expr_constant_positive(expr: types.ExpressionRef | nil): boolean
   if expr is nil then
      return false
   end
   local val = number_literal_value(expr)
   return val is number and val > 0
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

local function validate_array_param(ctx: Context, arr: types.ArrayType)
   if arr.is_static then
      local sz = arr.size_expr
      if arr.is_vla or sz is nil then
         ctx.rep:report(Diagnostic.new("error", "static array parameter requires a constant bound", arr.span, "SEM011"))
         return
      end
      if sz.kind ~= "number_literal" then
         ctx.rep:report(Diagnostic.new("error", "static array parameter requires a constant bound", arr.span, "SEM011"))
         return
      end
      if not size_expr_constant_positive(sz) then
         ctx.rep:report(Diagnostic.new("error", "static array parameter bound must be a positive constant", arr.span, "SEM012"))
      end
   end
end

local function validate_incomplete(ctx: Context, ty: types.TypeNode)
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
      for _, q in ipairs(ty.qualifiers) do
         if q == "restrict" then
            -- ok on pointers
         end
      end
      validate_restrict(ctx, ty.to)
   elseif ty is types.ArrayType then
      -- array qualifiers handled on conversion to pointer for params, still recurse
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
      validate_param_type(ctx, ty.to)
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

local function define_symbol(ctx: Context, sym: Symbol)
   local ns = "object"
   if sym.kind == "tag" then
      ns = "tag"
   elseif sym.kind == "label" then
      ns = "label"
   end
   local existing = ctx.globals:lookup(sym.name, ns)
    if existing is nil then
      ctx.globals:define(sym, ns)
      return
   end
   local existing_sym: Symbol = existing

   if existing_sym.kind ~= sym.kind then
      report_conflict(ctx, sym.name, sym.span, "SEM002", "conflicting declaration for")
      return
   end

   if not types.equals(existing_sym.type, sym.type) then
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
   ctx.globals:define(existing_sym, ns)
end

local function note_enum_constants(ctx: Context, ty: types.EnumType)
   if not ty.complete then
      return
   end
   for _, ev in ipairs(ty.values) do
      local sym: Symbol = {
         name = ev.name,
         kind = "enum_const",
         type = ty.underlying,
         storage = nil,
         linkage = "none",
         span = ev.span,
         is_tentative = false,
         is_defined = true,
      }
      define_symbol(ctx, sym)
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

   local existing = ctx.globals:lookup(name, "tag")
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
      }
      ctx.globals:define(sym, "tag")
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
      ctx.globals:define(existing_sym, "tag")
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
      if ty is types.EnumType then
         -- enum constants handled in merge_tag when complete
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

local function process_decl(ctx: Context, decl: ast.DeclNode)
   if decl is ast.VarDecl then
      local name_tok = decl.declarator.name
      if name_tok is nil then
         missing_name(ctx.rep, decl)
         return
      end
      local tok: token_mod.Token = name_tok
      collect_tags(ctx, decl.type, nil)

      local specs = decl.specifiers
      local linkage = linkage_for(specs)
      local storage = storage_duration_for(specs)
      local is_def = decl.init ~= nil
      validate_storage(ctx, decl.type, storage)
      local sym: Symbol = {
         name = tok.lexeme,
         kind = "object",
         type = decl.type,
         storage = storage,
         linkage = linkage,
         span = decl.span,
         is_tentative = not is_def and not has_storage(specs, "extern"),
         is_defined = is_def,
      }
      define_symbol(ctx, sym)
   elseif decl is ast.FuncDecl then
      local name_tok = decl.declarator.name
      if name_tok is nil then
         missing_name(ctx.rep, decl)
         return
      end
      local tok: token_mod.Token = name_tok
      collect_tags(ctx, decl.type, nil)

      local specs = decl.specifiers
      local linkage = linkage_for(specs)
      local fn_ty = decl.type
      if fn_ty is types.FunctionType then
         validate_function(ctx, fn_ty)
      end
      local sym: Symbol = {
         name = tok.lexeme,
         kind = "function",
         type = decl.type,
         storage = nil,
         linkage = linkage,
         span = decl.span,
         is_tentative = false,
         is_defined = decl.body ~= nil,
      }
      define_symbol(ctx, sym)
   elseif decl is ast.TypedefDecl then
      local name_tok = decl.declarator.name
      if name_tok is nil then
         missing_name(ctx.rep, decl)
         return
      end
      local tok: token_mod.Token = name_tok
      collect_tags(ctx, decl.type, nil)

      local sym: Symbol = {
         name = tok.lexeme,
         kind = "typedef",
         type = decl.type,
         storage = nil,
         linkage = "none",
         span = decl.span,
         is_tentative = false,
         is_defined = true,
      }
      define_symbol(ctx, sym)
   elseif decl is ast.TagDecl then
      collect_tags(ctx, decl.type, nil)
   end
end

local function check(tu: TranslationUnit, reporter?: Reporter): CheckedTranslationUnit
   local rep = reporter or Reporter.new()
   local global_scope = scopes.Scope.new(nil)
   local ctx: Context = { rep = rep, globals = global_scope }

   for _, decl in ipairs(tu.decls) do
      process_decl(ctx, decl)
   end

   return { tu = tu, globals = global_scope }
end

return {
   CheckedTranslationUnit = CheckedTranslationUnit,
   check = check,
}
