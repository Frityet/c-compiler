package.path = "src/?.tl;src/?/init.tl;build/?.lua;build/?/init.lua;src/?.lua;src/?/init.lua;" .. package.path

local tl = require("tl")
tl.loader()

local ffi = require("ffi")
local Span = require("util.span")
local TLStringView = require("util.string_view")
local types = require("sema.types-ffi")

local TypeTag = types.TypeTag
local BuiltinName = types.BuiltinName
local TypeQualifier = types.TypeQualifier
local equals = types.equals

local dummy_span = Span.new(0, 0, 0, 1, 1)

local keepalive = {}

before_each(function()
   keepalive = {}
end)

local function keep(obj)
   table.insert(keepalive, obj)
   return obj
end

local function sv(s)
   if s == nil or s == "" then
      return TLStringView.new(nil, 0)
   end
   local buf = ffi.new("const char[?]", #s + 1, s)
   keep(buf)
   return TLStringView.new(buf, #s)
end

local function type_ptr(node)
   local storage = ffi.cast("union TypeNode *", node)
   return keep(storage)
end

local function set_qualifiers(target, qs)
   local n = #qs
   target.qualifiers_len = n
   for i = 1, n do
      target.qualifiers[i - 1] = qs[i]
   end
end

local function make_builtin(name, opts)
   local ty = ffi.new("struct BuiltinType")
   ty.tag = TypeTag.BUILTIN
   ty.span = dummy_span
   ty.name = name
   ty.is_signed = opts and opts.is_signed or false
   ty.is_complex = opts and opts.is_complex or false
   ty.is_imaginary = opts and opts.is_imaginary or false
   return ty
end

local function make_typedef(name)
   local ty = ffi.new("struct TypedefType")
   ty.tag = TypeTag.TYPEDEF
   ty.span = dummy_span
   ty.name = sv(name)
   return ty
end

local function make_pointer(target, qs)
   local ty = ffi.new("struct PointerType")
   ty.tag = TypeTag.POINTER
   ty.span = dummy_span
   ty.to = type_ptr(target)
   set_qualifiers(ty, qs)
   return ty
end

local function make_array(base, size, qs, opts)
   local ty = ffi.new("struct ArrayType")
   ty.tag = TypeTag.ARRAY
   ty.span = dummy_span
   ty.of = type_ptr(base)
   ty.size = size
   ty.size_expr = nil
   ty.has_size = not (opts and opts.has_size == false)
   ty.is_vla = opts and opts.is_vla or false
   ty.is_static = opts and opts.is_static or false
   set_qualifiers(ty, qs)
   return ty
end

local function make_function(ret, params, is_variadic)
   local count = #params
   local arr = nil
   if count > 0 then
      local raw = ffi.new("struct FunctionParam[?]", count)
      for i = 1, count do
         local p = params[i]
         raw[i - 1] = {
            name = sv(p.name),
            type = type_ptr(p.ty),
            span = dummy_span,
         }
      end
      arr = keep(raw)
   end

   local ty = ffi.new("struct FunctionType")
   ty.tag = TypeTag.FUNCTION
   ty.span = dummy_span
   ty.returns = type_ptr(ret)
   ty.params = arr
   ty.params_len = count
   ty.is_variadic = is_variadic or false
   return ty
end

local function make_field(name, ty)
   local f = ffi.new("struct Field")
   f.name = sv(name)
   f.type = type_ptr(ty)
   f.bit_width = 0
   f.has_bit_width = false
   return f
end

local function make_struct(name, fields, complete)
   local arr = ffi.new("struct Field[?]", #fields)
   for i = 1, #fields do
      arr[i - 1] = fields[i]
   end
   local ty = ffi.new("struct StructType")
   ty.tag = TypeTag.STRUCT
   ty.span = dummy_span
   ty.name = sv(name)
   ty.fields = keep(arr)
   ty.fields_len = #fields
   ty.complete = complete
   return ty
end

local function make_union(name, fields, complete)
   local arr = ffi.new("struct Field[?]", #fields)
   for i = 1, #fields do
      arr[i - 1] = fields[i]
   end
   local ty = ffi.new("struct UnionType")
   ty.tag = TypeTag.UNION
   ty.span = dummy_span
   ty.name = sv(name)
   ty.fields = keep(arr)
   ty.fields_len = #fields
   ty.complete = complete
   return ty
end

local function make_enum_const(name, value)
   local c = ffi.new("struct EnumConst")
   c.name = sv(name)
   c.value = value or 0
   c.has_value = not (value == nil)
   c.span = dummy_span
   return c
end

local function make_enum(name, underlying, values, complete)
   local arr = ffi.new("struct EnumConst[?]", #values)
   for i = 1, #values do
      arr[i - 1] = values[i]
   end
   local ty = ffi.new("struct EnumType")
   ty.tag = TypeTag.ENUM
   ty.span = dummy_span
   ty.name = sv(name)
   ty.underlying = type_ptr(underlying)
   ty.values = keep(arr)
   ty.values_len = #values
   ty.complete = complete
   return ty
end

local function make_qualified(base, qs)
   local ty = ffi.new("struct QualifiedType")
   ty.tag = TypeTag.QUALIFIED
   ty.span = dummy_span
   ty.of = type_ptr(base)
   set_qualifiers(ty, qs)
   return ty
end

describe("types-ffi equality", function()
   it("compares builtin types by name and flags", function()
      local a = make_builtin(BuiltinName.INT, { is_signed = true })
      local b = make_builtin(BuiltinName.INT, { is_signed = true })
      local c = make_builtin(BuiltinName.UINT, { is_signed = false })
      assert.is_true(equals(a, b))
      assert.is_false(equals(a, c))
   end)

   it("compares typedef names via TLStringView content", function()
      local a = make_typedef("size_t")
      local b = make_typedef("size_t")
      local c = make_typedef("ptrdiff_t")
      assert.is_true(equals(a, b))
      assert.is_false(equals(a, c))
   end)

   it("compares pointer qualifiers and targets", function()
      local base = make_builtin(BuiltinName.INT, { is_signed = true })
      local ptr_const = make_pointer(base, { TypeQualifier.CONST })
      local ptr_const_2 = make_pointer(base, { TypeQualifier.CONST })
      local ptr_plain = make_pointer(base, {})
      assert.is_true(equals(ptr_const, ptr_const_2))
      assert.is_false(equals(ptr_const, ptr_plain))
   end)

   it("compares arrays including size, VLA/static flags, qualifiers, and element type", function()
      local base = make_builtin(BuiltinName.UCHAR, {})
      local arr_a = make_array(base, 4, { TypeQualifier.RESTRICT }, { is_static = true })
      local arr_b = make_array(base, 4, { TypeQualifier.RESTRICT }, { is_static = true })
      local arr_c = make_array(base, 8, { TypeQualifier.RESTRICT }, { is_static = true })
      local arr_d = make_array(base, 4, {}, { is_static = true })
      assert.is_true(equals(arr_a, arr_b))
      assert.is_false(equals(arr_a, arr_c))
      assert.is_false(equals(arr_a, arr_d))
   end)

   it("compares function signatures by params, return type, and variadic flag", function()
      local ret = make_builtin(BuiltinName.VOID, {})
      local param_ty = make_pointer(make_builtin(BuiltinName.CHAR, {}), {})
      local fn_a = make_function(ret, { { name = "p", ty = param_ty } }, false)
      local fn_b = make_function(ret, { { name = "q", ty = param_ty } }, false)
      local fn_var = make_function(ret, { { name = "p", ty = param_ty } }, true)
      local fn_diff = make_function(ret, {}, false)
      assert.is_true(equals(fn_a, fn_b))
      assert.is_false(equals(fn_a, fn_var))
      assert.is_false(equals(fn_a, fn_diff))
   end)

   it("compares struct types using names when present and fields when anonymous", function()
      local field_ty = make_builtin(BuiltinName.INT, { is_signed = true })
      local field = make_field("x", field_ty)
      local named_a = make_struct("S", { field }, false)
      local named_b = make_struct("S", { field }, true)
      local named_c = make_struct("T", { field }, false)
      assert.is_true(equals(named_a, named_b))
      assert.is_false(equals(named_a, named_c))

      local anon_a = make_struct(nil, { field }, true)
      local anon_b = make_struct(nil, { field }, true)
      assert.is_true(equals(anon_a, anon_b))
   end)

   it("compares union types with the same semantics as structs", function()
      local field_ty = make_builtin(BuiltinName.SHORT, { is_signed = true })
      local f = make_field("u", field_ty)
      local named_a = make_union("U", { f }, false)
      local named_b = make_union("U", { f }, true)
      local named_c = make_union("V", { f }, false)
      assert.is_true(equals(named_a, named_b))
      assert.is_false(equals(named_a, named_c))

      local anon_a = make_union(nil, { f }, true)
      local anon_b = make_union(nil, { f }, true)
      assert.is_true(equals(anon_a, anon_b))
   end)

   it("compares enum types by name and value list when complete", function()
      local underlying = make_builtin(BuiltinName.INT, { is_signed = true })
      local values_a = { make_enum_const("A", 1), make_enum_const("B", 2) }
      local values_b = { make_enum_const("A", 1), make_enum_const("B", 2) }
      local values_c = { make_enum_const("A", 1), make_enum_const("C", 3) }
      local enum_a = make_enum("E", underlying, values_a, true)
      local enum_b = make_enum("E", underlying, values_b, true)
      local enum_c = make_enum("E", underlying, values_c, true)
      local enum_named = make_enum("F", underlying, values_a, true)
      assert.is_true(equals(enum_a, enum_b))
      assert.is_false(equals(enum_a, enum_c))
      assert.is_false(equals(enum_a, enum_named))
   end)

   it("compares qualified types by qualifiers and base", function()
      local base = make_builtin(BuiltinName.DOUBLE, {})
      local qual_a = make_qualified(base, { TypeQualifier.CONST, TypeQualifier.VOLATILE })
      local qual_b = make_qualified(base, { TypeQualifier.VOLATILE, TypeQualifier.CONST })
      local qual_c = make_qualified(base, { TypeQualifier.CONST })
      assert.is_true(equals(qual_a, qual_b))
      assert.is_false(equals(qual_a, qual_c))
   end)
end)
