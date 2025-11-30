local ffi = require("ffi")
local TLStringView = require("util.string_view")
local Span = require("util.span")

ffi.cdef [[
union TypeNode;

enum CType_TypeTag {
    TypeTag_BUILTIN,
    TypeTag_POINTER,
    TypeTag_ARRAY,
    TypeTag_FUNCTION,
    TypeTag_STRUCT,
    TypeTag_UNION,
    TypeTag_ENUM,
    TypeTag_QUALIFIED,
    TypeTag_TYPEDEF,
};

enum CType_BuiltinName {
    BuiltinTypeName_VOID,
    BuiltinTypeName_BOOL,
    BuiltinTypeName_CHAR,
    BuiltinTypeName_SCHAR,
    BuiltinTypeName_UCHAR,
    BuiltinTypeName_SHORT,
    BuiltinTypeName_USHORT,
    BuiltinTypeName_INT,
    BuiltinTypeName_UINT,
    BuiltinTypeName_LONG,
    BuiltinTypeName_ULONG,
    BuiltinTypeName_LONG_LONG,
    BuiltinTypeName_ULONG_LONG,
    BuiltinTypeName_FLOAT,
    BuiltinTypeName_DOUBLE,
    BuiltinTypeName_LONG_DOUBLE,
};

enum CType_TypeQualifier {
    TypeQualifier_CONST,
    TypeQualifier_RESTRICT,
    TypeQualifier_VOLATILE,
};

struct CType {
    enum CType_TypeTag tag;
    struct TLSpan span;
};

struct BuiltinType {
    struct CType;
    enum CType_BuiltinName name;
    bool is_signed;
    bool is_complex;
    bool is_imaginary;
};

struct TypedefType {
    struct CType;
    struct TLStringView name;
};

struct PointerType {
    struct CType;
    union TypeNode *to;
    uint8_t qualifiers_len;
    enum CType_TypeQualifier qualifiers[3];
};

struct ArrayType {
    struct CType;
    union TypeNode *of;
    int64_t size;
    void *size_expr;
    bool has_size;
    bool is_vla;
    bool is_static;
    uint8_t qualifiers_len;
    enum CType_TypeQualifier qualifiers[3];
};

struct FunctionParam {
    struct TLStringView name;
    union TypeNode *type;
    struct TLSpan span;
};

struct FunctionType {
    struct CType;
    union TypeNode *returns;
    struct FunctionParam *params;
    size_t params_len;
    bool is_variadic;
};

struct Field {
    struct TLStringView name;
    union TypeNode *type;
    int64_t bit_width;
    bool has_bit_width;
};

struct StructType {
    struct CType;
    struct TLStringView name;
    struct Field *fields;
    size_t fields_len;
    bool complete;
};

struct UnionType {
    struct CType;
    struct TLStringView name;
    struct Field *fields;
    size_t fields_len;
    bool complete;
};

struct EnumConst {
    struct TLStringView name;
    int64_t value;
    bool has_value;
    struct TLSpan span;
};

struct EnumType {
    struct CType;
    struct TLStringView name;
    union TypeNode *underlying;
    struct EnumConst *values;
    size_t values_len;
    bool complete;
};

struct QualifiedType {
    struct CType;
    union TypeNode *of;
    uint8_t qualifiers_len;
    enum CType_TypeQualifier qualifiers[3];
};

union TypeNode {
   struct BuiltinType;
   struct PointerType;
   struct ArrayType;
   struct FunctionType;
   struct StructType;
   struct UnionType;
   struct EnumType;
   struct QualifiedType;
   struct TypedefType;
};
]]

