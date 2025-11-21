local Span = require("util.span")
local token_mod = require("lexer.token")
local TokenRecord = token_mod.Token
local type Token = token_mod.Token
local type Trivia = token_mod.Trivia
local type TokenKindType = token_mod.TokenKind
local type TriviaKindType = token_mod.TriviaKind
local TK_IDENTIFIER: TokenKindType = "identifier"
local TK_NUMBER: TokenKindType = "number"
local TK_STRING: TokenKindType = "string"
local TK_CHAR: TokenKindType = "char"
local TK_KEYWORD: TokenKindType = "keyword"
local TK_PUNCT: TokenKindType = "punctuator"
local TK_EOF: TokenKindType = "eof"
local Diagnostic = require("diag.diagnostics")
local Reporter = require("diag.reporter")
local ffi = require("ffi")
local bit = require("bit")
local band = bit.band
local bor = bit.bor

local keywords: {string:boolean} = {
   ["auto"] = true, ["break"] = true, ["case"] = true, ["char"] = true, ["const"] = true,
   ["continue"] = true, ["default"] = true, ["do"] = true, ["double"] = true, ["else"] = true,
   ["enum"] = true, ["extern"] = true, ["float"] = true, ["for"] = true, ["goto"] = true,
   ["if"] = true, ["inline"] = true, ["int"] = true, ["long"] = true, ["register"] = true,
   ["restrict"] = true, ["return"] = true, ["short"] = true, ["signed"] = true, ["sizeof"] = true,
   ["static"] = true, ["struct"] = true, ["switch"] = true, ["typedef"] = true, ["union"] = true,
   ["unsigned"] = true, ["void"] = true, ["volatile"] = true, ["while"] = true, ["_Bool"] = true,
   ["_Complex"] = true, ["_Imaginary"] = true,
}

local punctuators: {string:boolean} = {
   ["{"] = true, ["}"] = true, ["("] = true, [")"] = true, ["["] = true, ["]"] = true,
   [";"] = true, [","] = true, ["."] = true, ["->"] = true, ["++"] = true, ["--"] = true,
   ["&"] = true, ["*"] = true, ["+"] = true, ["-"] = true, ["~"] = true, ["!"] = true,
   ["/"] = true, ["%"] = true, ["<<"] = true, [">>"] = true, ["<"] = true, [">"] = true,
   ["<="] = true, [">="] = true, ["=="] = true, ["!="] = true, ["^"] = true, ["|"] = true,
   ["&&"] = true, ["||"] = true, ["?"] = true, [":"] = true, ["#"] = true, ["##"] = true, ["="] = true, ["+="] = true,
   ["-="] = true, ["*="] = true, ["/="] = true, ["%="] = true, ["&="] = true, ["|="] = true,
   ["^="] = true, ["<<="] = true, [">>="] = true, ["..."] = true,
}

-- FFI Types
local type Uint8Ptr = ffi.Pointer<integer>
local type Uint8Array = ffi.Array<integer>

-- Character properties
local PROP_SPACE = 1
local PROP_DIGIT = 2
local PROP_ALPHA = 4
local PROP_IDENT = 8
local PROP_HEX = 16

local char_props = ffi.new("uint8_t[256]") as Uint8Array
local punct_max_len = ffi.new("uint8_t[256]") as Uint8Array

for i = 0, 255 do
   local c = string.char(i)
   local p = 0
   if c:match("%s") then p = bor(p, PROP_SPACE) end
   if c:match("%d") then p = bor(p, PROP_DIGIT) end
   if c:match("[%a_]") then p = bor(p, PROP_ALPHA) end
   if c:match("[%w_]") then p = bor(p, PROP_IDENT) end
   if c:match("[%da-fA-F]") then p = bor(p, PROP_HEX) end
   char_props[i] = p
end

for k, _ in pairs(punctuators) do
   local b = string.byte(k, 1)
   local l = #k
   if l > punct_max_len[b] then
      punct_max_len[b] = l
   end
