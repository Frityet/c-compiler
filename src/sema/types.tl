local Span = require("util.span")

local enum TypeTag
   "builtin"
   "pointer"
   "array"
   "function"
   "struct"
   "union"
   "enum"
   "qualified"
   "typedef"
end

local enum BuiltinName
   "void"
   "bool"
   "char"
   "schar"
   "uchar"
   "short"
   "ushort"
   "int"
   "uint"
   "long"
   "ulong"
   "long_long"
   "ulong_long"
   "float"
   "double"
   "long_double"
end

local enum TypeQualifier
   "const"
   "restrict"
   "volatile"
end

local interface ExpressionRef
   span: Span
   kind: string
end

local interface CType
   tag: TypeTag
   span: Span
end

local record BuiltinType
   is CType
   where self.tag == "builtin"

   name: BuiltinName
   is_signed: boolean
   is_complex: boolean
   is_imaginary: boolean
end

local record TypedefType
   is CType
   where self.tag == "typedef"

   name: string
end

local record PointerType
   is CType
   where self.tag == "pointer"

   to: TypeNode
   qualifiers: {TypeQualifier}
end

local record ArrayType
   is CType
   where self.tag == "array"

   of: TypeNode
   size: integer | nil
   size_expr: ExpressionRef | nil
   is_vla: boolean
   is_static: boolean
   qualifiers: {TypeQualifier}
end

local record FunctionParam
   name: string | nil
   type: TypeNode
   span: Span
end

local record FunctionType
   is CType
   where self.tag == "function"

   returns: TypeNode
   params: {FunctionParam}
   is_variadic: boolean
end

local record Field
   name: string
   type: TypeNode
   bit_width: integer | nil
end

local record StructType
   is CType
   where self.tag == "struct"

   name: string | nil
   fields: {Field}
   complete: boolean
end

local record UnionType
   is CType
   where self.tag == "union"

   name: string | nil
   fields: {Field}
   complete: boolean
end

local record EnumConst
   name: string
   value: integer | nil
   span: Span
end

local record EnumType
   is CType
   where self.tag == "enum"

   name: string | nil
   underlying: BuiltinType
   values: {EnumConst}
   complete: boolean
end

local record QualifiedType
   is CType
   where self.tag == "qualified"

   of: TypeNode
   qualifiers: {TypeQualifier}
end

local type TypeNode = BuiltinType | PointerType | ArrayType | FunctionType | StructType | UnionType | EnumType | QualifiedType | TypedefType
local types_equal: function(TypeNode, TypeNode): boolean

local record TokenView
   lexeme: string
end

local record LiteralExprView
   token: TokenView | nil
end

local function qualifier_set_equal(lhs: {TypeQualifier}, rhs: {TypeQualifier}): boolean
   if #lhs ~= #rhs then
      return false
   end
   local seen: {TypeQualifier: integer} = {}
   for _, q in ipairs(lhs) do
      seen[q] = (seen[q] or 0) + 1
   end
   for _, q in ipairs(rhs) do
      local count = seen[q]
      if not count or count == 0 then
         return false
      end
      seen[q] = count - 1
   end
   return true
end

local function fields_equal(lhs: {Field}, rhs: {Field}): boolean
   if #lhs ~= #rhs then
      return false
   end
   for i = 1, #lhs do
      local l = lhs[i]
      local r = rhs[i]
      if l.name ~= r.name then
         return false
      end
      if l.bit_width ~= r.bit_width then
         return false
      end
      if not types_equal(l.type, r.type) then
         return false
      end
   end
   return true
end

local function enum_values_equal(lhs: {EnumConst}, rhs: {EnumConst}): boolean
   if #lhs ~= #rhs then
      return false
   end
   for i = 1, #lhs do
      local l = lhs[i]
      local r = rhs[i]
      if l.name ~= r.name then
         return false
      end
      if l.value ~= r.value then
         return false
      end
   end
   return true
end

local function extract_literal(expr: ExpressionRef | nil): string | nil
   if expr is nil then
      return nil
   end
   local expr_any: LiteralExprView = expr as LiteralExprView
   local token = expr_any.token
   if token is nil then
      return nil
   end
   local lex = token.lexeme
   if type(lex) == "string" then
      return lex
   end
   return nil
end

types_equal = function(lhs: TypeNode, rhs: TypeNode): boolean
   if lhs.tag ~= rhs.tag then
      return false
   end
   if lhs is BuiltinType and rhs is BuiltinType then
      return lhs.name == rhs.name and lhs.is_signed == rhs.is_signed and lhs.is_complex == rhs.is_complex and lhs.is_imaginary == rhs.is_imaginary
   elseif lhs is PointerType and rhs is PointerType then
      return qualifier_set_equal(lhs.qualifiers, rhs.qualifiers) and types_equal(lhs.to, rhs.to)
   elseif lhs is ArrayType and rhs is ArrayType then
      local lhs_size = lhs.size
      local rhs_size = rhs.size
      if not (lhs_size is nil) or not (rhs_size is nil) then
         if lhs_size ~= rhs_size then
            return false
         end
      else
         local lhs_lit = extract_literal(lhs.size_expr)
         local rhs_lit = extract_literal(rhs.size_expr)
         if lhs_lit and rhs_lit and lhs_lit ~= rhs_lit then
            return false
         end
      end
      return lhs.is_vla == rhs.is_vla and lhs.is_static == rhs.is_static and qualifier_set_equal(lhs.qualifiers, rhs.qualifiers) and types_equal(lhs.of, rhs.of)
   elseif lhs is FunctionType and rhs is FunctionType then
      if lhs.is_variadic ~= rhs.is_variadic then
         return false
      end
      if #lhs.params ~= #rhs.params then
         return false
      end
      for i = 1, #lhs.params do
         if not types_equal(lhs.params[i].type, rhs.params[i].type) then
            return false
         end
      end
      return types_equal(lhs.returns, rhs.returns)
   elseif lhs is StructType and rhs is StructType then
      if lhs.name ~= rhs.name then
         return false
      end
      if lhs.complete and rhs.complete then
         return fields_equal(lhs.fields, rhs.fields)
      end
      return true
   elseif lhs is UnionType and rhs is UnionType then
      if lhs.name ~= rhs.name then
         return false
      end
      if lhs.complete and rhs.complete then
         return fields_equal(lhs.fields, rhs.fields)
      end
      return true
   elseif lhs is EnumType and rhs is EnumType then
      if lhs.name ~= rhs.name then
         return false
      end
      if lhs.complete and rhs.complete then
         return enum_values_equal(lhs.values, rhs.values)
      end
      return true
   elseif lhs is QualifiedType and rhs is QualifiedType then
      return qualifier_set_equal(lhs.qualifiers, rhs.qualifiers) and types_equal(lhs.of, rhs.of)
   else
      local l = lhs as TypedefType
      local r = rhs as TypedefType
      return l.name == r.name
   end
end

return {
   TypeTag = TypeTag,
   BuiltinName = BuiltinName,
   TypeQualifier = TypeQualifier,
   ExpressionRef = ExpressionRef,
   CType = CType,
   BuiltinType = BuiltinType,
   PointerType = PointerType,
   ArrayType = ArrayType,
   FunctionType = FunctionType,
   StructType = StructType,
   UnionType = UnionType,
   EnumType = EnumType,
   QualifiedType = QualifiedType,
   TypedefType = TypedefType,
   FunctionParam = FunctionParam,
   Field = Field,
   EnumConst = EnumConst,
   TypeNode = TypeNode,
   equals = types_equal,
}