local TYPE_TAG_BUILTIN<const> = ffi.C.TypeTag_BUILTIN as integer
local TYPE_TAG_POINTER<const> = ffi.C.TypeTag_POINTER as integer
local TYPE_TAG_ARRAY<const> = ffi.C.TypeTag_ARRAY as integer
local TYPE_TAG_FUNCTION<const> = ffi.C.TypeTag_FUNCTION as integer
local TYPE_TAG_STRUCT<const> = ffi.C.TypeTag_STRUCT as integer
local TYPE_TAG_UNION<const> = ffi.C.TypeTag_UNION as integer
local TYPE_TAG_ENUM<const> = ffi.C.TypeTag_ENUM as integer
local TYPE_TAG_QUALIFIED<const> = ffi.C.TypeTag_QUALIFIED as integer
local TYPE_TAG_TYPEDEF<const> = ffi.C.TypeTag_TYPEDEF as integer

local BUILTIN_VOID<const> = ffi.C.BuiltinTypeName_VOID as integer
local BUILTIN_BOOL<const> = ffi.C.BuiltinTypeName_BOOL as integer
local BUILTIN_CHAR<const> = ffi.C.BuiltinTypeName_CHAR as integer
local BUILTIN_SCHAR<const> = ffi.C.BuiltinTypeName_SCHAR as integer
local BUILTIN_UCHAR<const> = ffi.C.BuiltinTypeName_UCHAR as integer
local BUILTIN_SHORT<const> = ffi.C.BuiltinTypeName_SHORT as integer
local BUILTIN_USHORT<const> = ffi.C.BuiltinTypeName_USHORT as integer
local BUILTIN_INT<const> = ffi.C.BuiltinTypeName_INT as integer
local BUILTIN_UINT<const> = ffi.C.BuiltinTypeName_UINT as integer
local BUILTIN_LONG<const> = ffi.C.BuiltinTypeName_LONG as integer
local BUILTIN_ULONG<const> = ffi.C.BuiltinTypeName_ULONG as integer
local BUILTIN_LONG_LONG<const> = ffi.C.BuiltinTypeName_LONG_LONG as integer
local BUILTIN_ULONG_LONG<const> = ffi.C.BuiltinTypeName_ULONG_LONG as integer
local BUILTIN_FLOAT<const> = ffi.C.BuiltinTypeName_FLOAT as integer
local BUILTIN_DOUBLE<const> = ffi.C.BuiltinTypeName_DOUBLE as integer
local BUILTIN_LONG_DOUBLE<const> = ffi.C.BuiltinTypeName_LONG_DOUBLE as integer

local QUAL_CONST<const> = ffi.C.TypeQualifier_CONST as integer
local QUAL_RESTRICT<const> = ffi.C.TypeQualifier_RESTRICT as integer
local QUAL_VOLATILE<const> = ffi.C.TypeQualifier_VOLATILE as integer

local TypeTag = {
   BUILTIN = TYPE_TAG_BUILTIN,
   POINTER = TYPE_TAG_POINTER,
   ARRAY = TYPE_TAG_ARRAY,
   FUNCTION = TYPE_TAG_FUNCTION,
   STRUCT = TYPE_TAG_STRUCT,
   UNION = TYPE_TAG_UNION,
   ENUM = TYPE_TAG_ENUM,
   QUALIFIED = TYPE_TAG_QUALIFIED,
   TYPEDEF = TYPE_TAG_TYPEDEF,
}

local BuiltinName = {
   VOID = BUILTIN_VOID,
   BOOL = BUILTIN_BOOL,
   CHAR = BUILTIN_CHAR,
   SCHAR = BUILTIN_SCHAR,
   UCHAR = BUILTIN_UCHAR,
   SHORT = BUILTIN_SHORT,
   USHORT = BUILTIN_USHORT,
   INT = BUILTIN_INT,
   UINT = BUILTIN_UINT,
   LONG = BUILTIN_LONG,
   ULONG = BUILTIN_ULONG,
   LONG_LONG = BUILTIN_LONG_LONG,
   ULONG_LONG = BUILTIN_ULONG_LONG,
   FLOAT = BUILTIN_FLOAT,
   DOUBLE = BUILTIN_DOUBLE,
   LONG_DOUBLE = BUILTIN_LONG_DOUBLE,
}