end

-- Metatable caching
local dummy_span = Span.new(0, 0, 0, 0, 0)
local span_mt: metatable<any> = getmetatable(dummy_span) as metatable<any>

local dummy_token = TokenRecord.new(TK_EOF, "", dummy_span)
local token_mt: metatable<any> = getmetatable(dummy_token) as metatable<any>

local empty_trivia_list: {Trivia} = {}

local record Lexer
   src: string
   src_ptr: Uint8Ptr -- const uint8_t*
   len: integer
   file_id: integer
   pos: integer -- 0-based
   line: integer
   col: integer
   reporter: Reporter | nil
   tokens: {Token}
end

local function make_span(lex: Lexer, start_pos: integer, end_pos: integer, line: integer, col: integer): Span
   return setmetatable({
      file_id = lex.file_id,
      start_offset = start_pos + 1,
      end_offset = end_pos + 1,
      line = line,
      column = col,
   } as any, span_mt) as Span
end

local function add_diag(lex: Lexer, message: string, span: Span, code: string)
   local rep = lex.reporter
   if not rep is nil then
      rep:report(Diagnostic.new("error", message, span, code))
   end
end

local function new_lexer(src: string, file_id: integer, reporter: Reporter | nil): Lexer
   local len = #src
   local ptr = ffi.cast("const uint8_t*", src) as Uint8Ptr
   return {
      src = src,
      src_ptr = ptr,
      len = len,
      file_id = file_id,
      pos = 0,
      line = 1,
      col = 1,
      reporter = reporter,
      tokens = {},
   }
end

local function consume_whitespace(lex: Lexer): {Trivia}
   local trivia: {Trivia}
   local trivia_count = 0
   local ptr = lex.src_ptr
   local len = lex.len

   while lex.pos < len do
      local c = ptr[lex.pos]
      
      if band(char_props[c], PROP_SPACE) ~= 0 then
         if not trivia then trivia = {} end
         if c == 10 then -- \n
            local start_pos = lex.pos
            local start_line = lex.line
            local start_col = lex.col
            lex.pos = lex.pos + 1
            lex.line = lex.line + 1
            lex.col = 1
            
            local span = setmetatable({
               file_id = lex.file_id,
               start_offset = start_pos + 1,
               end_offset = lex.pos + 1,
               line = start_line,
               column = start_col,
            } as any, span_mt) as Span
            
            trivia_count = trivia_count + 1
            trivia[trivia_count] = { kind = "newline", lexeme = "\n", span = span }
         else
            local start_pos = lex.pos
            local start_line = lex.line
            local start_col = lex.col
            while lex.pos < len do
               local cc = ptr[lex.pos]
               if band(char_props[cc], PROP_SPACE) == 0 or cc == 10 then
                  break
               end
               lex.pos = lex.pos + 1
               lex.col = lex.col + 1
            end
            
            local span = setmetatable({
               file_id = lex.file_id,
               start_offset = start_pos + 1,
               end_offset = lex.pos + 1,
               line = start_line,
               column = start_col,
            } as any, span_mt) as Span
            
            local text = ffi.string(lex.src_ptr + start_pos, lex.pos - start_pos)
            trivia_count = trivia_count + 1
            trivia[trivia_count] = { kind = "whitespace", lexeme = text, span = span }
         end
      elseif c == 47 then -- /
         if lex.pos + 1 < len then
            local next_c = ptr[lex.pos + 1]
            if next_c == 47 then -- //
               if not trivia then trivia = {} end
               local start_pos = lex.pos
               local start_line = lex.line
               local start_col = lex.col
               lex.pos = lex.pos + 2
               lex.col = lex.col + 2
               while lex.pos < len do
                  local cc = ptr[lex.pos]
                  if cc == 10 then break end
                  lex.pos = lex.pos + 1
                  lex.col = lex.col + 1
               end
               
               local span = setmetatable({
                  file_id = lex.file_id,
                  start_offset = start_pos + 1,
                  end_offset = lex.pos + 1,
                  line = start_line,
                  column = start_col,
               } as any, span_mt) as Span
               
               local text = ffi.string(lex.src_ptr + start_pos, lex.pos - start_pos)
               trivia_count = trivia_count + 1
               trivia[trivia_count] = { kind = "comment", lexeme = text, span = span }
            elseif next_c == 42 then -- /*
               if not trivia then trivia = {} end
               local start_pos = lex.pos
               local start_line = lex.line
               local start_col = lex.col
               lex.pos = lex.pos + 2
               lex.col = lex.col + 2
               local terminated = false
               while lex.pos < len do
                  local cc = ptr[lex.pos]
                  if cc == 42 and lex.pos + 1 < len and ptr[lex.pos + 1] == 47 then -- */
                     lex.pos = lex.pos + 2
                     lex.col = lex.col + 2
                     terminated = true
                     break
                  end
                  if cc == 10 then
                     lex.line = lex.line + 1
                     lex.col = 1
                  else
                     lex.col = lex.col + 1
                  end
                  lex.pos = lex.pos + 1
               end
               
               local span = setmetatable({
                  file_id = lex.file_id,
                  start_offset = start_pos + 1,
                  end_offset = lex.pos + 1,
                  line = start_line,
                  column = start_col,
               } as any, span_mt) as Span
               
               if not terminated then
                  add_diag(lex, "unterminated block comment", span, "LEX001")
               end
               
               local text = ffi.string(lex.src_ptr + start_pos, lex.pos - start_pos)
               trivia_count = trivia_count + 1
               trivia[trivia_count] = { kind = "comment", lexeme = text, span = span }
            else
               break
            end
         else
            break
         end
      else
         break
      end
   end
   return trivia or empty_trivia_list
