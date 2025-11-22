local Span = require("util.span")
local Diagnostic = require("diag.diagnostics")
local Reporter = require("diag.reporter")
local scopes = require("sema.scopes")
local symbols = require("sema.symbols")
local types = require("sema.types")
local ast = require("parser.ast")

local type Scope = scopes.Scope
local type Symbol = symbols.Symbol

local interface TypeCtx
   scope: Scope
   rep: Reporter
end

local record BuiltinInfo
   is_signed: boolean
end

local function qualifier_span(ty: types.TypeNode): Span
   return ty.span
end

local function merge_qualifiers(lhs: {types.TypeQualifier}, rhs: {types.TypeQualifier}): {types.TypeQualifier}
   if #lhs == 0 then
      return rhs
   end
   if #rhs == 0 then
      return lhs
   end
   local seen: {types.TypeQualifier:boolean} = {}
   local out: {types.TypeQualifier} = {}
   for _, q in ipairs(lhs) do
      if not seen[q] then
         table.insert(out, q)
         seen[q] = true
      end
   end
   for _, q in ipairs(rhs) do
      if not seen[q] then
         table.insert(out, q)
         seen[q] = true
      end
   end
   return out
end

local function wrap_qualified(base: types.TypeNode, quals: {types.TypeQualifier}): types.TypeNode
   if #quals == 0 then
      return base
   end
   return {
      tag = "qualified",
      span = base.span,
      of = base,
      qualifiers = quals,
   }
end

local function strip_qualifiers(ty: types.TypeNode): (types.TypeNode, {types.TypeQualifier})
   local quals: {types.TypeQualifier} = {}
   local current = ty
   while current is types.QualifiedType do
      quals = merge_qualifiers(quals, current.qualifiers)
      current = current.of
   end
   return current, quals
end

local builtin_defaults: { string: BuiltinInfo } = {
   void = { is_signed = false },
   bool = { is_signed = false },
   char = { is_signed = true },
   schar = { is_signed = true },
   uchar = { is_signed = false },
   short = { is_signed = true },
   ushort = { is_signed = false },
   int = { is_signed = true },
   uint = { is_signed = false },
   long = { is_signed = true },
   ulong = { is_signed = false },
   long_long = { is_signed = true },
   ulong_long = { is_signed = false },
   float = { is_signed = true },
   double = { is_signed = true },
   long_double = { is_signed = true },
}

local function make_builtin(name: types.BuiltinName, span: Span, is_signed?: boolean): types.BuiltinType
   local default_signed = builtin_defaults[name]
   local signed = is_signed
   if signed is nil then
      if default_signed ~= nil then
         signed = default_signed.is_signed
      else
         signed = true
      end
   end
   return {
      tag = "builtin",
      span = span,
      name = name,
      is_signed = signed,
      is_complex = false,
      is_imaginary = false,
   }
end