local TypeQualifier = {
   CONST = QUAL_CONST,
   RESTRICT = QUAL_RESTRICT,
   VOLATILE = QUAL_VOLATILE,
}

local function valid_tag(tag: integer): boolean
   return tag == TYPE_TAG_BUILTIN
      or tag == TYPE_TAG_POINTER
      or tag == TYPE_TAG_ARRAY
      or tag == TYPE_TAG_FUNCTION
      or tag == TYPE_TAG_STRUCT
      or tag == TYPE_TAG_UNION
      or tag == TYPE_TAG_ENUM
      or tag == TYPE_TAG_QUALIFIED
      or tag == TYPE_TAG_TYPEDEF
end

local interface CType is ffi.CData where valid_tag(self.tag)
   tag: integer
   span: Span
end

local record BuiltinType is CType
   where self.tag == TYPE_TAG_BUILTIN

   name: integer
   is_signed: boolean
   is_complex: boolean
   is_imaginary: boolean
end

local record TypedefType is CType
   where self.tag == TYPE_TAG_TYPEDEF

   name: TLStringView
end

local record PointerType is CType
   where self.tag == TYPE_TAG_POINTER

   to: ffi.Pointer<TypeNode>
   qualifiers_len: integer
   qualifiers: ffi.Array<integer>
end

local record ArrayType is CType
   where self.tag == TYPE_TAG_ARRAY

   of: ffi.Pointer<TypeNode>
   size: integer
   size_expr: ffi.CData | nil
   has_size: boolean
   is_vla: boolean
   is_static: boolean
   qualifiers_len: integer
   qualifiers: ffi.Array<integer>
end

local record FunctionParam is ffi.CData where ffi.istype("struct FunctionParam", self)
   name: TLStringView
   type: ffi.Pointer<TypeNode>
   span: Span
end

local record FunctionType is CType
   where self.tag == TYPE_TAG_FUNCTION

   returns: ffi.Pointer<TypeNode>
   params: ffi.Pointer<FunctionParam>
   params_len: integer
   is_variadic: boolean
end

local record Field is ffi.CData where ffi.istype("struct Field", self)
   name: TLStringView
   type: ffi.Pointer<TypeNode>
   bit_width: integer
   has_bit_width: boolean
end

local record StructType is CType
   where self.tag == TYPE_TAG_STRUCT

   name: TLStringView
   fields: ffi.Pointer<Field>
   fields_len: integer
   complete: boolean
end

local record UnionType is CType
   where self.tag == TYPE_TAG_UNION

   name: TLStringView
   fields: ffi.Pointer<Field>
   fields_len: integer
   complete: boolean
end

local record EnumConst is ffi.CData where ffi.istype("struct EnumConst", self)
   name: TLStringView
   value: integer
   has_value: boolean
   span: Span
end

local record EnumType is CType
   where self.tag == TYPE_TAG_ENUM

   name: TLStringView
   underlying: ffi.Pointer<TypeNode>
   values: ffi.Pointer<EnumConst>
   values_len: integer
   complete: boolean
end

local record QualifiedType is CType
   where self.tag == TYPE_TAG_QUALIFIED

   of: ffi.Pointer<TypeNode>
   qualifiers_len: integer
   qualifiers: ffi.Array<integer>
end

local type TypeNode = BuiltinType
   | PointerType
   | ArrayType
   | FunctionType
   | StructType
   | UnionType
   | EnumType
   | QualifiedType
   | TypedefType

-- local record TypeNode is CType
--    where valid_tag(self.tag) and ffi.istype("union TypeNode", self)

--    tag: integer
--    span: Span
--    builtin: BuiltinType
--    pointer: PointerType
--    array: ArrayType
--    func: FunctionType
--    struct_type: StructType
--    union_type: UnionType
--    enum_type: EnumType
--    qualified: QualifiedType
--    typedef_type: TypedefType
-- end

local record TokenView
   lexeme: string
end

local interface LiteralExprView is ffi.CData
   token: TokenView
   kind: string
