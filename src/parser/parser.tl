local Span = require("util.span")
local token_mod = require("lexer.token")
local Lexer = require("lexer.lexer")
local types = require("sema.types")
local Reporter = require("diag.reporter")
local Diagnostic = require("diag.diagnostics")
local ast = require("parser.ast")

local type Token = token_mod.Token
local type TokenKindType = token_mod.TokenKind
local TK_IDENTIFIER: TokenKindType = "identifier"
local TK_NUMBER: TokenKindType = "number"
local TK_STRING: TokenKindType = "string"
local TK_CHAR: TokenKindType = "char"
local TK_KEYWORD: TokenKindType = "keyword"
local TK_PUNCT: TokenKindType = "punctuator"
local TK_EOF: TokenKindType = "eof"

local type TokenIterator = function(): Token

local BN = {
   void: types.BuiltinName = "void",
   bool: types.BuiltinName = "bool",
   char: types.BuiltinName = "char",
   schar: types.BuiltinName = "schar",
   uchar: types.BuiltinName = "uchar",
   short: types.BuiltinName = "short",
   ushort: types.BuiltinName = "ushort",
   int: types.BuiltinName = "int",
   uint: types.BuiltinName = "uint",
   long: types.BuiltinName = "long",
   ulong: types.BuiltinName = "ulong",
   long_long: types.BuiltinName = "long_long",
   ulong_long: types.BuiltinName = "ulong_long",
   float: types.BuiltinName = "float",
   double: types.BuiltinName = "double",
   long_double: types.BuiltinName = "long_double",
}

local assignment_ops: {string:boolean} = {
   ["="] = true, ["+="] = true, ["-="] = true, ["*="] = true, ["/="] = true, ["%="] = true,
   ["<<="] = true, [">>="] = true, ["&="] = true, ["^="] = true, ["|="] = true,
}

local binary_precedence: {string: integer} = {
   ["||"] = 1,
   ["&&"] = 2,
   ["|"] = 3,
   ["^"] = 4,
   ["&"] = 5,
   ["=="] = 6, ["!="] = 6,
   ["<"] = 7, [">"] = 7, ["<="] = 7, [">="] = 7,
   ["<<"] = 8, [">>"] = 8,
   ["+"] = 9, ["-"] = 9,
   ["*"] = 10, ["/"] = 10, ["%"] = 10,
}

local record Parser
   next_token: TokenIterator
   current: Token
   lookahead: Token
   reporter: Reporter
   typedef_scopes: {{string:boolean}}
end

local function new_parser(iter: TokenIterator, reporter: Reporter): Parser
   local first = iter()
   local second = first.kind == TK_EOF and first or iter()
   return {
      next_token = iter,
      current = first,
      lookahead = second,
      reporter = reporter,
      typedef_scopes = { {} },
   }
end

local function cur(p: Parser): Token
   return p.current
end

local function peek(p: Parser, offset: integer): Token
   if offset <= 0 then
      return p.current
   end
   if offset == 1 then
      return p.lookahead
   end
   return p.lookahead
end

local function at(p: Parser, kind: TokenKindType, lexeme?: string): boolean
   local t = cur(p)
   return t.kind == kind and (not lexeme or t.lexeme == lexeme)
end

local function advance(p: Parser): Token
   local t = p.current
   if t.kind ~= TK_EOF then
      p.current = p.lookahead
      if p.current.kind == TK_EOF then
         p.lookahead = p.current
      else
         local nxt = p.next_token()
         p.lookahead = nxt
      end
   end
   return t
end

local function is_attribute_token(tok: Token): boolean
   if tok.kind ~= TK_IDENTIFIER and tok.kind ~= TK_KEYWORD then
      return false
   end
   local lx = tok.lexeme
   return lx == "__attribute__" or lx == "__attribute" or lx == "__declspec" or lx == "__declspec__" or lx == "__asm" or lx == "__asm__" or lx == "asm"
end

local function skip_parens(p: Parser)
   if not at(p, TK_PUNCT, "(") then
      return
   end
   local depth = 0
   repeat
      local t = cur(p)
      if t.kind == TK_PUNCT then
         if t.lexeme == "(" then
            depth = depth + 1
         elseif t.lexeme == ")" then
            depth = depth - 1
         end
      end
      advance(p)
      if depth == 0 then
         break
      end
   until cur(p).kind == TK_EOF
end

local function skip_attributes(p: Parser)
   while true do
       local tok = cur(p)
       local lx = tok.lexeme
       if tok.kind == TK_IDENTIFIER and (lx == "__attribute__" or lx == "__attribute" or lx == "__declspec" or lx == "__declspec__") then
          advance(p)
          while at(p, TK_PUNCT, "(") do
             skip_parens(p)
          end
       elseif tok.kind == TK_IDENTIFIER and (lx == "__asm" or lx == "__asm__" or lx == "asm") then
          advance(p)
          if at(p, TK_PUNCT, "(") then
             skip_parens(p)
          end
       else
          break
       end
   end
end

local function report_error(p: Parser, message: string, span: Span, code: string)
   p.reporter:report(Diagnostic.new("error", message, span, code))
end

local function expect(p: Parser, kind: TokenKindType, lexeme?: string, code?: string): Token
   local t = cur(p)
   if at(p, kind, lexeme) then
      return advance(p)
   end
   local msg = lexeme and ("expected '" .. lexeme .. "'") or ("expected " .. tostring(kind))
   report_error(p, msg, t.span, code or "PAR000")
   advance(p)
   return t
end

local function push_typedef_scope(p: Parser)
   table.insert(p.typedef_scopes, {})
end