local function resolve_type(ctx: TypeCtx, ty: types.TypeNode, seen?: {string:boolean}): types.TypeNode
   local guard = seen or {}
   local base, quals = strip_qualifiers(ty)
   if base is types.TypedefType then
      local name = base.name
      if guard[name] then
         return wrap_qualified(base, quals)
      end
      guard[name] = true
      local sym_lookup = ctx.scope:lookup(name)
      if not sym_lookup is nil and sym_lookup is symbols.TypeDef then
         return wrap_qualified(resolve_type(ctx, sym_lookup.type, guard), quals)
      end
      ctx.rep:report(Diagnostic.new("error", string.format("unknown type name '%s'", name), base.span, "SEM020"))
      return wrap_qualified(make_builtin("int", base.span, true), quals)
   elseif base is types.PointerType then
      local inner = resolve_type(ctx, base.to, guard)
      local ptr: types.TypeNode = {
         tag = "pointer",
         span = base.span,
         to = inner,
         qualifiers = base.qualifiers,
      }
      return wrap_qualified(ptr, quals)
   elseif base is types.ArrayType then
      local inner = resolve_type(ctx, base.of, guard)
      local size = base.size
      if size is nil then
         local sz_expr = base.size_expr
         if sz_expr and sz_expr is ast.NumberLiteralExpr then
            local parsed = tonumber(sz_expr.token.lexeme)
            if parsed then
               size = math.floor(parsed)
            end
         end
      end
      local arr: types.TypeNode = {
         tag = "array",
         span = base.span,
         of = inner,
         size = size,
         size_expr = base.size_expr,
         is_vla = base.is_vla,
         is_static = base.is_static,
         qualifiers = base.qualifiers,
      }
      return wrap_qualified(arr, quals)
   elseif base is types.FunctionType then
      local returns = resolve_type(ctx, base.returns, seen)
      local params: {types.FunctionParam} = {}
      for _, p in ipairs(base.params) do
         table.insert(params, { name = p.name, type = resolve_type(ctx, p.type, seen), span = p.span })
      end
      local fn: types.TypeNode = {
         tag = "function",
         span = base.span,
         returns = returns,
         params = params,
         is_variadic = base.is_variadic,
      }
      return wrap_qualified(fn, quals)
   elseif base is types.StructType then
      local tag_seen = base.name and guard["tag:" .. base.name] or false
      if tag_seen then
         return wrap_qualified(base, quals)
      end
      if base.name then
         guard["tag:" .. base.name] = true
      end
      local source = base
      if base.name ~= nil and not base.complete then
         local tag_lookup = ctx.scope:lookup(base.name, "tag")
         if not tag_lookup is nil and tag_lookup is symbols.Tag then
            local tag_ty = tag_lookup.type
            if tag_ty is types.StructType then
               source = tag_ty
            end
         end
      end
      local fields: {types.Field} = {}
      for _, f in ipairs(source.fields) do
         table.insert(fields, { name = f.name, type = resolve_type(ctx, f.type, guard), bit_width = f.bit_width })
      end
      local st: types.StructType = {
         tag = "struct",
         span = source.span,
         name = source.name,
         fields = fields,
         complete = source.complete,
      }
      return wrap_qualified(st, quals)
   elseif base is types.UnionType then
      local tag_seen = base.name and guard["tag:" .. base.name] or false
      if tag_seen then
         return wrap_qualified(base, quals)
      end
      if base.name then
         guard["tag:" .. base.name] = true
      end
      local source = base
      if base.name and not base.complete then
         local tag_lookup = ctx.scope:lookup(base.name, "tag")
         if not tag_lookup is nil and tag_lookup is symbols.Tag then
            local tag_ty = tag_lookup.type
            if tag_ty is types.UnionType then
               source = tag_ty
            end
         end
      end
      local fields: {types.Field} = {}
      for _, f in ipairs(source.fields) do
         table.insert(fields, { name = f.name, type = resolve_type(ctx, f.type, guard), bit_width = f.bit_width })
      end
      local ut: types.TypeNode = {
         tag = "union",
         span = source.span,
         name = source.name,
         fields = fields,
         complete = source.complete,
      }
      return wrap_qualified(ut, quals)
   elseif base is types.EnumType then
      local source = base
      if base.name ~= nil and not base.complete then
         local tag_lookup = ctx.scope:lookup(base.name, "tag")
         if tag_lookup ~= nil then
            local tag_sym: Symbol = tag_lookup
            if tag_sym.kind == "tag" then
               local tag_ty = tag_sym.type
               if tag_ty is types.EnumType then
                  source = tag_ty
               end
            end
         end
      end
      local values: {types.EnumConst} = {}
      for _, v in ipairs(source.values) do
         table.insert(values, { name = v.name, value = v.value, span = v.span })
      end
      local en: types.TypeNode = {
         tag = "enum",
         span = source.span,
         name = source.name,
         underlying = source.underlying,
         values = values,
         complete = source.complete,
      }
      return wrap_qualified(en, quals)
   end
   return wrap_qualified(base, quals)
end

local function is_void_type(ctx: TypeCtx, ty: types.TypeNode): boolean
   local base = resolve_type(ctx, ty)
   local unqual, _ = strip_qualifiers(base)
   return unqual is types.BuiltinType and unqual.name == "void"
end

local function is_integer_type(ctx: TypeCtx, ty: types.TypeNode): boolean
   local resolved = resolve_type(ctx, ty)
   local base, _ = strip_qualifiers(resolved)
   if base is types.BuiltinType then
      return base.name ~= "void" and base.name ~= "float" and base.name ~= "double" and base.name ~= "long_double"
   end
   if base is types.EnumType then
      return true
   end
   return false
end

local function is_floating_type(ctx: TypeCtx, ty: types.TypeNode): boolean
   local resolved = resolve_type(ctx, ty)
   local base, _ = strip_qualifiers(resolved)
   return base is types.BuiltinType and (base.name == "float" or base.name == "double" or base.name == "long_double")
end

local function is_arithmetic_type(ctx: TypeCtx, ty: types.TypeNode): boolean
   return is_integer_type(ctx, ty) or is_floating_type(ctx, ty)
end

local function is_pointer_type(ctx: TypeCtx, ty: types.TypeNode): boolean
   local resolved = resolve_type(ctx, ty)
   local base, _ = strip_qualifiers(resolved)
   return base is types.PointerType
end

local function is_scalar_type(ctx: TypeCtx, ty: types.TypeNode): boolean
   return is_arithmetic_type(ctx, ty) or is_pointer_type(ctx, ty)
end