end

local function int_len(v: integer): integer
   local n = tonumber(v) or 0
   if n <= 0 then
      return 0
   end
   return math.floor(n)
end

local function view_to_string(view: TLStringView): string
   if view.ptr == nil then
      return ""
   end
   return ffi.string(view.ptr, view.len)
end

local function view_to_optional_string(view: TLStringView): string | nil
   if view.ptr == nil or view.len == 0 then
      return nil
   end
   return ffi.string(view.ptr, view.len)
end

local types_equal: function(TypeNode, TypeNode): boolean


local function qualifier_set_equal(lhs: ffi.Array<integer>, lhs_len: integer, rhs: ffi.Array<integer>, rhs_len: integer): boolean
   local l_len = int_len(lhs_len)
   local r_len = int_len(rhs_len)
   if l_len ~= r_len then
      return false
   end
   local seen: {integer: integer} = {}
   for i = 0, l_len - 1 do
      local q_num = tonumber(lhs[i]) or 0
      local q: integer = math.floor(q_num)
      seen[q] = (seen[q] or 0) + 1
   end
   for i = 0, r_len - 1 do
      local q_num = tonumber(rhs[i]) or 0
      local q: integer = math.floor(q_num)
      local count = seen[q]
      if not count or count == 0 then
         return false
      end
      seen[q] = count - 1
   end
   return true
end

local function fields_equal(lhs: ffi.Pointer<Field>, lhs_len: integer, rhs: ffi.Pointer<Field>, rhs_len: integer): boolean
   local l_len = int_len(lhs_len)
   local r_len = int_len(rhs_len)
   if l_len ~= r_len then
      return false
   end
   for i = 0, l_len - 1 do
      local l = lhs[i]
      local r = rhs[i]
      local l_name = view_to_string(l.name)
      local r_name = view_to_string(r.name)
      if l_name ~= r_name then
         return false
      end
      if l.has_bit_width ~= r.has_bit_width then
         return false
      end
      if l.has_bit_width and l.bit_width ~= r.bit_width then
         return false
      end
      if l.type == nil or r.type == nil then
         return l.type == r.type
      end
      if not types_equal(l.type[0], r.type[0]) then
         return false
      end
   end
   return true
end

local function enum_values_equal(lhs: ffi.Pointer<EnumConst>, lhs_len: integer, rhs: ffi.Pointer<EnumConst>, rhs_len: integer): boolean
   local l_len = int_len(lhs_len)
   local r_len = int_len(rhs_len)
   if l_len ~= r_len then
      return false
   end
   for i = 0, l_len - 1 do
      local l = lhs[i]
      local r = rhs[i]
      local l_name = view_to_string(l.name)
      local r_name = view_to_string(r.name)
      if l_name ~= r_name then
         return false
      end
      if l.has_value ~= r.has_value then
         return false
      end
      if l.has_value and l.value ~= r.value then
         return false
      end
   end
   return true
end

local function extract_literal(expr: ffi.CData | nil): string | nil
   if expr is nil or not expr is LiteralExprView then
      return nil
   end
   return expr.token.lexeme
end

