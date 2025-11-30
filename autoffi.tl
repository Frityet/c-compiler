local ffi = require("ffi")

local macro autoffi!(rec: Statement): Statement
   local blk = require("teal.block")
   local type Block = blk.Block
   local type BlockKind = blk.BlockKind
   local BI = blk.BLOCK_INDEXES

   local record TypeInfo
      ctype: string
      teal_type: Block
   end

   local record FieldInfo
      name: string
      name_block: Block
      ctype: string
      teal_type: Block
   end

   local function clone_block(b: Block): Block
      local out: Block = {
         kind = b.kind,
         f = b.f,
         y = b.y,
         x = b.x,
         tk = b.tk,
         yend = b.yend,
         xend = b.xend,
         constnum = b.constnum,
         conststr = b.conststr,
         is_longstring = b.is_longstring,
      }
      for i = 1, #b do
         local child = b[i]
         if child then
            out[i] = clone_block(child)
         end
      end
      return out
   end

   local function make_identifier(name: string): Block
      local id = block("identifier")
      id.tk = name
      return id
   end

   local function make_variable(name: string): Block
      local var = block("variable")
      var.tk = name
      return var
   end

   local function make_string_literal(s: string, is_long: boolean): Block
      local str = block("string")
      str.conststr = s
      if is_long then
         str.tk = "[[" .. s .. "]]"
         str.is_longstring = true
      else
         str.tk = '"' .. s .. '"'
      end
      return str
   end

   local function make_nominal_from_parts(parts: {string}): Block
      local t = block("nominal_type")
      t.tk = parts[1]
      for i, p in ipairs(parts) do
         t[i] = make_identifier(p)
      end
      return t
   end

   local function nominal_parts(t: Block): {string}
      local parts: {string} = {}
      if t.kind ~= "nominal_type" then
         return parts
      end
      for i = 1, #t do
         local child = t[i]
         if child and child.kind == "identifier" then
            table.insert(parts, child.tk)
         end
      end
      return parts
   end

   local function first_typearg(t: Block): Block | nil
      for i = 1, #t do
         local child = t[i]
         if child and child.kind == "typelist" then
            return child[BI.TYPELIST.FIRST]
         end
      end
      return nil
   end

   local function build_argument_type(name: string, typ: Block): Block
      local at = block("argument_type")
      local name_id = make_identifier(name)
      at[BI.ARGUMENT_TYPE.NAME] = name_id
      at[2] = typ
      return at
   end

   local function build_tuple_type(types: {Block}): Block
      local tlist = block("typelist")
      for i, ty in ipairs(types) do
         tlist[i] = ty
      end
      local tt = block("tuple_type")
      tt[BI.TUPLE_TYPE.FIRST] = tlist
      return tt
   end

   local function build_function_type(args: {Block}, ret: Block): Block
      local fn = block("function")
      local arg_tuple = build_tuple_type(args)
      fn[BI.FUNCTION_TYPE.ARGS] = arg_tuple
      local ret_tuple = build_tuple_type({ ret })
      fn[BI.FUNCTION_TYPE.RETS] = ret_tuple
      return fn
   end

   local function build_meta_call_field(struct_name: string, fields: {FieldInfo}): Block
      local meta_body = block("record_body")

      local args: {Block} = {}
      table.insert(args, build_argument_type("self", make_nominal_from_parts({ struct_name })))
      for _, f in ipairs(fields) do
         table.insert(args, build_argument_type(f.name, clone_block(f.teal_type)))
      end

      local meta_call = block("record_field")
      meta_call[BI.RECORD_FIELD.NAME] = make_variable("__call")
      meta_call[BI.RECORD_FIELD.TYPE] = build_function_type(args, make_nominal_from_parts({ struct_name }))
      table.insert(meta_body, meta_call)

      return meta_body
   end

   local function field_name_from_block(name_block: Block): string
      if name_block.kind == "variable" or name_block.kind == "identifier" then
         return name_block.tk
      elseif name_block.kind == "string" and name_block.conststr then
         return name_block.conststr
      end
      error("autoffi!: unsupported field name kind " .. tostring(name_block.kind))
   end

   local function convert_type(t: Block): TypeInfo
      if t.kind == "union_type" then
         local primary: Block | nil = nil
         local nil_child: Block | nil = nil
         for i = 1, #t do
            local child = t[i]
            if child then
               if child.kind == "nil" then
                  nil_child = child
               elseif not primary then
                  primary = child
               else
                  error("autoffi!: unions with more than one non-nil member are not supported")
               end
            end
         end
         if not primary or not nil_child then
            error("autoffi!: union types must include exactly one non-nil member")
         end
         local mapped = convert_type(primary)
         local union = block("union_type")
         union[BI.UNION_TYPE.FIRST] = mapped.teal_type
         union[2] = clone_block(nil_child)
         return { ctype = mapped.ctype, teal_type = union }
      end

      if t.kind ~= "nominal_type" then
         error("autoffi!: unsupported type node '" .. tostring(t.kind) .. "'")
      end

      local parts = nominal_parts(t)
      if #parts == 0 then
         error("autoffi!: unnamed nominal type")
      end

      if #parts == 1 then
         local base = parts[1]
         if base == "int" then
            return { ctype = "int", teal_type = make_nominal_from_parts({ "integer" }) }
         elseif base == "long" then
            return { ctype = "long", teal_type = make_nominal_from_parts({ "integer" }) }
         elseif base == "float" then
            return { ctype = "float", teal_type = make_nominal_from_parts({ "number" }) }
         elseif base == "double" then
            return { ctype = "double", teal_type = make_nominal_from_parts({ "number" }) }
         end
         local struct_name = parts[1]
         return {
            ctype = "struct " .. struct_name,
            teal_type = clone_block(t),
         }
      end

      if parts[1] == "ffi" then
         local head = parts[2] or ""
         if head == "CString" or head == "String" then
            return {
               ctype = "const char *",
               teal_type = clone_block(t),
            }
         elseif head == "Pointer" then
            local arg = first_typearg(t)
            if not arg then
               error("autoffi!: ffi.Pointer is missing a type argument")
            end
            local inner = convert_type(arg)
            return {
               ctype = inner.ctype .. " *",
               teal_type = clone_block(t),
            }
         end
         error("autoffi!: unsupported ffi type '" .. head .. "'")
      end

      local struct_name = parts[#parts]
      return {
         ctype = "struct " .. struct_name,
         teal_type = clone_block(t),
      }
   end

   local function collect_fields(body: Block): {FieldInfo}
      local fields: {FieldInfo} = {}
      for _, child in ipairs(body) do
         if child and child.kind == "record_field" then
            local name_node = child[BI.RECORD_FIELD.NAME]
            local type_node = child[BI.RECORD_FIELD.TYPE]
            if not name_node or not type_node then
               error("autoffi!: record fields must have a name and type")
            end
            local converted = convert_type(type_node)
            table.insert(fields, {
               name = field_name_from_block(name_node),
               name_block = clone_block(name_node),
               ctype = converted.ctype,
               teal_type = converted.teal_type,
            })
         end
      end
      return fields
   end

   local function render_cdef(struct_name: string, fields: {FieldInfo}): string
      local lines: {string} = {}
      table.insert(lines, "struct " .. struct_name .. " {\n")
      for _, f in ipairs(fields) do
         local spacer = f.ctype:match("%*$") and "" or " "
         table.insert(lines, "   " .. f.ctype .. spacer .. f.name .. ";\n")
      end
      table.insert(lines, "};\n")
      return table.concat(lines)
   end

   local function build_where_clause(struct_name: string, rec_block: Block): Block
      local where_macro = block("macroexp")

      local args = block("argument_list")
      local self_arg = block("argument")
      self_arg.tk = "self"
      local self_annot = block("nominal_type")
      self_annot.tk = "self"
      self_annot[BI.NOMINAL_TYPE.NAME] = rec_block
      self_arg[BI.ARGUMENT.ANNOTATION] = self_annot
      args[BI.ARGUMENT_LIST.FIRST] = self_arg
      where_macro[BI.MACROEXP.ARGS] = args

      local rets = block("tuple_type")
      local ret_bool = block("boolean")
      ret_bool.tk = "boolean"
      rets[BI.TUPLE_TYPE.FIRST] = ret_bool
      where_macro[BI.MACROEXP.RETS] = rets

      local callee = block("op_dot")
      callee[BI.OP.E1] = make_variable("ffi")
      callee[BI.OP.E2] = make_identifier("istype")

      local call_args = block("expression_list")
      local struct_string = block("string")
      struct_string.conststr = "struct " .. struct_name
      struct_string.tk = '"' .. struct_string.conststr .. '"'
      call_args[BI.EXPRESSION_LIST.FIRST] = struct_string
      call_args[BI.EXPRESSION_LIST.SECOND] = make_variable("self")

      local call = block("op_funcall")
      call[BI.OP.E1] = callee
      call[BI.OP.E2] = call_args

      where_macro[BI.MACROEXP.EXP] = call

      return where_macro
   end

   local function build_record(struct_name: string, decl_kind: BlockKind, fields: {FieldInfo}, source_record: Block): Block
      local record_block = clone_block(source_record)
      local iface_list = block("interface_list")
      iface_list[BI.INTERFACE_LIST.FIRST] = make_nominal_from_parts({ "ffi", "CData" })
      record_block[BI.RECORD.INTERFACES] = iface_list

      local body = block("record_body")
      for _, f in ipairs(fields) do
         local field_block = block("record_field")
         field_block.tk = f.name
         field_block[BI.RECORD_FIELD.NAME] = f.name_block
         field_block[BI.RECORD_FIELD.TYPE] = clone_block(f.teal_type)
         table.insert(body, field_block)
      end
      record_block[BI.RECORD.FIELDS] = body
      record_block[BI.RECORD.WHERE_CLAUSE] = build_where_clause(struct_name, record_block)
      record_block[BI.RECORD.META_FIELDS] = build_meta_call_field(struct_name, fields)
      record_block[BI.RECORD.ARRAY_TYPE] = nil

      local td = block("typedecl")
      td[BI.TYPEDECL.TYPE] = record_block

      local nt = block("newtype")
      nt[BI.NEWTYPE.TYPEDECL] = td

      local decl = block(decl_kind)
      local type_indexes = decl_kind == "global_type" and BI.GLOBAL_TYPE or BI.LOCAL_TYPE
      decl[type_indexes.VAR] = make_identifier(struct_name)
      decl[type_indexes.VALUE] = nt

      return decl
   end

   local function build_cdef_statement(cdef_src: string): Block
      local cdef_call = block("op_funcall")
      local callee = block("op_dot")
      callee[BI.OP.E1] = make_variable("ffi")
      callee[BI.OP.E2] = make_identifier("cdef")

      local args = block("expression_list")
      local str = block("string")
      str.conststr = cdef_src
      str.tk = "[[" .. cdef_src .. "]]"
      str.is_longstring = true
      args[BI.EXPRESSION_LIST.FIRST] = str

      cdef_call[BI.OP.E1] = callee
      cdef_call[BI.OP.E2] = args
      return cdef_call
   end

   local function build_new_function(struct_name: string, fields: {FieldInfo}): Block
      local fn = block("function")
      local args = block("argument_list")

      local ct_arg = block("argument")
      ct_arg.tk = "ct"
      ct_arg[BI.ARGUMENT.ANNOTATION] = make_nominal_from_parts({ "ffi", "CType" })
      args[1] = ct_arg

      for i, f in ipairs(fields) do
         local arg = block("argument")
         arg.tk = f.name
         arg[BI.ARGUMENT.ANNOTATION] = clone_block(f.teal_type)
         args[i + 1] = arg
      end
      fn[BI.FUNCTION.ARGS] = args

      local ret_tuple = block("tuple_type")
      local ret_list = block("typelist")
      ret_list[1] = make_nominal_from_parts({ struct_name })
      ret_tuple[BI.TUPLE_TYPE.FIRST] = ret_list
      fn[BI.FUNCTION.RETS] = ret_tuple

      local call_args = block("expression_list")
      call_args[BI.EXPRESSION_LIST.FIRST] = make_variable("ct")
      for i, f in ipairs(fields) do
         call_args[i + 1] = make_variable(f.name)
      end

      local call = block("op_funcall")
      local callee = block("op_dot")
      callee[BI.OP.E1] = make_variable("ffi")
      callee[BI.OP.E2] = make_identifier("new")
      call[BI.OP.E1] = callee
      call[BI.OP.E2] = call_args

      local ret_stmt = block("return")
      local ret_exps = block("expression_list")
      ret_exps[BI.EXPRESSION_LIST.FIRST] = call
      ret_stmt[BI.RETURN.EXPS] = ret_exps

      local body = block("statements")
      body[1] = ret_stmt
      fn[BI.FUNCTION.BODY] = body

      return fn
   end

   local function build_call_function(struct_name: string, fields: {FieldInfo}, ctor_name: string): Block
      local fn = block("function")
      local args = block("argument_list")

      local self_arg = block("argument")
      self_arg.tk = "_self"
      self_arg[BI.ARGUMENT.ANNOTATION] = make_nominal_from_parts({ struct_name })
      args[1] = self_arg

      for i, f in ipairs(fields) do
         local arg = block("argument")
         arg.tk = f.name
         arg[BI.ARGUMENT.ANNOTATION] = clone_block(f.teal_type)
         args[i + 1] = arg
      end
      fn[BI.FUNCTION.ARGS] = args

      local ret_tuple = block("tuple_type")
      local ret_list = block("typelist")
      ret_list[1] = make_nominal_from_parts({ struct_name })
      ret_tuple[BI.TUPLE_TYPE.FIRST] = ret_list
      fn[BI.FUNCTION.RETS] = ret_tuple

      local call_args = block("expression_list")
      for i, f in ipairs(fields) do
         call_args[i] = make_variable(f.name)
      end

      local call = block("op_funcall")
      call[BI.OP.E1] = make_variable(ctor_name)
      call[BI.OP.E2] = call_args

      local ret_stmt = block("return")
      local ret_exps = block("expression_list")
      ret_exps[BI.EXPRESSION_LIST.FIRST] = call
      ret_stmt[BI.RETURN.EXPS] = ret_exps

      local body = block("statements")
      body[1] = ret_stmt
      fn[BI.FUNCTION.BODY] = body

      return fn
   end

   local function build_metatype_statements(struct_name: string, fields: {FieldInfo}): {Block}
      local ctor_var = struct_name .. "__ctor"
      local record_var = make_variable(struct_name)

      local meta_table = block("literal_table")
      local index_item = block("literal_table_item")
      index_item[BI.LITERAL_TABLE_ITEM.KEY] = make_string_literal("__index", false)
      index_item[BI.LITERAL_TABLE_ITEM.VALUE] = clone_block(record_var)
      table.insert(meta_table, index_item)

      local new_item = block("literal_table_item")
      new_item[BI.LITERAL_TABLE_ITEM.KEY] = make_string_literal("__new", false)
      new_item[BI.LITERAL_TABLE_ITEM.VALUE] = build_new_function(struct_name, fields)
      table.insert(meta_table, new_item)

      local metatype_call = block("op_funcall")
      local metatype_callee = block("op_dot")
      metatype_callee[BI.OP.E1] = make_variable("ffi")
      metatype_callee[BI.OP.E2] = make_identifier("metatype")
      metatype_call[BI.OP.E1] = metatype_callee

      local metatype_args = block("expression_list")
      metatype_args[BI.EXPRESSION_LIST.FIRST] = make_string_literal("struct " .. struct_name, false)
      metatype_args[BI.EXPRESSION_LIST.SECOND] = meta_table
      metatype_call[BI.OP.E2] = metatype_args

      local ctor_decl = block("local_declaration")
      local vars = block("variable_list")
      vars[BI.VARIABLE_LIST.FIRST] = make_identifier(ctor_var)
      ctor_decl[BI.LOCAL_DECLARATION.VARS] = vars
      ctor_decl[BI.LOCAL_DECLARATION.EXPS] = block("expression_list")
      ctor_decl[BI.LOCAL_DECLARATION.EXPS][BI.EXPRESSION_LIST.FIRST] = metatype_call

      local mt_table = block("literal_table")
      local call_item = block("literal_table_item")
      call_item[BI.LITERAL_TABLE_ITEM.KEY] = make_string_literal("__call", false)
      call_item[BI.LITERAL_TABLE_ITEM.VALUE] = build_call_function(struct_name, fields, ctor_var)
      table.insert(mt_table, call_item)

      local table_index_item = block("literal_table_item")
      table_index_item[BI.LITERAL_TABLE_ITEM.KEY] = make_string_literal("__index", false)
      table_index_item[BI.LITERAL_TABLE_ITEM.VALUE] = clone_block(record_var)
      table.insert(mt_table, table_index_item)

      local setmeta_call = block("op_funcall")
      setmeta_call[BI.OP.E1] = make_variable("setmetatable")
      local setmeta_args = block("expression_list")
      setmeta_args[BI.EXPRESSION_LIST.FIRST] = clone_block(record_var)
      setmeta_args[BI.EXPRESSION_LIST.SECOND] = mt_table
      setmeta_call[BI.OP.E2] = setmeta_args

      return { ctor_decl, setmeta_call }
   end

   if rec.kind ~= "statements" then
      error("autoffi!: expected a Statement argument")
   end

   local decl = rec[1]
   if not decl or (decl.kind ~= "local_type" and decl.kind ~= "global_type") then
      error("autoffi!: macro expects a local/global record declaration")
   end

   local decl_indexes = decl.kind == "global_type" and BI.GLOBAL_TYPE or BI.LOCAL_TYPE
   local name_block = expect(decl[decl_indexes.VAR], "identifier")
   if not name_block then
      return rec
   end
   local struct_name = name_block.tk
   if struct_name == "" then
      error("autoffi!: record name cannot be empty")
   end

   local nt = expect(decl[decl_indexes.VALUE], "newtype")
   if not nt then
      return rec
   end
   local td = expect(nt[BI.NEWTYPE.TYPEDECL], "typedecl")
   if not td then
      return rec
   end
   local record_def = expect(td[BI.TYPEDECL.TYPE], "record")
   if not record_def then
      return rec
   end
   local body = record_def[BI.RECORD.FIELDS]
   if not body then
      error("autoffi!: record is missing a body")
   end

   local fields = collect_fields(body)
   if #fields == 0 then
      error("autoffi!: record must declare at least one field")
   end

   local out = block("statements")
   table.insert(out, build_cdef_statement(render_cdef(struct_name, fields)))
   table.insert(out, build_record(struct_name, decl.kind, fields, record_def))
   for _, s in ipairs(build_metatype_statements(struct_name, fields)) do
      table.insert(out, s)
   end
   return out
end

autoffi!(
   local record Point
      x: double
      y: double
   end
)

autoffi!(
   local record MyRecord
      a: int
      b: float
      s: ffi.String

      p_len: long
      p: ffi.Pointer<Point>
   end
)

function MyRecord:print()
   local count: integer = (tonumber(self.p_len) or 0) as integer
   print(string.format("MyRecord { a=%d, b=%f, s=%s, p_len=%d }", self.a, self.b, ffi.string(self.s as ffi.CString), count))
   for i = 0, count - 1 do
      local idx: integer = (i as integer)
      local pt = self.p[idx]
      print(string.format("  Point[%d] { x=%f, y=%f }", idx, pt.x, pt.y))
   end
end


local points: ffi.Pointer<Point> = ffi.cast("struct Point *", ffi.new("struct Point[3]", {
   Point(1.0, 2.0),
   Point(3.0, 4.0),
   Point(5.0, 6.0),
}))

local x = MyRecord(1, 4.12, "hello", 3, points)

x:print()