end

local function read_number(lex: Lexer, leading: {Trivia}): Token
   local start_pos = lex.pos
   local start_line = lex.line
   local start_col = lex.col
   local ptr = lex.src_ptr
   local len = lex.len

   while lex.pos < len do
      local c = ptr[lex.pos]
      if band(char_props[c], PROP_DIGIT) ~= 0 or c == 46 or 
         c == 120 or c == 88 or -- x X
         c == 112 or c == 80 or -- p P
         c == 101 or c == 69 or -- e E
         c == 117 or c == 85 or -- u U
         c == 108 or c == 76    -- l L
      then
         lex.pos = lex.pos + 1
         lex.col = lex.col + 1
      else
         break
      end
   end
   local span = setmetatable({
      file_id = lex.file_id,
      start_offset = start_pos + 1,
      end_offset = lex.pos + 1,
      line = start_line,
      column = start_col,
   } as any, span_mt) as Span
   
   local lexeme = ffi.string(ptr + start_pos, lex.pos - start_pos)
   return setmetatable({
      kind = TK_NUMBER,
      lexeme = lexeme,
      span = span,
      leading = leading,
      trailing = empty_trivia_list,
   } as any, token_mt) as Token
end

local function read_identifier_or_keyword(lex: Lexer, leading: {Trivia}): Token
   local start_pos = lex.pos
   local start_line = lex.line
   local start_col = lex.col
   local ptr = lex.src_ptr
   local len = lex.len

   lex.pos = lex.pos + 1
   lex.col = lex.col + 1

   while lex.pos < len do
      local c = ptr[lex.pos]
      if band(char_props[c], PROP_IDENT) ~= 0 then
         lex.pos = lex.pos + 1
         lex.col = lex.col + 1
      else
         break
      end
   end

   local lexeme = ffi.string(ptr + start_pos, lex.pos - start_pos)
   local kind: TokenKindType = keywords[lexeme] and TK_KEYWORD or TK_IDENTIFIER
   local span = setmetatable({
      file_id = lex.file_id,
      start_offset = start_pos + 1,
      end_offset = lex.pos + 1,
      line = start_line,
      column = start_col,
   } as any, span_mt) as Span
   
   return setmetatable({
      kind = kind,
      lexeme = lexeme,
      span = span,
      leading = leading,
      trailing = empty_trivia_list,
   } as any, token_mt) as Token
