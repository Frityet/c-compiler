local Preprocessor = require("pp.preprocessor")
local Parser = require("parser.parser")
local Checker = require("sema.checker")
local Reporter = require("diag.reporter")
local LexerFast = require("lexer.lexer")
local Target = require("util.target")
local Diagnostic = require("diag.diagnostics")
local types = require("sema.types")
local ast = require("parser.ast")
local fs = require("util.fs")

local type TypeNode = types.TypeNode
local type TranslationUnit = ast.TranslationUnit
local type Token = LexerFast.Token
local types_equal = types.equals
local record FileContext
   path: string | nil
   source: string | nil
   lines: {string} | nil
end

local record GenerateOptions
   headers: {string}
   output: string | nil
   lib_name: string | nil
   ignore_system_includes: boolean | nil
   max_errors: integer | nil
   diagnostic_level: Diagnostic.Severity
   load_library: string | nil
   strip_prefix: string | nil
end

local record Collected
   structs: {string: types.StructType}
   unions: {string: types.UnionType}
   enums: {string: types.EnumType}
   typedefs: {string: TypeNode}
   functions: {string: types.FunctionType}
   warnings: {string}
   forwards: {string: string}
end

local record Rendered
   path: string
   content: string | nil
   warnings: {string}
end

local function path_dir(p: string): string
   local dir = p:match("^(.*)/[^/]+$")
   if dir is nil or dir == "" then
      return "."
   end
   return dir
end

local function basename_no_ext(p: string): string
   local base = p:match("([^/]+)$") or p
   return (base:gsub("%.[^%.]+$", ""))
end

local function default_output(headers: {string}): string
   local first = headers[1] or "ffi"
   return basename_no_ext(first) .. ".ffi.tl"
end

local HOST_TARGET = Target.detect()
local SYSTEM_PREFIXES = Target.system_prefixes(HOST_TARGET)