local function pop_typedef_scope(p: Parser)
   p.typedef_scopes[#p.typedef_scopes] = nil
end

local function declare_typedef(p: Parser, name: string)
   local top = p.typedef_scopes[#p.typedef_scopes]
   top[name] = true
end

local function is_typedef_name(p: Parser, tok: Token): boolean
   if tok.kind ~= TK_IDENTIFIER then
      return false
   end
   for i = #p.typedef_scopes, 1, -1 do
      if p.typedef_scopes[i][tok.lexeme] then
         return true
      end
   end
   return false
end

local function is_type_qualifier(tok: Token): boolean
   return tok.kind == TK_KEYWORD and (tok.lexeme == "const" or tok.lexeme == "restrict" or tok.lexeme == "volatile")
end

local function is_storage_class(tok: Token): boolean
   if tok.kind ~= TK_KEYWORD then
      return false
   end
   return tok.lexeme == "typedef" or tok.lexeme == "extern" or tok.lexeme == "static" or tok.lexeme == "auto" or tok.lexeme == "register"
end

local function is_function_specifier(tok: Token): boolean
   return tok.kind == TK_KEYWORD and tok.lexeme == "inline"
end

local function is_builtin_keyword(tok: Token): boolean
   if tok.kind ~= TK_KEYWORD then
      return false
   end
   local l = tok.lexeme
   return l == "void" or l == "_Bool" or l == "char" or l == "short" or l == "int" or l == "long" or l == "float" or l == "double" or l == "signed" or l == "unsigned" or l == "_Complex" or l == "_Imaginary"
end

local function is_type_specifier_start(p: Parser, tok: Token): boolean
   if is_attribute_token(tok) then
      return true
   end
   if is_builtin_keyword(tok) or is_type_qualifier(tok) or is_storage_class(tok) or is_function_specifier(tok) then
      return true
   end
   if tok.kind == TK_KEYWORD and (tok.lexeme == "struct" or tok.lexeme == "union" or tok.lexeme == "enum") then
      return true
   end
   if tok.kind == TK_IDENTIFIER then
      if string.sub(tok.lexeme, 1, 9) == "__builtin" then
         return true
      end
      return is_typedef_name(p, tok)
   end
   return is_typedef_name(p, tok)
end

local function looks_like_declaration(p: Parser): boolean
   local t = cur(p)
   if t.kind == TK_EOF then
   	 return false
   end
   if is_attribute_token(t) then
      return true
   end
   if is_type_specifier_start(p, t) then
      return true
   end
   if t.kind == TK_PUNCT and t.lexeme == "(" then
      -- maybe a parenthesized type-name cast/abstract declarator
      local next_tok = peek(p, 1)
      if is_type_specifier_start(p, next_tok) then
         return true
      end
   end
   return false
end

local function default_signed(name: types.BuiltinName): boolean
   if name == BN.bool or name == BN.void then
      return false
   end
   if name == BN.float or name == BN.double or name == BN.long_double then
      return true
   end
   return true
end

local function make_builtin_type(name: types.BuiltinName, span: Span, signed_override: boolean | nil, is_complex: boolean, is_imaginary: boolean): types.BuiltinType
   local is_signed = signed_override
   if is_signed is nil then
      is_signed = default_signed(name)
   end
   return {
      tag = "builtin",
      span = span,
      name = name,
      is_signed = is_signed,
      is_complex = is_complex,
      is_imaginary = is_imaginary,
   }
end

local function qualify(base: types.TypeNode, qualifiers: {types.TypeQualifier}): types.TypeNode
   if #qualifiers == 0 then
      return base
   end
   return {
      tag = "qualified",
      span = base.span,
      of = base,
      qualifiers = qualifiers,
   }
end

local function apply_derived(base: types.TypeNode, derived: {ast.DerivedDeclarator}): types.TypeNode
   local ty = base
   for i = #derived, 1, -1 do
      local d = derived[i]
      if d is ast.PointerDeclarator then
         ty = {
            tag = "pointer",
            span = d.span,
            to = ty,
            qualifiers = d.qualifiers,
         }
      elseif d is ast.ArrayDeclarator then
         ty = {
            tag = "array",
            span = d.span,
            of = ty,
            size = nil,
            size_expr = d.size,
            is_vla = d.is_vla,
            is_static = d.is_static,
            qualifiers = d.qualifiers,
         }
      elseif d is ast.FunctionDeclarator then
         local params: {types.FunctionParam} = {}
         for _, p in ipairs(d.params) do
            local param_name: string | nil = nil
            local pdecl = p.declarator
            if not (pdecl is nil) then
               local pname = pdecl.name
               if not (pname is nil) then
                  param_name = pname.lexeme
               end
            end
            table.insert(params, {
               name = param_name,
               type = p.type,
               span = p.span,
            })
         end
         ty = {
            tag = "function",
            span = ty.span,
            returns = ty,
            params = params,
            is_variadic = d.is_variadic,
         }
      end
   end
   return ty
end

local parse_declarator: function(p: Parser, allow_abstract: boolean): ast.Declarator
local parse_expression: function(p: Parser): ast.ExprNode
local parse_initializer: function(p: Parser): ast.Initializer
local parse_statement: function(p: Parser): ast.StmtNode
local parse_unary: function(p: Parser): ast.ExprNode
local parse_postfix: function(p: Parser): ast.ExprNode
local parse_conditional: function(p: Parser): ast.ExprNode
local parse_assignment: function(p: Parser): ast.ExprNode

local function parse_decl_specifiers(p: Parser): ast.DeclSpecifiers | nil
   local storage: {ast.StorageClass} = {}
   local func_specs: {ast.FunctionSpecifier} = {}
   local qualifiers: {types.TypeQualifier} = {}
   local type_spec: ast.TypeSpecifier | nil = nil
   local start_span: Span | nil = nil

   local signedness: boolean | nil = nil
   local long_count = 0
   local short_count = 0
   local base_builtin: string | nil = nil
   local is_complex = false
   local is_imaginary = false

   while true do
      skip_attributes(p)
      local tok = cur(p)
      if not start_span then
         start_span = tok.span
      end
      if is_storage_class(tok) then
         if tok.lexeme == "typedef" then
            table.insert(storage, "typedef")
         elseif tok.lexeme == "extern" then
            table.insert(storage, "extern")
         elseif tok.lexeme == "static" then
            table.insert(storage, "static")
         elseif tok.lexeme == "auto" then
            table.insert(storage, "auto")
         elseif tok.lexeme == "register" then
            table.insert(storage, "register")
         end
         advance(p)
      elseif is_function_specifier(tok) then
         table.insert(func_specs, "inline")
         advance(p)
      elseif is_type_qualifier(tok) then
         local q = tok.lexeme == "const" and "const" or tok.lexeme == "restrict" and "restrict" or "volatile"
         table.insert(qualifiers, q as types.TypeQualifier)
         advance(p)
      elseif tok.kind == TK_KEYWORD and (tok.lexeme == "struct" or tok.lexeme == "union") then
         local spec: ast.StructSpecifier | nil = nil
         local tag_kind = tok.lexeme
         advance(p)
         local name_tok: Token | nil = nil
         if cur(p).kind == TK_IDENTIFIER then
            name_tok = advance(p)
         end
         local fields: {ast.StructField} | nil = nil
         if at(p, TK_PUNCT, "{") then
            advance(p)
            fields = {}
            while not at(p, TK_PUNCT, "}") and cur(p).kind ~= TK_EOF do
               local field_spec = parse_decl_specifiers(p)
               if not field_spec is nil then
                  local declarators: {ast.StructDeclarator} = {}
                  repeat
                     local sd_span = cur(p).span
                     local decl: ast.Declarator | nil = nil
                     local bit_width: ast.ExprNode | nil = nil
                     if not at(p, TK_PUNCT, ":") then
                        decl = parse_declarator(p, true)
                     end
                     if at(p, TK_PUNCT, ":") then
                        advance(p)
                        bit_width = parse_expression(p)
                     end
                     local end_span = sd_span
                     if not bit_width is nil then
                        end_span = bit_width.span
                     elseif not decl is nil then
                        end_span = decl.span
                     end
                     table.insert(declarators, { span = sd_span:merge(end_span), declarator = decl, bit_width = bit_width })
                     if not at(p, TK_PUNCT, ",") then
                        break
                     end
                     advance(p)
                  until false
                  expect(p, TK_PUNCT, ";", "PAR104")
                  table.insert(fields, { span = field_spec.span, specifiers = field_spec, declarators = declarators })
               else break end
            end
            expect(p, TK_PUNCT, "}", "PAR105")
         end
         local span = start_span or tok.span
         spec = {
            kind = "struct",
            tag_kind = tag_kind,
            span = span,
            name = name_tok,
            fields = fields,
         }
         type_spec = spec
      elseif tok.kind == TK_KEYWORD and tok.lexeme == "enum" then
         advance(p)
         local name_tok: Token | nil = nil
         if cur(p).kind == TK_IDENTIFIER then
            name_tok = advance(p)
         end
         local enumerators: {ast.Enumerator} | nil = nil
         if at(p, TK_PUNCT, "{") then
            advance(p)
            enumerators = {}
            local value_counter = 0
            while not at(p, TK_PUNCT, "}") and cur(p).kind ~= TK_EOF do
               local name = expect(p, TK_IDENTIFIER, nil, "PAR106")
            local value_expr: ast.ExprNode | nil = nil
            if at(p, TK_PUNCT, "=") then
               advance(p)
               value_expr = parse_assignment(p)
            end
            local span = name.span
            local val_int: integer | nil = nil
            local ve = value_expr
            if not ve is nil and ve is ast.NumberLiteralExpr then
               local parsed = tonumber(ve.token.lexeme)
               if not (parsed is nil) then
                  val_int = math.floor(parsed)
               end
            end
            if val_int is nil then
               val_int = value_counter
            end
            table.insert(enumerators, { name = name, value = value_expr, span = span })
               value_counter = value_counter + 1
               if not at(p, TK_PUNCT, ",") then
                  break
               end
               advance(p)
               if at(p, TK_PUNCT, "}") then
                  break
               end
            end
            expect(p, TK_PUNCT, "}", "PAR107")
         end
         local span = start_span or tok.span
         type_spec = { kind = "enum", span = span, name = name_tok, enumerators = enumerators }
      elseif is_builtin_keyword(tok) then
         if tok.lexeme == "signed" then
            signedness = true
         elseif tok.lexeme == "unsigned" then
            signedness = false
         elseif tok.lexeme == "short" then
            short_count = short_count + 1
         elseif tok.lexeme == "long" then
            long_count = long_count + 1
         elseif tok.lexeme == "void" then
            base_builtin = "void"
         elseif tok.lexeme == "_Bool" then
            base_builtin = "bool"
         elseif tok.lexeme == "char" then
            base_builtin = "char"
         elseif tok.lexeme == "int" then
            base_builtin = base_builtin or "int"
         elseif tok.lexeme == "float" then
            base_builtin = "float"
         elseif tok.lexeme == "double" then
            base_builtin = "double"
         elseif tok.lexeme == "_Complex" then
            is_complex = true
         elseif tok.lexeme == "_Imaginary" then
            is_imaginary = true
         end
         advance(p)
      elseif type_spec is nil and tok.kind == TK_IDENTIFIER and string.sub(tok.lexeme, 1, 9) == "__builtin" then
         type_spec = { kind = "typedef", span = tok.span, name = tok }
         advance(p)
      elseif is_typedef_name(p, tok) then
         type_spec = { kind = "typedef", span = tok.span, name = tok }
         advance(p)
      else
         break
      end
   end

   if type_spec is nil then
      if not base_builtin then
         if long_count > 0 then
            base_builtin = "long"
         elseif short_count > 0 then
            base_builtin = "short"
         elseif not (signedness is nil) or is_complex or is_imaginary then
            base_builtin = "int"
         else
            base_builtin = "int"
         end
      end
      local span = start_span or cur(p).span
      local name = BN.int
      if base_builtin == "void" then
         name = BN.void
      elseif base_builtin == "bool" then
         name = BN.bool
      elseif base_builtin == "char" then
         if signedness == false then
            name = BN.uchar
         elseif signedness == true then
            name = BN.schar
         else
            name = BN.char
         end
      elseif base_builtin == "short" then
         name = signedness == false and BN.ushort or BN.short
      elseif base_builtin == "long" then
         if long_count > 1 then
            name = signedness == false and BN.ulong_long or BN.long_long
         else
            name = signedness == false and BN.ulong or BN.long
         end
      elseif base_builtin == "float" then
         name = BN.float
      elseif base_builtin == "double" then
         if long_count > 0 then
            name = BN.long_double
         else
            name = BN.double
         end
      end
      local builtin_ty = make_builtin_type(name, span, signedness, is_complex, is_imaginary)
      type_spec = { kind = "builtin", span = span, builtin = builtin_ty }
   else
      if type_spec is ast.StructSpecifier or type_spec is ast.EnumSpecifier then
         -- keep
      elseif type_spec is ast.TypedefTypeSpec then
         -- ok
      end
   end

   if type_spec is nil then
      return nil
   end

   local end_span = (not start_span is nil and start_span:merge(cur(p).span)) or cur(p).span
   return {
      storage = storage,
      func_specs = func_specs,
      qualifiers = qualifiers,
      type_spec = type_spec,
      span = end_span,
   }
end

local function type_from_spec(spec: ast.TypeSpecifier): types.TypeNode
   if spec is ast.BuiltinTypeSpec then
      return spec.builtin
   elseif spec is ast.TypedefTypeSpec then
      return {
         tag = "typedef",
         span = spec.span,
         name = spec.name.lexeme,
      } 
   elseif spec is ast.StructSpecifier then
      local fields: {types.Field} = {}
      local sfields = spec.fields
      if not sfields is nil then
         for _, f in ipairs(sfields) do
               for _, decl in ipairs(f.declarators) do
                  local name = ""
                  local base_type = type_from_spec(f.specifiers.type_spec)
                  base_type = qualify(base_type, f.specifiers.qualifiers)
                  local ty = base_type
                  local field_inner_decl = decl.declarator
                  if not (field_inner_decl is nil) then
                     ty = apply_derived(base_type, field_inner_decl.derived)
                     local dname = field_inner_decl.name
                     if not (dname is nil) then
                        name = dname.lexeme
                     end
                  end
                  local bit_width_num: integer | nil = nil
                  local bw = decl.bit_width
                  if not bw is nil and bw is ast.NumberLiteralExpr then
                     local parsed_bw = tonumber(bw.token.lexeme)
                     if not (parsed_bw is nil) then
                        bit_width_num = math.floor(parsed_bw)
                     end
                  end
                  table.insert(fields, { name = name, type = ty, bit_width = bit_width_num })
               end
            end
      end
      local sname = spec.name
      local name = not sname is nil and sname.lexeme or nil
      if spec.tag_kind == "struct" then
         local struct_fields = spec.fields
         local complete = not (struct_fields is nil)
         return { tag = "struct", span = spec.span, name = name, fields = fields, complete = complete }
      else
         local union_fields = spec.fields
         local complete = not (union_fields is nil)
         return { tag = "union", span = spec.span, name = name, fields = fields, complete = complete }
      end
   else
      local sname = spec.name
      local name = not sname is nil and sname.lexeme or nil
      local values: {types.EnumConst} = {}
      local senums = spec.enumerators
      if not senums is nil then
         for _, en in ipairs(senums) do
            local value_int: integer | nil = nil
            local ev = en.value
            if not ev is nil and ev is ast.NumberLiteralExpr then
               local parsed_val = tonumber(ev.token.lexeme)
               if not (parsed_val is nil) then
                  value_int = math.floor(parsed_val)
               end
            end
            table.insert(values, { name = en.name.lexeme, value = value_int, span = en.span })
         end
      end
      local built_int = make_builtin_type(BN.int, spec.span, true, false, false)
      return { tag = "enum", span = spec.span, name = name, underlying = built_int, values = values, complete = not senums is nil }
   end
end

local function parse_pointer_chain(p: Parser): {ast.PointerDeclarator}
   if not at(p, TK_PUNCT, "*") then
      return {}
   end
   local star = advance(p)
   local quals: {types.TypeQualifier} = {}
   while is_type_qualifier(cur(p)) do
      local q = cur(p).lexeme == "const" and "const" or cur(p).lexeme == "restrict" and "restrict" or "volatile"
      table.insert(quals, q as types.TypeQualifier)
      advance(p)
   end
   local inner = parse_pointer_chain(p)
   table.insert(inner, { kind = "pointer", span = star.span, qualifiers = quals })
   return inner
end

local function parse_parameter_list(p: Parser): ({ast.Parameter}, boolean)
   local params: {ast.Parameter} = {}
   local is_variadic = false
   if at(p, TK_PUNCT, ")") then
      return params, false
   end

   -- K&R identifier list parameter syntax (deprecated but part of C99 for compatibility)
   if not is_type_specifier_start(p, cur(p)) and cur(p).kind == TK_IDENTIFIER then
      repeat
         local name_tok = advance(p)
         local span = name_tok.span
         local builtin_ty = make_builtin_type(BN.int, span, true, false, false)
         local spec: ast.DeclSpecifiers = { storage = {}, func_specs = {}, qualifiers = {}, type_spec = { kind = "builtin", span = span, builtin = builtin_ty }, span = span }
         local decl: ast.Declarator = { name = name_tok, derived = {}, span = span }
         table.insert(params, { specifiers = spec, declarator = decl, type = builtin_ty, span = span })
         if not at(p, TK_PUNCT, ",") then
            break
         end
         advance(p)
      until false
      return params, false
   end

   repeat
      if at(p, TK_PUNCT, "...") then
         is_variadic = true
         advance(p)
         break
      end
      local specs = parse_decl_specifiers(p)
      if not specs is nil then
         local d: ast.Declarator | nil = nil
         if not at(p, TK_PUNCT, ",") and not at(p, TK_PUNCT, ")") and not at(p, TK_PUNCT, "...") then
            d = parse_declarator(p, true)
         end
         local base = qualify(type_from_spec(specs.type_spec), specs.qualifiers)
         local ty = base
         if not (d is nil) then
            ty = apply_derived(base, d.derived)
         end
         local span = specs.span
         if not (d is nil) then
            span = span:merge(d.span)
         end
         table.insert(params, { specifiers = specs, declarator = d, type = ty, span = span })
         if not at(p, TK_PUNCT, ",") then
            break
         end
         advance(p)
      else break end
   until false
   return params, is_variadic
end

parse_declarator = function(p: Parser, allow_abstract: boolean): ast.Declarator
   skip_attributes(p)
   local pointers = parse_pointer_chain(p)
   skip_attributes(p)
   local name_tok: Token | nil = nil
   local lparen_span: Span | nil = nil
   if at(p, TK_PUNCT, "(") then
      lparen_span = advance(p).span
      local inner = parse_declarator(p, allow_abstract)
      expect(p, TK_PUNCT, ")", "PAR201")
      name_tok = inner.name
      local derived = inner.derived
      while at(p, TK_PUNCT, "[") or at(p, TK_PUNCT, "(") do
         if at(p, TK_PUNCT, "[") then
            local lbrack = advance(p)
            local arr_quals: {types.TypeQualifier} = {}
            local is_static = false
            -- type-qualifier-list? 'static'? type-qualifier-list? per C99
            while is_type_qualifier(cur(p)) do
               local q = cur(p).lexeme == "const" and "const" or cur(p).lexeme == "restrict" and "restrict" or "volatile"
               table.insert(arr_quals, q as types.TypeQualifier)
               advance(p)
            end
            if cur(p).kind == TK_KEYWORD and cur(p).lexeme == "static" then
               is_static = true
               advance(p)
               while is_type_qualifier(cur(p)) do
                  local q = cur(p).lexeme == "const" and "const" or cur(p).lexeme == "restrict" and "restrict" or "volatile"
                  table.insert(arr_quals, q as types.TypeQualifier)
                  advance(p)
               end
            end
            local size_expr: ast.ExprNode | nil = nil
            local is_vla = false
            if at(p, TK_PUNCT, "*") then
               is_vla = true
               advance(p)
            elseif not at(p, TK_PUNCT, "]") then
               size_expr = parse_expression(p)
            end
            local rbrack = expect(p, TK_PUNCT, "]", "PAR202")
            table.insert(derived, { kind = "array", span = lbrack.span:merge(rbrack.span), qualifiers = arr_quals, is_static = is_static, is_vla = is_vla, size = size_expr })
         else
            local lparen = advance(p)
            local params, is_variadic = parse_parameter_list(p)
            local rparen = expect(p, TK_PUNCT, ")", "PAR203")
            table.insert(derived, { kind = "function", params = params, is_variadic = is_variadic })
            if lparen_span is nil then
               lparen_span = lparen.span:merge(rparen.span)
            else
               lparen_span = lparen_span:merge(rparen.span)
            end
         end
      end
      for _, ptr in ipairs(pointers) do
         table.insert(derived, ptr)
      end
      local span = inner.span
      if lparen_span then
         span = lparen_span
      end
      return { name = name_tok, derived = derived, span = span }
   end

   if cur(p).kind == TK_IDENTIFIER then
      name_tok = advance(p)
   elseif not allow_abstract then
      report_error(p, "expected identifier", cur(p).span, "PAR204")
   end

   local derived: {ast.DerivedDeclarator} = {}
   while at(p, TK_PUNCT, "[") or at(p, TK_PUNCT, "(") do
      if at(p, TK_PUNCT, "[") then
         local lbrack = advance(p)
         local arr_quals: {types.TypeQualifier} = {}
         local is_static = false
         while is_type_qualifier(cur(p)) do
            local q = cur(p).lexeme == "const" and "const" or cur(p).lexeme == "restrict" and "restrict" or "volatile"
            table.insert(arr_quals, q as types.TypeQualifier)
            advance(p)
         end
         if cur(p).kind == TK_KEYWORD and cur(p).lexeme == "static" then
            is_static = true
            advance(p)
            while is_type_qualifier(cur(p)) do
               local q = cur(p).lexeme == "const" and "const" or cur(p).lexeme == "restrict" and "restrict" or "volatile"
               table.insert(arr_quals, q as types.TypeQualifier)
               advance(p)
            end
         end
         local size_expr: ast.ExprNode | nil = nil
         local is_vla = false
         if at(p, TK_PUNCT, "*") then
            is_vla = true
            advance(p)
         elseif not at(p, TK_PUNCT, "]") then
            size_expr = parse_expression(p)
         end
         local rbrack = expect(p, TK_PUNCT, "]", "PAR205")
         table.insert(derived, { kind = "array", span = lbrack.span:merge(rbrack.span), qualifiers = arr_quals, is_static = is_static, is_vla = is_vla, size = size_expr })
      else
         local lparen = advance(p)
         local params, is_variadic = parse_parameter_list(p)
         local rparen = expect(p, TK_PUNCT, ")", "PAR206")
         table.insert(derived, { kind = "function", params = params, is_variadic = is_variadic })
         if lparen_span is nil then
            lparen_span = lparen.span:merge(rparen.span)
         else
            lparen_span = lparen_span:merge(rparen.span)
         end
      end
   end

   for _, ptr in ipairs(pointers) do
      table.insert(derived, ptr)
   end

   local span = not name_tok is nil and name_tok.span or cur(p).span
   return { name = name_tok, derived = derived, span = span }
end

local function build_type(specs: ast.DeclSpecifiers, declarator: ast.Declarator | nil): types.TypeNode
   local base = type_from_spec(specs.type_spec)
   base = qualify(base, specs.qualifiers)
   if not declarator is nil then
      return apply_derived(base, declarator.derived)
   end
   return base
end

local function parse_type_name(p: Parser): ast.TypeName
   local specs = parse_decl_specifiers(p)
   if specs is nil then
      local t = cur(p)
      report_error(p, "expected type name", t.span, "PAR3000")
      specs = { storage = {}, func_specs = {}, qualifiers = {}, type_spec = { kind = "builtin", span = t.span, builtin = make_builtin_type(BN.int, t.span, true, false, false) }, span = t.span }
   end
   if specs is nil then return end
   local decl: ast.Declarator | nil = nil
   if not at(p, TK_PUNCT, ")") and not at(p, TK_PUNCT, ",") and not at(p, TK_PUNCT, "{") then
      decl = parse_declarator(p, true)
   end
   local ty = build_type(specs, decl)
   local span = specs.span
   if not decl is nil then
      span = span:merge(decl.span)
   end
   return { specifiers = specs, declarator = decl, type = ty, span = span }
end

local function parse_primary(p: Parser): ast.ExprNode
   local t = cur(p)
   if t.kind == TK_IDENTIFIER then
      advance(p)
      if at(p, TK_PUNCT, ":") then
         -- label lookahead handled in statement parsing; fallthrough
      end
      return { kind = "identifier", span = t.span, name = t }
   elseif t.kind == TK_NUMBER then
      advance(p)
      return { kind = "number_literal", span = t.span, token = t }
   elseif t.kind == TK_STRING then
      local parts: {Token} = {}
      repeat
         table.insert(parts, cur(p))
         advance(p)
      until cur(p).kind ~= TK_STRING
      local span = parts[1].span
      local last = parts[#parts].span
      span = span:merge(last)
      return { kind = "string_literal", span = span, parts = parts }
   elseif t.kind == TK_CHAR then
      advance(p)
      return { kind = "char_literal", span = t.span, token = t }
   elseif t.kind == TK_PUNCT and t.lexeme == "(" then
      advance(p)
      if is_type_specifier_start(p, cur(p)) then
         local type_name = parse_type_name(p)
         expect(p, TK_PUNCT, ")", "PAR3010")
         if at(p, TK_PUNCT, "{") then
            local init = parse_initializer(p)
            local span = type_name.span:merge(init.span)
            return { kind = "compound_literal", span = span, type_name = type_name, init = init } 
         else
            local value = parse_unary(p)
            local span = type_name.span:merge(value.span)
            return { kind = "cast", span = span, type_name = type_name, value = value } 
         end
      else
         local expr = parse_expression(p)
         expect(p, TK_PUNCT, ")", "PAR3011")
         return expr
      end
   end
   report_error(p, "unexpected token in expression", t.span, "PAR300")
   advance(p)
   return { kind = "identifier", span = t.span, name = t }
end

parse_postfix = function(p: Parser): ast.ExprNode
   local expr = parse_primary(p)
   while true do
      if at(p, TK_PUNCT, "(") then
         local lparen = advance(p)
         local args: {ast.ExprNode} = {}
         if not at(p, TK_PUNCT, ")") then
            repeat
               table.insert(args, parse_expression(p))
               if not at(p, TK_PUNCT, ",") then
                  break
               end
               advance(p)
            until false
         end
         local rparen = expect(p, TK_PUNCT, ")", "PAR303")
         local span = lparen.span:merge(rparen.span)
         expr = { kind = "call", span = span, callee = expr, args = args }
      elseif at(p, TK_PUNCT, "[") then
         local lbrack = advance(p)
         local index = parse_expression(p)
         local rbrack = expect(p, TK_PUNCT, "]", "PAR304")
         local span = lbrack.span:merge(rbrack.span)
         expr = { kind = "index", span = span, array = expr, index = index }
      elseif at(p, TK_PUNCT, ".") or at(p, TK_PUNCT, "->") then
         local op = advance(p)
         local field = expect(p, TK_IDENTIFIER, nil, "PAR305")
         local span = expr.span:merge(field.span)
         expr = { kind = "field", span = span, receiver = expr, field = field, is_arrow = op.lexeme == "->" } 
      elseif at(p, TK_PUNCT, "++") or at(p, TK_PUNCT, "--") then
         local op = advance(p)
         local span = expr.span:merge(op.span)
         expr = { kind = "unary", span = span, op = op, operand = expr, postfix = true }
      else
         break
      end
   end
   return expr
end

parse_unary = function(p: Parser): ast.ExprNode
   local t = cur(p)
   if t.kind == TK_PUNCT and (t.lexeme == "&" or t.lexeme == "*" or t.lexeme == "+" or t.lexeme == "-" or t.lexeme == "~" or t.lexeme == "!") then
      advance(p)
      local operand = parse_unary(p)
      local span = t.span:merge(operand.span)
      return { kind = "unary", span = span, op = t, operand = operand, postfix = false } 
   elseif t.kind == TK_PUNCT and (t.lexeme == "++" or t.lexeme == "--") then
      advance(p)
      local operand = parse_unary(p)
      local span = t.span:merge(operand.span)
      return { kind = "unary", span = span, op = t, operand = operand, postfix = false }
   elseif t.kind == TK_KEYWORD and t.lexeme == "sizeof" then
      local kw = advance(p)
      if at(p, TK_PUNCT, "(") and is_type_specifier_start(p, peek(p, 1)) then
         advance(p)
         local type_name = parse_type_name(p)
         expect(p, TK_PUNCT, ")", "PAR306")
         local span = kw.span:merge(type_name.span)
         return { kind = "sizeof", span = span, type_name = type_name, expr = nil } 
      else
         local operand = parse_unary(p)
         local span = kw.span:merge(operand.span)
         return { kind = "sizeof", span = span, type_name = nil, expr = operand } 
      end
   end
   return parse_postfix(p)
end

local function parse_binary_rhs(p: Parser, min_prec: integer, lhs: ast.ExprNode): ast.ExprNode
   while true do
      local op_tok = cur(p)
      if op_tok.kind ~= TK_PUNCT or not binary_precedence[op_tok.lexeme] then
         break
      end
      local prec = binary_precedence[op_tok.lexeme]
      if prec < min_prec then
         break
      end
      advance(p)
      local rhs = parse_unary(p)
      while true do
         local next_tok = cur(p)
         local next_prec = next_tok.kind == TK_PUNCT and binary_precedence[next_tok.lexeme] or nil
         if not next_prec or next_prec <= prec then
            break
         end
         rhs = parse_binary_rhs(p, prec + 1, rhs)
      end
      local span = lhs.span:merge(rhs.span)
      lhs = { kind = "binary", span = span, op = op_tok, lhs = lhs, rhs = rhs }
   end
   return lhs
end

parse_conditional = function(p: Parser): ast.ExprNode
   local cond = parse_unary(p)
   cond = parse_binary_rhs(p, 1, cond)
   if at(p, TK_PUNCT, "?") then
      advance(p)
      local then_expr = parse_expression(p)
      expect(p, TK_PUNCT, ":", "PAR307")
      local else_expr = parse_conditional(p)
      local span = cond.span:merge(else_expr.span)
      return { kind = "conditional", span = span, cond = cond, then_expr = then_expr, else_expr = else_expr } 
   end
   return cond
end

parse_assignment = function(p: Parser): ast.ExprNode
   local lhs = parse_conditional(p)
   local t = cur(p)
   if t.kind == TK_PUNCT and assignment_ops[t.lexeme] then
      advance(p)
      local rhs = parse_assignment(p)
      local span = lhs.span:merge(rhs.span)
      return { kind = "assignment", span = span, op = t, lhs = lhs, rhs = rhs } 
   end
   return lhs
end

parse_expression = function(p: Parser): ast.ExprNode
   local expr = parse_assignment(p)
   while at(p, TK_PUNCT, ",") do
      local op = advance(p)
      local rhs = parse_assignment(p)
      local span = expr.span:merge(rhs.span)
      expr = { kind = "binary", span = span, op = op, lhs = expr, rhs = rhs } 
   end
   return expr
end

parse_initializer = function(p: Parser): ast.Initializer
   if at(p, TK_PUNCT, "{") then
      local lbrace = advance(p)
      local entries: {ast.InitializerEntry} = {}
      while not at(p, TK_PUNCT, "}") and cur(p).kind ~= TK_EOF do
         local designators: {ast.Designator} = {}
         while at(p, TK_PUNCT, ".") or at(p, TK_PUNCT, "[") do
            if at(p, TK_PUNCT, ".") then
               local dot = advance(p)
               local name = expect(p, TK_IDENTIFIER, nil, "PAR308")
               table.insert(designators, { kind = "field", span = dot.span:merge(name.span), name = name })
            else
               local lbr = advance(p)
               local expr = parse_expression(p)
               local rbr = expect(p, TK_PUNCT, "]", "PAR309")
               table.insert(designators, { kind = "index", span = lbr.span:merge(rbr.span), index = expr })
            end
         end
         if #designators > 0 then
            expect(p, TK_PUNCT, "=", "PAR310")
         end
         local value = parse_initializer(p)
         local span = value.span
         if designators[#designators] then
            span = (designators[1].span):merge(value.span)
         end
         table.insert(entries, { designators = designators, value = value, span = span })
         if not at(p, TK_PUNCT, ",") then
            break
         end
         advance(p)
         if at(p, TK_PUNCT, "}") then
            break
         end
      end
      local rbrace = expect(p, TK_PUNCT, "}", "PAR311")
      local span = lbrace.span:merge(rbrace.span)
      return { kind = "list", span = span, entries = entries }
   else
      local expr = parse_assignment(p)
      return { kind = "expr", span = expr.span, expr = expr }
   end
end

local function is_typedef_specifier(specs: ast.DeclSpecifiers): boolean
   for _, s in ipairs(specs.storage) do
      if s == "typedef" then
         return true
      end
   end
   return false
end

local function parse_decl_or_func(p: Parser, specs: ast.DeclSpecifiers): {ast.DeclNode}
   local decls: {ast.DeclNode} = {}
   -- Allow declarations with only a tag specifier (e.g., 'struct S;').
   if at(p, TK_PUNCT, ";") then
      local ts = specs.type_spec
      if ts is ast.StructSpecifier or ts is ast.EnumSpecifier then
         local tag_ty = type_from_spec(ts)
         table.insert(decls, { kind = "tag", specifiers = specs, type = tag_ty, span = specs.span })
         return decls
      end
   end

   repeat
      local d = parse_declarator(p, false)
      skip_attributes(p)
      local ty = build_type(specs, d)
      local span = specs.span:merge(d.span)
      local is_function = false
      local outer = d.derived[1]
      if outer then
         is_function = outer is ast.FunctionDeclarator
      end
      if is_function then
         if is_typedef_specifier(specs) then
            table.insert(decls, { kind = "typedef", specifiers = specs, declarator = d, type = ty, span = span })
            local dname = d.name
            if not dname is nil then
               declare_typedef(p, dname.lexeme)
            end
         else
            local body: ast.StmtNode | nil = nil
            local old_params: {ast.DeclNode} = {}
            if at(p, TK_PUNCT, "{") then
               push_typedef_scope(p)
               body = parse_statement(p)
               pop_typedef_scope(p)
            else
               -- old-style parameter declarations before function body
               while looks_like_declaration(p) and not at(p, TK_PUNCT, "{") and cur(p).kind ~= TK_EOF do
                  local ospecs = parse_decl_specifiers(p)
                  if not ospecs is nil then
                     repeat
                        local pd = parse_declarator(p, false)
                        local pty = build_type(ospecs, pd)
                        local pspan = ospecs.span:merge(pd.span)
                        table.insert(old_params, { kind = "var", specifiers = ospecs, declarator = pd, type = pty, init = nil, span = pspan })
                        if not at(p, TK_PUNCT, ",") then
                           break
                        end
                        advance(p)
                     until false
                     expect(p, TK_PUNCT, ";", "PAR9000")
                  else break end
               end
               if at(p, TK_PUNCT, "{") then
                  push_typedef_scope(p)
                  body = parse_statement(p)
                  pop_typedef_scope(p)
               end
            end
            table.insert(decls, { kind = "func", specifiers = specs, declarator = d, type = ty, body = body, old_param_decls = old_params, span = span })
         end
      else
         local init: ast.Initializer | nil = nil
         if at(p, TK_PUNCT, "=") then
            advance(p)
            init = parse_initializer(p)
         end
         if is_typedef_specifier(specs) then
            table.insert(decls, { kind = "typedef", specifiers = specs, declarator = d, type = ty, span = span })
            local dname = d.name
            if not dname is nil then
               declare_typedef(p, dname.lexeme)
            end
         else
            table.insert(decls, { kind = "var", specifiers = specs, declarator = d, type = ty, init = init, span = span })
         end
      end
      if not at(p, TK_PUNCT, ",") then
         break
      end
      advance(p)
   until false
   return decls
end

parse_statement = function(p: Parser): ast.StmtNode
   local t = cur(p)
   if t.kind == TK_PUNCT and t.lexeme == ";" then
      local semi = advance(p)
      return { kind = "null", span = semi.span }
   elseif t.kind == TK_KEYWORD and t.lexeme == "if" then
      local kw = advance(p)
      expect(p, TK_PUNCT, "(", "PAR401")
      local cond = parse_expression(p)
      expect(p, TK_PUNCT, ")", "PAR402")
      local then_branch = parse_statement(p)
      local else_branch: ast.StmtNode | nil = nil
      if at(p, TK_KEYWORD, "else") then
         advance(p)
         else_branch = parse_statement(p)
      end
      local span = kw.span:merge((then_branch).span)
      if not else_branch is nil then
         span = span:merge(else_branch.span)
      end
      return { kind = "if", span = span, cond = cond, then_branch = then_branch, else_branch = else_branch }
   elseif t.kind == TK_KEYWORD and t.lexeme == "switch" then
      local kw = advance(p)
      expect(p, TK_PUNCT, "(", "PAR403")
      local expr = parse_expression(p)
      expect(p, TK_PUNCT, ")", "PAR404")
      local body = parse_statement(p)
      local span = kw.span:merge((body).span)
      return { kind = "switch", span = span, expr = expr, body = body }
   elseif t.kind == TK_KEYWORD and t.lexeme == "while" then
      local kw = advance(p)
      expect(p, TK_PUNCT, "(", "PAR405")
      local cond = parse_expression(p)
      expect(p, TK_PUNCT, ")", "PAR406")
      local body = parse_statement(p)
      local span = kw.span:merge((body).span)
      return { kind = "while", span = span, cond = cond, body = body }
   elseif t.kind == TK_KEYWORD and t.lexeme == "do" then
      local kw = advance(p)
      local body = parse_statement(p)
      expect(p, TK_KEYWORD, "while", "PAR407")
      expect(p, TK_PUNCT, "(", "PAR408")
      local cond = parse_expression(p)
      expect(p, TK_PUNCT, ")", "PAR409")
      expect(p, TK_PUNCT, ";", "PAR410")
      local span = kw.span:merge((body).span)
      return { kind = "do_while", span = span, body = body, cond = cond }
   elseif t.kind == TK_KEYWORD and t.lexeme == "for" then
      local kw = advance(p)
      expect(p, TK_PUNCT, "(", "PAR411")
      push_typedef_scope(p)
      local init: ast.StmtNode | nil = nil
      if not at(p, TK_PUNCT, ";") then
         if looks_like_declaration(p) then
            local specs_opt = parse_decl_specifiers(p)
            if not (specs_opt is nil) then
               local specs = specs_opt
               local decls = parse_decl_or_func(p, specs)
               expect(p, TK_PUNCT, ";", "PAR412")
               init = { kind = "decl", span = specs.span, decls = decls }
            end
         else
            local expr = parse_expression(p)
            expect(p, TK_PUNCT, ";", "PAR413")
            init = { kind = "expr", span = expr.span, expr = expr }
         end
      else
         advance(p)
      end
      local cond: ast.ExprNode | nil = nil
      if not at(p, TK_PUNCT, ";") then
         cond = parse_expression(p)
      end
      expect(p, TK_PUNCT, ";", "PAR414")
      local step: ast.ExprNode | nil = nil
      if not at(p, TK_PUNCT, ")") then
         step = parse_expression(p)
      end
      expect(p, TK_PUNCT, ")", "PAR415")
      local body = parse_statement(p)
      pop_typedef_scope(p)
      local span = kw.span:merge((body).span)
      return { kind = "for", span = span, init = init, cond = cond, step = step, body = body }
   elseif t.kind == TK_KEYWORD and t.lexeme == "return" then
      local kw = advance(p)
      local expr: ast.ExprNode | nil = nil
      if not at(p, TK_PUNCT, ";") then
         expr = parse_expression(p)
      end
      expect(p, TK_PUNCT, ";", "PAR416")
      local span = kw.span
      if not expr is nil then
         span = span:merge(expr.span)
      end
      return { kind = "return", span = span, value = expr }
   elseif t.kind == TK_KEYWORD and t.lexeme == "break" then
      local kw = advance(p)
      expect(p, TK_PUNCT, ";", "PAR417")
      return { kind = "break", span = kw.span }
   elseif t.kind == TK_KEYWORD and t.lexeme == "continue" then
      local kw = advance(p)
      expect(p, TK_PUNCT, ";", "PAR418")
      return { kind = "continue", span = kw.span }
   elseif t.kind == TK_KEYWORD and t.lexeme == "goto" then
      local kw = advance(p)
      local name = expect(p, TK_IDENTIFIER, nil, "PAR419")
      expect(p, TK_PUNCT, ";", "PAR420")
      local span = kw.span:merge(name.span)
      return { kind = "goto", span = span, name = name }
   elseif at(p, TK_IDENTIFIER) and peek(p, 1).kind == TK_PUNCT and peek(p, 1).lexeme == ":" then
      local name = advance(p)
      advance(p) -- consume colon
      local body = parse_statement(p)
      local span = name.span:merge((body).span)
      return { kind = "label", span = span, name = name, body = body }
   elseif t.kind == TK_KEYWORD and t.lexeme == "case" then
      local kw = advance(p)
      local expr = parse_expression(p)
      expect(p, TK_PUNCT, ":", "PAR421")
      local body = parse_statement(p)
      local span = kw.span:merge((body).span)
      return { kind = "case", span = span, expr = expr, body = body }
   elseif t.kind == TK_KEYWORD and t.lexeme == "default" then
      local kw = advance(p)
      expect(p, TK_PUNCT, ":", "PAR422")
      local body = parse_statement(p)
      local span = kw.span:merge((body).span)
      return { kind = "default", span = span, body = body }
   elseif t.kind == TK_PUNCT and t.lexeme == "{" then
      local lbrace = advance(p)
      push_typedef_scope(p)
      local items: {ast.StmtNode} = {}
      while not at(p, TK_PUNCT, "}") and cur(p).kind ~= TK_EOF do
         if looks_like_declaration(p) then
            local specs_opt = parse_decl_specifiers(p)
            if specs_opt is nil then
               break
            end
            local specs = specs_opt
            local decls = parse_decl_or_func(p, specs)
            expect(p, TK_PUNCT, ";", "PAR423")
            table.insert(items, { kind = "decl", span = not specs is nil and specs.span or nil, decls = decls })
         else
            table.insert(items, parse_statement(p))
         end
      end
      local rbrace = expect(p, TK_PUNCT, "}", "PAR424")
      pop_typedef_scope(p)
      local span = lbrace.span:merge(rbrace.span)
      return { kind = "compound", span = span, items = items }
   elseif looks_like_declaration(p) then
      local specs_opt = parse_decl_specifiers(p)
      if specs_opt is nil then
         report_error(p, "expected declaration", cur(p).span, "PAR425")
         advance(p)
         return { kind = "null", span = cur(p).span }
      end
      local specs = specs_opt
      local decls = parse_decl_or_func(p, specs)
      expect(p, TK_PUNCT, ";", "PAR426")
      return { kind = "decl", span = specs.span, decls = decls }
   else
      local expr = parse_expression(p)
      expect(p, TK_PUNCT, ";", "PAR427")
      return { kind = "expr", span = expr.span, expr = expr }
   end
end

local function parse_external_declaration(p: Parser): {ast.DeclNode}
   local specs = parse_decl_specifiers(p)
   if not specs then
      local t = cur(p)
      report_error(p, "expected declaration", t.span, "PAR700")
      advance(p)
      return {}
   end
   local decls = parse_decl_or_func(p, specs)
   local last = decls[#decls]
   local needs_semicolon = true
   if last and last is ast.FuncDecl then
      local body = last.body
      needs_semicolon = body is nil
   elseif last and last is ast.TagDecl then
      needs_semicolon = true
   end
   if needs_semicolon then
      expect(p, TK_PUNCT, ";", "PAR701")
   end
   return decls
end

local function tokens_to_iter(tokens: {Token}): TokenIterator
   local idx = 0
   local last = tokens[#tokens]
   if last is nil then
      error("parser requires at least one token")
   end
   local tail = last as Token
   return function(): Token
      idx = idx + 1
      local t = tokens[idx]
      if t then
         return t
      end
      return tail
   end
end

local function parse_translation_unit(p: Parser): ast.TranslationUnit
   local decls: {ast.DeclNode} = {}
   while cur(p).kind ~= TK_EOF do
      if at(p, TK_PUNCT, ";") then
         advance(p)
         goto continue
      end
      local parsed = parse_external_declaration(p)
      for _, d in ipairs(parsed) do
         table.insert(decls, d)
      end
      ::continue::
   end
   return { decls = decls }
end

local function parse_source(source: string, file_id: integer, reporter?: Reporter, tokens?: {Token}): ast.TranslationUnit
   local rep = reporter or Reporter.new()
   local iter: TokenIterator
   if tokens then
      iter = tokens_to_iter(tokens)
   else
      iter = Lexer.lex(source, file_id, rep)
   end
   local p = new_parser(iter, rep)
   return parse_translation_unit(p)
end

return {
   parse = parse_source,
}