types_equal = function(lhs: TypeNode, rhs: TypeNode): boolean
   if lhs is BuiltinType and rhs is BuiltinType then
      local lb = lhs
      local rb = rhs
      return lb.name == rb.name and lb.is_signed == rb.is_signed and lb.is_complex == rb.is_complex and lb.is_imaginary == rb.is_imaginary
   elseif lhs is PointerType and rhs is PointerType then
      local lp = lhs
      local rp = rhs
      if not qualifier_set_equal(lp.qualifiers, lp.qualifiers_len, rp.qualifiers, rp.qualifiers_len) then
         return false
      end
      if lp.to == nil or rp.to == nil then
         return lp.to == rp.to
      end
      return types_equal(lp.to[0], rp.to[0])
   elseif lhs is ArrayType and rhs is ArrayType then
      local la = lhs
      local ra = rhs
      if la.has_size ~= ra.has_size then
         return false
      end
      if la.has_size then
         if la.size ~= ra.size then
            return false
         end
      else
         local lhs_lit = extract_literal(la.size_expr)
         local rhs_lit = extract_literal(ra.size_expr)
         if lhs_lit and rhs_lit and lhs_lit ~= rhs_lit then
            return false
         end
      end
      if la.is_vla ~= ra.is_vla or la.is_static ~= ra.is_static then
         return false
      end
      if not qualifier_set_equal(la.qualifiers, la.qualifiers_len, ra.qualifiers, ra.qualifiers_len) then
         return false
      end
      if la.of == nil or ra.of == nil then
         return la.of == ra.of
      end
      return types_equal(la.of[0], ra.of[0])
   elseif lhs is FunctionType and rhs is FunctionType then
      local lf = lhs
      local rf = rhs
      local lparams = int_len(lf.params_len)
      local rparams = int_len(rf.params_len)
      if lf.is_variadic ~= rf.is_variadic or lparams ~= rparams then
         return false
      end
      if lparams > 0 and lf.params ~= nil and rf.params ~= nil then
         for i = 0, lparams - 1 do
            if not types_equal(lf.params[i].type[0], rf.params[i].type[0]) then
               return false
            end
         end
      elseif lf.params ~= rf.params then
         return false
      end
      if lf.returns == nil or rf.returns == nil then
         return lf.returns == rf.returns
      end
      return types_equal(lf.returns[0], rf.returns[0])
   elseif lhs is StructType and rhs is StructType then
      local ls = lhs
      local rs = rhs  
      local ls_name = view_to_optional_string(ls.name)
      local rs_name = view_to_optional_string(rs.name)
      if ls_name ~= rs_name then
         local lhs_anon = ls_name == nil
         local rhs_anon = rs_name == nil
         if (lhs_anon or rhs_anon) and ls.complete and rs.complete then
            return fields_equal(ls.fields, ls.fields_len, rs.fields, rs.fields_len)
         end
         return false
      end
      if ls.complete and rs.complete then
         return fields_equal(ls.fields, ls.fields_len, rs.fields, rs.fields_len)
      end
      return true
   elseif lhs is UnionType and rhs is UnionType then
      local lu = lhs
      local ru = rhs
      local lu_name = view_to_optional_string(lu.name)
      local ru_name = view_to_optional_string(ru.name)
      if lu_name ~= ru_name then
         local lhs_anon = lu_name == nil
         local rhs_anon = ru_name == nil
         if (lhs_anon or rhs_anon) and lu.complete and ru.complete then
            return fields_equal(lu.fields, lu.fields_len, ru.fields, ru.fields_len)
         end
         return false
      end
      if lu.complete and ru.complete then
         return fields_equal(lu.fields, lu.fields_len, ru.fields, ru.fields_len)
      end
      return true
   elseif lhs is EnumType and rhs is EnumType then
      local le = lhs
      local re = rhs
      local le_name = view_to_optional_string(le.name)
      local re_name = view_to_optional_string(re.name)
      if le_name ~= re_name then
         return false
      end
      if le.complete and re.complete then
         return enum_values_equal(le.values, le.values_len, re.values, re.values_len)
      end
      return true
   elseif lhs is QualifiedType and rhs is QualifiedType then
      local lq = lhs
      local rq = rhs
      if not qualifier_set_equal(lq.qualifiers, lq.qualifiers_len, rq.qualifiers, rq.qualifiers_len) then
         return false
      end
      if lq.of == nil or rq.of == nil then
         return lq.of == rq.of
      end
      return types_equal(lq.of[0], rq.of[0])
   elseif lhs is TypedefType and rhs is TypedefType then
      return view_to_string(lhs.name) == view_to_string(rhs.name)
   end

   return false
end

return {
   TypeTag = TypeTag,
   BuiltinName = BuiltinName,
   TypeQualifier = TypeQualifier,
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