end

local function read_string_like(lex: Lexer, leading: {Trivia}, quote: integer, token_kind: TokenKindType, start_pos_override?: integer, start_line_override?: integer, start_col_override?: integer): Token
   local start_pos = start_pos_override or lex.pos
   local start_line = start_line_override or lex.line
   local start_col = start_col_override or lex.col
   local ptr = lex.src_ptr
   local len = lex.len

   lex.pos = lex.pos + 1 -- consume opening quote
   lex.col = lex.col + 1

   while lex.pos < len do
      local c = ptr[lex.pos]
      if c == 92 then -- \
         if lex.pos + 1 < len then
            lex.pos = lex.pos + 2
            lex.col = lex.col + 2
         else
            lex.pos = lex.pos + 1
            lex.col = lex.col + 1
            break
         end
      elseif c == quote then
         lex.pos = lex.pos + 1
         lex.col = lex.col + 1
         break
      elseif c == 10 then -- \n
         lex.line = lex.line + 1
         lex.col = 1
         lex.pos = lex.pos + 1
      else
         lex.pos = lex.pos + 1
         lex.col = lex.col + 1
      end
   end
   
   if lex.pos > len then lex.pos = len end

   local span = setmetatable({
      file_id = lex.file_id,
      start_offset = start_pos + 1,
      end_offset = lex.pos + 1,
      line = start_line,
      column = start_col,
   } as any, span_mt) as Span
   
   local lexeme = ffi.string(ptr + start_pos, lex.pos - start_pos)
   return setmetatable({
      kind = token_kind,
      lexeme = lexeme,
      span = span,
      leading = leading,
      trailing = empty_trivia_list,
   } as any, token_mt) as Token
end

local function match_punctuator(lex: Lexer, leading: {Trivia}): Token
   local start_pos = lex.pos
   local start_line = lex.line
   local start_col = lex.col
   local ptr = lex.src_ptr
   local len = lex.len
   
   local c = ptr[lex.pos]
   local max_len = punct_max_len[c]

   if max_len >= 3 and lex.pos + 2 < len then
      local s = ffi.string(ptr + lex.pos, 3)
      if punctuators[s] then
         lex.pos = lex.pos + 3
         lex.col = lex.col + 3
         local span = setmetatable({
            file_id = lex.file_id,
            start_offset = start_pos + 1,
            end_offset = lex.pos + 1,
            line = start_line,
            column = start_col,
         } as any, span_mt) as Span
         return setmetatable({
            kind = TK_PUNCT,
            lexeme = s,
            span = span,
            leading = leading,
            trailing = empty_trivia_list,
         } as any, token_mt) as Token
      end
   end

   if max_len >= 2 and lex.pos + 1 < len then
      local s = ffi.string(ptr + lex.pos, 2)
      if punctuators[s] then
         lex.pos = lex.pos + 2
         lex.col = lex.col + 2
         local span = setmetatable({
            file_id = lex.file_id,
            start_offset = start_pos + 1,
            end_offset = lex.pos + 1,
            line = start_line,
            column = start_col,
         } as any, span_mt) as Span
         return setmetatable({
            kind = TK_PUNCT,
            lexeme = s,
            span = span,
            leading = leading,
            trailing = empty_trivia_list,
         } as any, token_mt) as Token
      end
   end

   local s = string.char(c)
   if punctuators[s] then
      lex.pos = lex.pos + 1
      lex.col = lex.col + 1
      local span = setmetatable({
         file_id = lex.file_id,
         start_offset = start_pos + 1,
         end_offset = lex.pos + 1,
         line = start_line,
         column = start_col,
      } as any, span_mt) as Span
      return setmetatable({
         kind = TK_PUNCT,
         lexeme = s,
         span = span,
         leading = leading,
         trailing = empty_trivia_list,
      } as any, token_mt) as Token
   end

   lex.pos = lex.pos + 1
   lex.col = lex.col + 1
   local span = setmetatable({
      file_id = lex.file_id,
      start_offset = start_pos + 1,
      end_offset = lex.pos + 1,
      line = start_line,
      column = start_col,
   } as any, span_mt) as Span
   add_diag(lex, "unknown character: " .. s, span, "LEX003")
   return setmetatable({
      kind = TK_PUNCT,
      lexeme = s,
      span = span,
      leading = leading,
      trailing = empty_trivia_list,
   } as any, token_mt) as Token