local function is_incomplete_type(ctx: TypeCtx, ty: types.TypeNode): boolean
   local resolved = resolve_type(ctx, ty)
   local base, _ = strip_qualifiers(resolved)
   if base is types.BuiltinType then
      return base.name == "void"
   elseif base is types.StructType or base is types.UnionType then
      if not base.complete then
         return true
      end
      for _, f in ipairs(base.fields) do
         if is_incomplete_type(ctx, f.type) then
            return true
         end
      end
   elseif base is types.EnumType then
      return not base.complete
   elseif base is types.ArrayType then
      if base.size == nil and not base.is_vla then
         return true
      end
      return is_incomplete_type(ctx, base.of)
   end
   return false
end

local function decay_for_value(ctx: TypeCtx, ty: types.TypeNode): types.TypeNode
   local resolved = resolve_type(ctx, ty)
   local base, quals = strip_qualifiers(resolved)
   if base is types.ArrayType then
      local ptr: types.TypeNode = {
         tag = "pointer",
         span = base.span,
         to = base.of,
         qualifiers = base.qualifiers,
      }
      return wrap_qualified(ptr, quals)
   elseif base is types.FunctionType then
      local ptr: types.TypeNode = {
         tag = "pointer",
         span = base.span,
         to = base,
         qualifiers = {},
      }
      return wrap_qualified(ptr, quals)
   end
   return resolved
end

local int_rank: {types.BuiltinName: integer} = {
   bool = 1,
   char = 2, schar = 2, uchar = 2,
   short = 3, ushort = 3,
   int = 4, uint = 4,
   long = 5, ulong = 5,
   long_long = 6, ulong_long = 6,
}

local function integer_promote(ctx: TypeCtx, ty: types.TypeNode): types.TypeNode
   local resolved = resolve_type(ctx, ty)
   local base, _ = strip_qualifiers(resolved)
   if base is types.BuiltinType then
      local rank = int_rank[base.name]
      if rank is nil then
         return resolved
      end
      if rank < (int_rank.int or 4) then
         return make_builtin("int", base.span, true)
      end
      return resolved
   elseif base is types.EnumType then
      return make_builtin("int", base.span, true)
   end
   return resolved
end

local function choose_integer(lhs: types.BuiltinType, rhs: types.BuiltinType): types.BuiltinType
   local l_rank = int_rank[lhs.name] or 0
   local r_rank = int_rank[rhs.name] or 0
   if lhs.is_signed == rhs.is_signed then
       if l_rank >= r_rank then
          return lhs
       else
          return rhs
       end
   end
   if not lhs.is_signed and l_rank >= r_rank then
      return lhs
   end
   if not rhs.is_signed and r_rank >= l_rank then
      return rhs
   end
   if lhs.is_signed then
      return { tag = "builtin", span = lhs.span, name = lhs.name, is_signed = false, is_complex = lhs.is_complex, is_imaginary = lhs.is_imaginary }
   end
   return { tag = "builtin", span = rhs.span, name = rhs.name, is_signed = false, is_complex = rhs.is_complex, is_imaginary = rhs.is_imaginary }
end

local function usual_arithmetic_conversion(ctx: TypeCtx, lhs: types.TypeNode, rhs: types.TypeNode): types.TypeNode | nil
   local l = resolve_type(ctx, lhs)
   local r = resolve_type(ctx, rhs)
   if is_floating_type(ctx, l) or is_floating_type(ctx, r) then
      local function is_double(bt: types.TypeNode): boolean
         local b, _ = strip_qualifiers(bt)
         return b is types.BuiltinType and (b.name == "double" or b.name == "long_double")
      end
      if is_double(l) or is_double(r) then
         return make_builtin("double", qualifier_span(l), true)
      end
      return make_builtin("float", qualifier_span(l), true)
   end

   local lp = integer_promote(ctx, l)
   local rp = integer_promote(ctx, r)
   local lb, _ = strip_qualifiers(lp)
   local rb, _ = strip_qualifiers(rp)
   if lb is types.BuiltinType and rb is types.BuiltinType then
      return choose_integer(lb, rb)
   end
   return nil
end

local function types_compatible(ctx: TypeCtx, lhs: types.TypeNode, rhs: types.TypeNode): boolean
   local l = resolve_type(ctx, lhs)
   local r = resolve_type(ctx, rhs)
   return types.equals(l, r)
end

return {
   TypeCtx = TypeCtx,
   merge_qualifiers = merge_qualifiers,
   wrap_qualified = wrap_qualified,
   strip_qualifiers = strip_qualifiers,
   resolve_type = resolve_type,
   is_void_type = is_void_type,
   is_integer_type = is_integer_type,
   is_floating_type = is_floating_type,
   is_arithmetic_type = is_arithmetic_type,
   is_pointer_type = is_pointer_type,
   is_scalar_type = is_scalar_type,
   is_incomplete_type = is_incomplete_type,
   decay_for_value = decay_for_value,
   integer_promote = integer_promote,
   usual_arithmetic_conversion = usual_arithmetic_conversion,
   types_compatible = types_compatible,
   make_builtin = make_builtin,
}