local function is_system_path(path: string): boolean
   for _, pref in ipairs(SYSTEM_PREFIXES) do
      if string.sub(path, 1, #pref) == pref then
         return true
      end
   end
   if path:match("^/usr/") or path:match("^/System/") or path:match("^/Library/Developer/CommandLineTools") then
      return true
   end
   return false
end

local function sanitize(name: string): string
   local out = name:gsub("[^%w_]", "_")
   if out:match("^[%d]") then
      out = "_" .. out
   end
   return out
end

local function has_storage(specs: ast.DeclSpecifiers, name: ast.StorageClass): boolean
   for _, s in ipairs(specs.storage) do
      if s == name then
         return true
      end
   end
   return false
end

local function qualifiers_to_string(qs: {types.TypeQualifier}): string
   if #qs == 0 then
      return ""
   end
   return table.concat(qs, " ")
end

local function builtin_to_c(b: types.BuiltinType): string
   local n = b.name
   if n == "void" then
      return "void"
   elseif n == "bool" then
      return "_Bool"
   elseif n == "char" then
      return "char"
   elseif n == "schar" then
      return "signed char"
   elseif n == "uchar" then
      return "unsigned char"
   elseif n == "short" then
      return "short"
   elseif n == "ushort" then
      return "unsigned short"
   elseif n == "int" then
      return "int"
   elseif n == "uint" then
      return "unsigned int"
   elseif n == "long" then
      return "long"
   elseif n == "ulong" then
      return "unsigned long"
   elseif n == "long_long" then
      return "long long"
   elseif n == "ulong_long" then
      return "unsigned long long"
   elseif n == "float" then
      return "float"
   elseif n == "double" then
      return "double"
   elseif n == "long_double" then
      return "long double"
   end
   return n
end

local function base_type_to_c(ty: TypeNode): string | nil
   if ty is types.BuiltinType then
      return builtin_to_c(ty)
   elseif ty is types.StructType then
      return ty.name and ("struct " .. ty.name) or nil
   elseif ty is types.UnionType then
      return ty.name and ("union " .. ty.name) or nil
   elseif ty is types.EnumType then
      return ty.name and ("enum " .. ty.name) or nil
   elseif ty is types.TypedefType then
      return ty.name
   elseif ty is types.QualifiedType then
      local inner = base_type_to_c(ty.of)
      if not inner then
         return nil
      end
      local quals = qualifiers_to_string(ty.qualifiers)
      if quals ~= "" then
         return quals .. " " .. inner
      end
      return inner
   end
   return nil
end

local function render_c_type(ty: TypeNode, name: string, contextsuffix: string, ctx: string, is_typedef?: boolean): string | nil
   -- ctx = "param" to decay arrays, otherwise emit raw.
   if ty is types.PointerType then
      local target = ty.to
      if is_typedef and name ~= "" and target.tag == "function" then
         local fn_ty = target as types.FunctionType
         local params: {string} = {}
         for _, p in ipairs(fn_ty.params) do
            local pname = p.name and p.name or ""
            local param_str = render_c_type(p.type, pname, "", "param", is_typedef)
            if not param_str then
               return nil
            end
            table.insert(params, param_str)
         end
         if fn_ty.is_variadic then
            table.insert(params, "...")
         elseif #params == 0 then
            table.insert(params, "void")
         end
         local ret = render_c_type(fn_ty.returns, "", "", ctx, is_typedef)
         if not ret then
            return nil
         end
         return string.format("%s (*%s)(%s)%s", ret, name, table.concat(params, ", "), contextsuffix)
      end
      local quals = qualifiers_to_string(ty.qualifiers)
      local ptr_pref = "*" .. (quals ~= "" and (" " .. quals) or "")
      local inner_name = ptr_pref .. (name ~= "" and (" " .. name) or name)
      if contextsuffix ~= "" then
         inner_name = "(" .. inner_name .. ")"
      end
      return render_c_type(ty.to, inner_name, contextsuffix, ctx, is_typedef)
   elseif ty is types.ArrayType then
      if ctx == "param" then
         local ptr: types.PointerType = { tag = "pointer", span = ty.span, to = ty.of, qualifiers = {} }
         return render_c_type(ptr, name, contextsuffix, ctx, is_typedef)
      end
      if ty.is_vla then
         return nil
      end
      local dim = ""
      local size_val = ty.size
      local size_expr = ty.size_expr
      if not size_val is nil then
         dim = tostring(size_val)
      elseif not size_expr is nil then
         local ptr: types.PointerType = { tag = "pointer", span = ty.span, to = ty.of, qualifiers = {} }
         return render_c_type(ptr, name, contextsuffix, ctx, is_typedef)
      end
      local suffix = string.format("[%s]%s", dim, contextsuffix)
      local inner_name = name
      if contextsuffix ~= "" then
         inner_name = "(" .. inner_name .. ")"
      end
      return render_c_type(ty.of, inner_name, suffix, ctx, is_typedef)
   elseif ty is types.FunctionType then
      local params: {string} = {}
      for _, p in ipairs(ty.params) do
         local pname = p.name and p.name or ""
         local param_str = render_c_type(p.type, pname, "", "param", is_typedef)
         if not param_str then
            return nil
         end
         table.insert(params, param_str)
      end
      if ty.is_variadic then
         table.insert(params, "...")
      elseif #params == 0 then
         table.insert(params, "void")
      end
      local call_sig = "(" .. table.concat(params, ", ") .. ")"
      local ret = render_c_type(ty.returns, "", "", ctx, is_typedef)
      if not ret then
         return nil
      end
      local inner_name = name
      if is_typedef and name ~= "" then
         inner_name = string.format("(*%s)", name)
      elseif contextsuffix ~= "" and name ~= "" then
         inner_name = "(" .. name .. ")"
      end
      if inner_name ~= "" then
         return string.format("%s %s%s%s", ret, inner_name, call_sig, contextsuffix)
      end
      return string.format("%s%s%s", ret, call_sig, contextsuffix)
   elseif ty is types.QualifiedType then
      local inner = render_c_type(ty.of, name, contextsuffix, ctx, is_typedef)
      if not inner then
         return nil
      end
      local quals = qualifiers_to_string(ty.qualifiers)
      if quals ~= "" then
         return quals .. " " .. inner
      end
      return inner
   else
      if ty is types.StructType then
         local sname = ty.name
         if sname is nil and is_typedef and ctx == "default" then
            local parts: {string} = {}
            for _, f in ipairs(ty.fields) do
               local bw = f.bit_width
               if bw is nil and f.name ~= "" then
                  local fdecl = render_c_type(f.type, f.name, "", ctx, is_typedef)
                  if not fdecl then
                     return nil
                  end
                  table.insert(parts, fdecl .. ";")
               end
            end
            return string.format("struct { %s } %s%s", table.concat(parts, " "), name, contextsuffix)
         end
      elseif ty is types.UnionType then
         local uname = ty.name
         if uname is nil and is_typedef and ctx == "default" then
            local parts: {string} = {}
            for _, f in ipairs(ty.fields) do
               local bw = f.bit_width
               if bw is nil and f.name ~= "" then
                  local fdecl = render_c_type(f.type, f.name, "", ctx, is_typedef)
                  if not fdecl then
                     return nil
                  end
                  table.insert(parts, fdecl .. ";")
               end
            end
            return string.format("union { %s } %s%s", table.concat(parts, " "), name, contextsuffix)
         end
      end
      local base = base_type_to_c(ty)
      if not base then
         return nil
      end
      local mid = name ~= "" and (" " .. name) or name
      return base .. mid .. contextsuffix
   end
end

local function builtin_to_teal(b: types.BuiltinType): string
   local n = b.name
   if n == "bool" then
      return "boolean"
   elseif n == "float" or n == "double" or n == "long_double" then
      return "number"
   elseif n == "void" then
      return "nil"
   end
   return "integer"
end

local function type_name_key(ty: TypeNode): string | nil
   if ty is types.StructType then
      if ty.name then
         return "struct:" .. ty.name
      end
   elseif ty is types.UnionType then
      if ty.name then
         return "union:" .. ty.name
      end
   elseif ty is types.EnumType then
      if ty.name then
         return "enum:" .. ty.name
      end
   elseif ty is types.TypedefType then
      return "typedef:" .. ty.name
   end
   return nil
end

local function numeric_record_class(ty: TypeNode, typedefs: {string: TypeNode}, seen?: {string:boolean}): string | nil
   local visited = seen or {}
   if ty is types.QualifiedType then
      return numeric_record_class(ty.of, typedefs, visited)
   elseif ty is types.TypedefType then
      local nm = ty.name
      if visited[nm] then
         return nil
      end
      visited[nm] = true
      local aliased = typedefs[nm]
      if aliased then
         return numeric_record_class(aliased, typedefs, visited)
      end
      return nil
   elseif ty is types.BuiltinType then
      local n = ty.name
      if n == "float" or n == "double" or n == "long_double" then
         return "ffi.CFloat"
      elseif n ~= "void" and n ~= "bool" then
         return "ffi.CInteger"
      end
   end
   return nil
end

local function type_supported(ty: TypeNode, seen: {TypeNode:boolean}, complete_enums?: {string: types.EnumType}): boolean
   if seen[ty] then
      return true
   end
   seen[ty] = true

   if ty is types.BuiltinType or ty is types.TypedefType then
      return true
   elseif ty is types.QualifiedType then
      return type_supported(ty.of, seen, complete_enums)
   elseif ty is types.PointerType then
      return type_supported(ty.to, seen, complete_enums)
   elseif ty is types.ArrayType then
      if ty.is_vla then
         return false
      end
      local size_expr = ty.size_expr
      local size_val = ty.size
      if not size_expr is nil and size_val is nil then
         -- allow arrays with unevaluated constant expressions; assume caller validated
      end
      return type_supported(ty.of, seen, complete_enums)
   elseif ty is types.FunctionType then
      if not type_supported(ty.returns, seen, complete_enums) then
         return false
      end
      for _, p in ipairs(ty.params) do
         if not type_supported(p.type, seen, complete_enums) then
            return false
         end
      end
      return true
   elseif ty is types.StructType then
      for _, f in ipairs(ty.fields) do
         local bw = f.bit_width
         if not bw is nil then
            return false
         end
         if f.name == "" then
            return false
         end
         if not type_supported(f.type, seen, complete_enums) then
            return false
         end
      end
      return true
   elseif ty is types.UnionType then
      for _, f in ipairs(ty.fields) do
         local bw = f.bit_width
         if not bw is nil then
            return false
         end
         if f.name == "" then
            return false
         end
         if not type_supported(f.type, seen, complete_enums) then
            return false
         end
      end
      return true
   elseif ty is types.EnumType then
      local ename = ty.name
      if ename is nil then
         return false
      end
      if ty.complete then
         return true
      end
      if complete_enums and complete_enums[ename] then
         return true
      end
      return false
   end
   return false
end

local function collect_type_defs(col: Collected, ty: TypeNode)
   local key = type_name_key(ty)

   if ty is types.StructType then
      local existing_struct = col.structs[ty.name or ""]
      if ty.name and not ty.complete and existing_struct is nil then
         col.forwards[ty.name] = "struct"
      end
      if ty.name and ty.complete then
         col.forwards[ty.name] = nil
         local existing = existing_struct or col.structs[ty.name]
         if existing is nil then
            col.structs[ty.name] = ty
         elseif not types_equal(existing, ty) then
            table.insert(col.warnings, "conflicting struct definition for " .. ty.name .. ", using first")
         end
      end
      for _, f in ipairs(ty.fields) do
         collect_type_defs(col, f.type)
      end
   elseif ty is types.UnionType then
      local existing_union = col.unions[ty.name or ""]
      if ty.name and not ty.complete and existing_union is nil then
         col.forwards[ty.name] = "union"
      end
      if ty.name and ty.complete then
         col.forwards[ty.name] = nil
         local existing = existing_union or col.unions[ty.name]
         if existing is nil then
            col.unions[ty.name] = ty
         elseif not types_equal(existing, ty) then
            table.insert(col.warnings, "conflicting union definition for " .. ty.name .. ", using first")
         end
      end
      for _, f in ipairs(ty.fields) do
         collect_type_defs(col, f.type)
      end
   elseif ty is types.EnumType then
      if ty.name and ty.complete then
         local existing = col.enums[ty.name]
         if existing is nil then
            col.enums[ty.name] = ty
         elseif not types_equal(existing, ty) then
            table.insert(col.warnings, "conflicting enum definition for " .. ty.name .. ", using first")
         end
      end
   elseif ty is types.PointerType then
      collect_type_defs(col, ty.to)
   elseif ty is types.ArrayType then
      collect_type_defs(col, ty.of)
   elseif ty is types.FunctionType then
      collect_type_defs(col, ty.returns)
      for _, p in ipairs(ty.params) do
         collect_type_defs(col, p.type)
      end
   elseif ty is types.QualifiedType then
      collect_type_defs(col, ty.of)
   end

   if key and ty is types.TypedefType then
      local name = ty.name
      local existing_td = col.typedefs[name]
      if existing_td is nil then
         col.typedefs[name] = ty
      end
   end
end

local function decl_path(d: ast.DeclNode, rep: Reporter): string | nil
   if d.kind == "func" or d.kind == "typedef" or d.kind == "var" then
      local dd = d as ast.FuncDecl | ast.TypedefDecl | ast.VarDecl
      local name_tok = dd.declarator.name
      if not name_tok is nil then
         local tok: Token = name_tok
         local ctx_any = rep:get_file(tok.file_id) as FileContext | nil
         if not ctx_any is nil then
            local ctx: FileContext = ctx_any as FileContext
            if ctx.path then
               return ctx.path
            end
         end
      end
   end

   local ctx_any = rep:get_file(d.span.file_id) as FileContext | nil
   if not ctx_any is nil then
      local ctx: FileContext = ctx_any as FileContext
      if ctx.path then
         return ctx.path
      end
   end
   return nil
end

local function should_emit_decl(d: ast.DeclNode, rep: Reporter, skip_system: boolean, allow: {string:boolean}): boolean
   local path = decl_path(d, rep)
   if path is nil or not skip_system then
      return true
   end
   if allow[path] then
      return true
   end
   return not is_system_path(path)
end

local function collect(col: Collected, tu: TranslationUnit, rep: Reporter, skip_system: boolean, allow: {string:boolean})
   for _, d in ipairs(tu.decls) do
      if not should_emit_decl(d, rep, skip_system, allow) then
         goto continue
      end
      if d is ast.FuncDecl then
         local name_tok = d.declarator.name
         if not name_tok is nil then
            local tok: Token = name_tok
            local name = tok:lexeme(tu.src_ptr)
            if not has_storage(d.specifiers, "static") then
               local existing = col.functions[name]
               if existing is nil then
                  col.functions[name] = d.type as types.FunctionType
               elseif not types_equal(existing, d.type) then
                  table.insert(col.warnings, "conflicting function prototype for " .. name .. ", using first")
               end
            end
         end
         collect_type_defs(col, d.type)
      elseif d is ast.TypedefDecl then
         local name_tok = d.declarator.name
         if not name_tok is nil then
            local tok: Token = name_tok
            local nm = tok:lexeme(tu.src_ptr)
            local existing_td = col.typedefs[nm]
            if existing_td is nil then
               col.typedefs[nm] = d.type
            elseif not types_equal(existing_td, d.type) then
               table.insert(col.warnings, "conflicting typedef for " .. nm .. ", using first")
            end
         end
         collect_type_defs(col, d.type)
      elseif d is ast.TagDecl then
         collect_type_defs(col, d.type)
      elseif d is ast.VarDecl then
         collect_type_defs(col, d.type)
      end
      ::continue::
   end
end

local function type_to_teal(ty: TypeNode, names: {string: string}, wrap_func?: boolean, strip_prefix?: string): string | nil
   local function strip_name(n: string): string
      local pref = strip_prefix or ""
      if pref ~= "" and string.sub(n, 1, #pref) == pref then
         local rest = string.sub(n, #pref + 1)
         if rest ~= "" then
            return rest
         end
      end
      return n
   end
   if ty is types.BuiltinType then
      return builtin_to_teal(ty)
   elseif ty is types.TypedefType then
      local base = names["typedef:" .. ty.name] or names["struct:" .. ty.name] or names["union:" .. ty.name] or names["enum:" .. ty.name] or "ffi.CData"
      return strip_name(base)
   elseif ty is types.StructType then
      if ty.name then
         local base = names["struct:" .. ty.name]
         if base then
            return strip_name(base)
         end
      end
      return nil
   elseif ty is types.UnionType then
      if ty.name then
         local base = names["union:" .. ty.name]
         if base then
            return strip_name(base)
         end
      end
      return nil
   elseif ty is types.EnumType then
      if ty.name then
         local base = names["enum:" .. ty.name]
         if base then
            return strip_name(base)
         end
      end
      return "integer"
   elseif ty is types.QualifiedType then
      return type_to_teal(ty.of, names, wrap_func, strip_prefix)
   elseif ty is types.PointerType then
      local to_ty = ty.to
      if to_ty is types.QualifiedType then
         local has_const = false
         for _, q in ipairs(to_ty.qualifiers) do
            if q == "const" then
               has_const = true
               break
            end
         end
         local base = to_ty.of
         if has_const and base is types.BuiltinType and base.name == "char" then
            return "ffi.String"
         end
      end
      local inner = type_to_teal(to_ty, names, wrap_func, strip_prefix) or "ffi.CData"
      return "ffi.Pointer<" .. inner .. ">"
   elseif ty is types.ArrayType then
      local inner = type_to_teal(ty.of, names, wrap_func, strip_prefix)
      if inner is nil then
         return nil
      end
      return "ffi.Array<" .. inner .. ">"
   elseif ty is types.FunctionType then
      local params: {string} = {}
      for _, p in ipairs(ty.params) do
         local pt = type_to_teal(p.type, names, wrap_func, strip_prefix)
         if not pt then
            return nil
         end
         if p.name then
            table.insert(params, p.name .. ": " .. pt)
         else
            table.insert(params, pt)
         end
      end
      if ty.is_variadic then
         table.insert(params, "...: any")
      end
      local ret = type_to_teal(ty.returns, names, wrap_func, strip_prefix) or "nil"
      local param_str = table.concat(params, ", ")
      if wrap_func then
         return string.format("ffi.Function<function(ffi.Function<nil>, %s): %s>", param_str, ret)
      end
      return "function(" .. param_str .. "): " .. ret
   end
   return nil
end

local function emit_struct(buf: {string}, st: types.StructType, _names: {string:string}, complete_enums?: {string: types.EnumType}): boolean
   if not type_supported(st, {}, complete_enums) then
      return false
   end
   table.insert(buf, "struct " .. st.name .. " {")
   for _, f in ipairs(st.fields) do
      local bw = f.bit_width
      if bw is nil and f.name ~= "" then
         local fdecl = render_c_type(f.type, f.name, "", "default")
         if fdecl then
            table.insert(buf, "  " .. fdecl .. ";")
         end
      end
   end
   table.insert(buf, "};")
   return true
end

local function emit_union(buf: {string}, un: types.UnionType, complete_enums?: {string: types.EnumType}): boolean
   if not type_supported(un, {}, complete_enums) then
      return false
   end
   table.insert(buf, "union " .. un.name .. " {")
   for _, f in ipairs(un.fields) do
      local bw = f.bit_width
      if bw is nil and f.name ~= "" then
         local fdecl = render_c_type(f.type, f.name, "", "default")
         if fdecl then
            table.insert(buf, "  " .. fdecl .. ";")
         end
      end
   end
   table.insert(buf, "};")
   return true
end

local function emit_enum(buf: {string}, en: types.EnumType)
   table.insert(buf, "enum " .. en.name .. " {")
   for idx, v in ipairs(en.values) do
      local line = "  " .. v.name
      local vval = v.value
      if not vval is nil then
         line = line .. " = " .. tostring(vval)
      end
      if idx < #en.values then
         line = line .. ","
      end
      table.insert(buf, line)
   end
   table.insert(buf, "};")
end

local function sorted_keys<K, V>(tbl: {K:V}): {K}
   local keys: {K} = {}
   for k, _ in pairs(tbl) do
      table.insert(keys, k)
   end
   table.sort(keys)
   return keys
end

local function render(collectd: Collected, headers: {string}, opts: GenerateOptions, writer?: function(string)): Rendered
   local names: {string:string} = {}
   for nm, _ in pairs(collectd.structs) do
      names["struct:" .. nm] = sanitize(nm)
   end
   for nm, _ in pairs(collectd.unions) do
      names["union:" .. nm] = sanitize(nm)
   end
   for nm, _ in pairs(collectd.enums) do
      names["enum:" .. nm] = sanitize(nm)
   end
   for nm, ty in pairs(collectd.typedefs) do
      local key = type_name_key(ty) or ("typedef:" .. nm)
      names[key] = sanitize(nm)
   end
   for nm, kind in pairs(collectd.forwards) do
      if kind == "struct" then
         names["struct:" .. nm] = sanitize(nm)
      elseif kind == "union" then
         names["union:" .. nm] = sanitize(nm)
      end
   end

   local strip_prefix = opts.strip_prefix or ""
   local function apply_strip(n: string): string
      if strip_prefix ~= "" and string.sub(n, 1, #strip_prefix) == strip_prefix then
         local rest = string.sub(n, #strip_prefix + 1)
         if rest ~= "" then
            return rest
         end
      end
      return n
   end

   local cdef_lines: {string} = {}
   table.insert(cdef_lines, "/* generated by autogen_ffi */")
   for nm, kind in pairs(collectd.forwards) do
      table.insert(cdef_lines, string.format("typedef %s %s %s;", kind, nm, nm))
   end
   for _, en in pairs(collectd.enums) do
      if type_supported(en, {}, collectd.enums) then
         emit_enum(cdef_lines, en)
         table.insert(cdef_lines, "")
      else
         table.insert(collectd.warnings, "skipping enum " .. (en.name or "<anon>") .. " (unsupported)")
      end
   end
   for _, st in pairs(collectd.structs) do
      if emit_struct(cdef_lines, st, names, collectd.enums) then
         table.insert(cdef_lines, "")
      else
         table.insert(collectd.warnings, "skipping struct " .. (st.name or "<anon>") .. " (unsupported)")
      end
   end
   for _, un in pairs(collectd.unions) do
      if emit_union(cdef_lines, un, collectd.enums) then
         table.insert(cdef_lines, "")
      else
         table.insert(collectd.warnings, "skipping union " .. (un.name or "<anon>") .. " (unsupported)")
      end
   end
   for _, nm in ipairs(sorted_keys(collectd.typedefs)) do
      local ty = collectd.typedefs[nm]
      local fwd = collectd.forwards[nm]
      if type_supported(ty, {}, collectd.enums) and fwd is nil then
         local decl = render_c_type(ty, nm, "", "default", true)
         if decl then
            local d = decl as string
            local stripped = d:gsub("^%s+", ""):gsub("%s+$", "")
            if stripped ~= nm and not stripped:match("^" .. nm .. "%s+" .. nm .. "$") then
               table.insert(cdef_lines, "typedef " .. d .. ";")
            end
         end
      else
         table.insert(collectd.warnings, "skipping typedef " .. nm .. " (unsupported)")
      end
   end
   for _, nm in ipairs(sorted_keys(collectd.functions)) do
      local fn_ty = collectd.functions[nm]
      if type_supported(fn_ty, {}, collectd.enums) then
         local decl = render_c_type(fn_ty, nm, "", "default")
         if decl then
            table.insert(cdef_lines, decl .. ";")
         end
      else
         table.insert(collectd.warnings, "skipping function " .. nm .. " (unsupported types)")
      end
   end
   local cdef = table.concat(cdef_lines, "\n")

   local type_defs: {string} = {}
   local used_fields: {string:boolean} = {}
   local function take_field(name: string): string | nil
      if used_fields[name] then
         return nil
      end
      used_fields[name] = true
      return name
   end
   for _, st in pairs(collectd.structs) do
      if type_supported(st, {}, collectd.enums) then
         local nm = names["struct:" .. st.name] or st.name
         local raw_name = apply_strip(nm)
         local field_name = take_field(raw_name)
         if field_name is nil then
            goto continue_struct
         end
         local ctype = st.name and ("struct " .. st.name) or ""
         table.insert(type_defs, string.format("local record %s is ffi.CData where ffi.istype(\"%s\", self)", field_name, ctype))
         for _, f in ipairs(st.fields) do
            local bw = f.bit_width
            if bw is nil and f.name ~= "" then
               local ft = type_to_teal(f.type, names, false, strip_prefix)
               if ft then
                  table.insert(type_defs, string.format("   %s: %s", f.name, ft))
               end
            end
         end
         table.insert(type_defs, "end\n")
         ::continue_struct::
      end
   end
   for _, un in pairs(collectd.unions) do
      if type_supported(un, {}, collectd.enums) then
         local nm = names["union:" .. un.name] or un.name
         local raw_name = apply_strip(nm)
         local field_name = take_field(raw_name)
         if field_name is nil then
            goto continue_union
         end
         local ctype = un.name and ("union " .. un.name) or ""
         table.insert(type_defs, string.format("local record %s is ffi.CData where ffi.istype(\"%s\", self)", field_name, ctype))
         for _, f in ipairs(un.fields) do
            local bw = f.bit_width
            if bw is nil and f.name ~= "" then
               local ft = type_to_teal(f.type, names, false, strip_prefix)
               if ft then
                  table.insert(type_defs, string.format("   %s: %s", f.name, ft))
               end
            end
         end
         table.insert(type_defs, "end\n")
         ::continue_union::
      end
   end
   for nm, kind in pairs(collectd.forwards) do
      local key = names[kind .. ":" .. nm] or sanitize(nm)
      local raw_name = apply_strip(key)
      local field_name = take_field(raw_name)
      if field_name is nil then
         goto continue_forward
      end
      local ctype = kind .. " " .. nm
      table.insert(type_defs, string.format("local record %s is ffi.CData where ffi.istype(\"%s\", self) end\n", field_name, ctype))
      ::continue_forward::
   end
   local enum_type_aliases: {string} = {}
   for _, en in pairs(collectd.enums) do
      if type_supported(en, {}, collectd.enums) and en.name then
         local nm = names["enum:" .. en.name] or en.name
         table.insert(enum_type_aliases, "type " .. apply_strip(nm) .. " = integer")
      end
   end
   local typedef_records: {string} = {}
   for nm, ty in pairs(collectd.typedefs) do
      local fwd = collectd.forwards[nm]
      local st_def = collectd.structs[nm]
      local un_def = collectd.unions[nm]
      if type_supported(ty, {}, collectd.enums) and fwd is nil and st_def is nil and un_def is nil then
         local tn = names["typedef:" .. nm] or sanitize(nm)
         local raw_name = apply_strip(tn)
         local field_name = take_field(raw_name)
         if field_name is nil then
            goto continue_typedef_record
         end
         local base_class = numeric_record_class(ty, collectd.typedefs) or "ffi.CData"
         local decl = string.format("local record %s is %s where ffi.istype(\"%s\", self) end", field_name, base_class, nm)
         table.insert(typedef_records, decl)
         ::continue_typedef_record::
      end
   end

   local fn_sigs: {string} = {}
   for nm, fn_ty in pairs(collectd.functions) do
      if type_supported(fn_ty, {}, collectd.enums) then
         local sig = type_to_teal(fn_ty, names, true, strip_prefix)
         if sig then
            local fname = apply_strip(nm)
            table.insert(fn_sigs, string.format("   %s: %s", fname, sig))
         else
            table.insert(collectd.warnings, "skipping function " .. nm .. " (unable to render type)")
         end
      end
   end

   local out: {string} = {}
   local function emit(line: string)
      if writer then
         writer(line .. "\n")
      else
         table.insert(out, line)
      end
   end

   emit('local ffi = require("ffi")')
   emit("")
   emit("local cdef = [[")
   emit(cdef)
   emit("]]")
   emit("")
   emit("ffi.cdef(cdef)")
   emit("")
   local libtag = basename_no_ext(opts.output or default_output(headers))
   libtag = sanitize(libtag)
   emit("local record " .. libtag)
   for _, block in ipairs(type_defs) do
      for line in block:gmatch("[^\n]+") do
         local cleaned = line:gsub("^local%s+", "")
         emit("   " .. cleaned)
      end
      emit("")
   end
   for _, l in ipairs(enum_type_aliases) do
      emit("   " .. l)
   end
   for _, block in ipairs(typedef_records) do
      for line in block:gmatch("[^\n]+") do
         local cleaned = line:gsub("^local%s+", "")
         emit("   " .. cleaned)
      end
      emit("")
   end
   for _, l in ipairs(fn_sigs) do
      emit(l)
   end
   emit("end")
   emit("")
   emit(string.format('local STRIP_PREFIX = %q', opts.strip_prefix or ""))
   emit("")
   local load_expr = opts.load_library and string.format('ffi.load("%s")', opts.load_library) or "ffi.C"
   emit(string.format("local raw = %s", load_expr))
   emit("")
   if opts.strip_prefix and opts.strip_prefix ~= "" then
         emit [[
local lib = setmetatable({
   cdef = cdef
}, {
   __index = function(self: {string:any}, key: string): any
      local ckey = STRIP_PREFIX .. key
      local ok, val = pcall(function(): any return raw[ckey] end)
      if ok and not val is nil then
         rawset(self, key, val)
         return val
      end
      local v = raw[key]
      rawset(self, key, v)
      return v
   end,

   __newindex = function(self: {string:any}, key: string, value: any): nil
      local ckey = STRIP_PREFIX .. key
      local ok = pcall(function(): nil raw[ckey] = value end)
      if ok then return end
      raw[key] = value
   end,
})
         ]]
      -- emit("getmetatable(" .. libtag .. ").__index = function(self: {string:any}, key: string): any")
      -- emit("   local ckey = STRIP_PREFIX .. key")
      -- emit("   local val = rawget(self, ckey)")
      -- emit("   if not val is nil then return val end")
      -- emit("   val = rawget(self, key)")
      -- emit("   if not val is nil then return val end")
      -- emit("   error(\"attempt to access undefined member '\" .. key .. \"'\")")
      -- emit("end")
      emit("")
   end
   emit("return lib as " .. libtag)

   local content: string | nil = nil
   if not writer then
      content = table.concat(out, "\n")
   end

   return {
      path = opts.output or default_output(headers),
      content = content,
      warnings = collectd.warnings,
   }
end

local function generate(opts: GenerateOptions, reporter?: Reporter, writer?: function(string)): Rendered | nil
   local rep = reporter or Reporter.new()
   local col: Collected = {
      structs = {},
      unions = {},
      enums = {},
   typedefs = {},
   functions = {},
   warnings = {},
   forwards = {},
   }
   local allow: {string:boolean} = {}
   for _, p in ipairs(opts.headers) do
      allow[p] = true
   end

   for idx, path in ipairs(opts.headers) do
      local pp = Preprocessor.preprocess(assert(fs.read_all(path)), idx, rep--[[, {
         search_paths = { path_dir(path) },
         defines = Target.default_defines(HOST_TARGET, true),
      undefs = {},
      current_dir = path_dir(path),
      source_path = path,
      no_system_paths = false,
      }]])
      local lex = pp.lexer
      if lex is nil then
         return nil
      end
      local tu = Parser.parse(lex.src_ptr, pp.next, rep)
      local checked = Checker.check(tu, rep, { allow_incomplete_params = true })
      collect(col, checked.tu, rep, opts.ignore_system_includes or false, allow)
   end

   return render(col, opts.headers, opts, writer)
end

local function run(opts: GenerateOptions, rep?: Reporter): string | nil
   if #opts.headers == 0 then
      return "no headers provided"
   end
   local f, ferr = io.open(opts.output or default_output(opts.headers), "w")
   if f is nil then
      return ferr
   end
   local rendered = generate(opts, rep, function(line: string)
      f:write(line)
   end)
   if rendered is nil then
      f:close()
      return "generation failed (see diagnostics above)"
   end
   f:close()
   for _, w in ipairs(rendered.warnings) do
      io.stderr:write("[ffi-gen] warning: " .. w .. "\n")
   end
   return nil
end

return {
   GenerateOptions = GenerateOptions,
   run = run,
   generate = generate,
}