end

local function lex_all(source: string, file_id: integer, reporter: Reporter | nil): {Token}
   local lex = new_lexer(source, file_id, reporter)
   local ptr = lex.src_ptr
   local len = lex.len
   local tokens = lex.tokens
   local token_count = 0

   while lex.pos < len do
      local leading = consume_whitespace(lex)
      if lex.pos >= len then
         local eof_span = setmetatable({
            file_id = lex.file_id,
            start_offset = lex.pos + 1,
            end_offset = lex.pos + 1,
            line = lex.line,
            column = lex.col,
         } as any, span_mt) as Span
         token_count = token_count + 1
         tokens[token_count] = setmetatable({
            kind = TK_EOF,
            lexeme = "",
            span = eof_span,
            leading = leading,
            trailing = empty_trivia_list,
         } as any, token_mt) as Token
         break
      end

      local c = ptr[lex.pos]
      
      if c == 76 then -- L
         local next_c = (lex.pos + 1 < len) and ptr[lex.pos + 1] or 0
         if next_c == 34 or next_c == 39 then -- " or '
            local start_pos = lex.pos
            local start_line = lex.line
            local start_col = lex.col
            lex.pos = lex.pos + 1
            lex.col = lex.col + 1
            token_count = token_count + 1
            tokens[token_count] = read_string_like(lex, leading, next_c, next_c == 39 and TK_CHAR or TK_STRING, start_pos, start_line, start_col)
         else
            token_count = token_count + 1
            tokens[token_count] = read_identifier_or_keyword(lex, leading)
         end
      elseif band(char_props[c], PROP_ALPHA) ~= 0 then
         token_count = token_count + 1
         tokens[token_count] = read_identifier_or_keyword(lex, leading)
      elseif band(char_props[c], PROP_DIGIT) ~= 0 then
         token_count = token_count + 1
         tokens[token_count] = read_number(lex, leading)
      elseif c == 39 then -- '
         token_count = token_count + 1
         tokens[token_count] = read_string_like(lex, leading, 39, TK_CHAR)
      elseif c == 34 then -- "
         token_count = token_count + 1
         tokens[token_count] = read_string_like(lex, leading, 34, TK_STRING)
      else
         token_count = token_count + 1
         tokens[token_count] = match_punctuator(lex, leading)
      end
   end
   
   if #tokens == 0 or tokens[#tokens].kind ~= TK_EOF then
       local eof_span = setmetatable({
          file_id = lex.file_id,
          start_offset = lex.pos + 1,
          end_offset = lex.pos + 1,
          line = lex.line,
          column = lex.col,
       } as any, span_mt) as Span
       token_count = token_count + 1
       tokens[token_count] = setmetatable({
          kind = TK_EOF,
          lexeme = "",
          span = eof_span,
          leading = empty_trivia_list,
          trailing = empty_trivia_list,
       } as any, token_mt) as Token
   end

   return tokens
end

return {
   lex = lex_all,
   keywords = keywords,
}
