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

local record Lexer
   src: string
   file_id: integer
   pos: integer
   line: integer
   col: integer
   reporter: Reporter | nil
   tokens: {Token}
end

local function make_span(lex: Lexer, start_pos: integer, end_pos: integer, line: integer, col: integer): Span
   return Span.new(lex.file_id, start_pos, end_pos, line, col)
end

local function add_diag(lex: Lexer, message: string, span: Span, code: string)
   local rep = lex.reporter
   if not rep is nil then
      rep:report(Diagnostic.new("error", message, span, code))
   end
end

local function new_lexer(src: string, file_id: integer, reporter: Reporter | nil): Lexer
   return {
      src = src,
      file_id = file_id,
      pos = 1,
      line = 1,
      col = 1,
      reporter = reporter,
      tokens = {},
   }
end

local function peek(lex: Lexer, offset: integer): string | nil
   local idx = lex.pos + offset
   if idx > #lex.src then
      return nil
   end
   return string.sub(lex.src, idx, idx)
end

local function advance(lex: Lexer, count: integer): string
   count = count or 1
   local start = lex.pos
   local finish = lex.pos + count - 1
   if finish < start then
      return ""
   end
   lex.pos = finish + 1
   return string.sub(lex.src, start, finish)
end

local function bump(lex: Lexer): string | nil
   local ch = peek(lex, 0)
   if not ch then
      return nil
   end
   advance(lex, 1)
   if ch == "\n" then
      lex.line = lex.line + 1
      lex.col = 1
   else
      lex.col = lex.col + 1
   end
   return ch
end

local function make_trivia(lex: Lexer, kind: TriviaKindType, start_offset: integer, end_offset: integer, start_line: integer, start_col: integer): Trivia
   local span = make_span(lex, start_offset, end_offset, start_line, start_col)
   local text = string.sub(lex.src, start_offset, end_offset - 1)
   return { kind = kind, lexeme = text, span = span }
end

local function consume_whitespace(lex: Lexer): {Trivia}
   local trivia: {Trivia} = {}
   while true do
      local ch = peek(lex, 0)
      if not ch then
         break
      end

      if ch == " " or ch == "\t" or ch == "\r" then
         local start_pos = lex.pos
         local start_line = lex.line
         local start_col = lex.col
         while true do
            local c = peek(lex, 0)
            if c ~= " " and c ~= "\t" and c ~= "\r" then
               break
            end
            bump(lex)
         end
         table.insert(trivia, make_trivia(lex, "whitespace", start_pos, lex.pos, start_line, start_col))
      elseif ch == "\n" then
         local start_pos = lex.pos
         local start_line = lex.line
         local start_col = lex.col
         bump(lex)
         table.insert(trivia, make_trivia(lex, "newline", start_pos, lex.pos, start_line, start_col))
      elseif ch == "/" and peek(lex, 1) == "/" then
         local start_pos = lex.pos
         local start_line = lex.line
         local start_col = lex.col
         bump(lex)
         bump(lex)
         while true do
            local c = peek(lex, 0)
            if not c or c == "\n" then
               break
            end
            bump(lex)
         end
         table.insert(trivia, make_trivia(lex, "comment", start_pos, lex.pos, start_line, start_col))
      elseif ch == "/" and peek(lex, 1) == "*" then
         local start_pos = lex.pos
         local start_line = lex.line
         local start_col = lex.col
         bump(lex)
         bump(lex)
         while true do
            local c = peek(lex, 0)
            if not c then
               local span = make_span(lex, start_pos, lex.pos, start_line, start_col)
               add_diag(lex, "unterminated block comment", span, "LEX001")
               break
            end
            if c == "*" and peek(lex, 1) == "/" then
               bump(lex)
               bump(lex)
               break
            end
            bump(lex)
         end
         table.insert(trivia, make_trivia(lex, "comment", start_pos, lex.pos, start_line, start_col))
      else
         break
      end
   end
   return trivia
end

local function read_number(lex: Lexer, leading: {Trivia}): Token
   local start_pos = lex.pos
   local start_line = lex.line
   local start_col = lex.col
   while true do
      local c = peek(lex, 0)
      if not c is nil and c:match("[%d]") or c == "." or c == "x" or c == "X" or c == "p" or c == "P" or c == "e" or c == "E" or c == "u" or c == "U" or c == "l" or c == "L" then
         bump(lex)
      else
         break
      end
   end
   local span = make_span(lex, start_pos, lex.pos, start_line, start_col)
   local lexeme = string.sub(lex.src, start_pos, lex.pos - 1)
   return TokenRecord.new(TK_NUMBER, lexeme, span, leading, {})
end

local function read_identifier_or_keyword(lex: Lexer, leading: {Trivia}): Token
   local start_pos = lex.pos
   local start_line = lex.line
   local start_col = lex.col
   bump(lex)
   while true do
      local c = peek(lex, 0)
      if not c is nil then
         if c:match("[%w_]") then
            bump(lex)
         else
            break
         end
      else
         break
      end
   end
   local lexeme = string.sub(lex.src, start_pos, lex.pos - 1)
   local kind: TokenKindType = keywords[lexeme] and TK_KEYWORD or TK_IDENTIFIER
   local span = make_span(lex, start_pos, lex.pos, start_line, start_col)
   return TokenRecord.new(kind, lexeme, span, leading, {})
end

local function read_string_like(lex: Lexer, leading: {Trivia}, quote: string, token_kind: TokenKindType, start_pos_override?: integer, start_line_override?: integer, start_col_override?: integer): Token
   local start_pos = start_pos_override or lex.pos
   local start_line = start_line_override or lex.line
   local start_col = start_col_override or lex.col
   bump(lex) -- consume opening quote
   while true do
      local c = peek(lex, 0)
      if not c then
         local span = make_span(lex, start_pos, lex.pos, start_line, start_col)
         add_diag(lex, "unterminated string/char literal", span, "LEX002")
         break
      end
      if c == "\\" then
         bump(lex)
         bump(lex)
      elseif c == quote then
         bump(lex)
         break
      else
         bump(lex)
      end
   end
   local span = make_span(lex, start_pos, lex.pos, start_line, start_col)
   local lexeme = string.sub(lex.src, start_pos, lex.pos - 1)
   return TokenRecord.new(token_kind, lexeme, span, leading, {})
end

local function match_punctuator(lex: Lexer, leading: {Trivia}): Token
   local start_pos = lex.pos
   local start_line = lex.line
   local start_col = lex.col

   local two: string | nil = nil
   local c1 = peek(lex, 0)
   local c2 = peek(lex, 1)
   if not c1 is nil and not c2 is nil then
      two = c1..c2
   end

   local three: string | nil = nil
   local c3 = peek(lex, 2)
   if two and not c3 is nil then
      three = two .. c3
   end

   if three and punctuators[three] then
      advance(lex, 3)
   elseif two and punctuators[two] then
      advance(lex, 2)
   elseif c1 and punctuators[c1] then
      advance(lex, 1)
   else
      -- unknown char, treat as single punctuator and diag
      advance(lex, 1)
      local span = make_span(lex, start_pos, lex.pos, start_line, start_col)
      add_diag(lex, "unknown character: " .. tostring(c1), span, "LEX003")
   end

   local lexeme = string.sub(lex.src, start_pos, lex.pos - 1)
   local span = make_span(lex, start_pos, lex.pos, start_line, start_col)
   return TokenRecord.new(TK_PUNCT, lexeme, span, leading, {})
end

local function lex_all(source: string, file_id: integer, reporter: Reporter | nil): {Token}
   local lex = new_lexer(source, file_id, reporter)

   while true do
      local leading = consume_whitespace(lex)
      local ch = peek(lex, 0)
      if not ch is nil then
         if ch == "L" and (peek(lex, 1) == '"' or peek(lex, 1) == "'") then
            local start_pos = lex.pos
            local start_line = lex.line
            local start_col = lex.col
            bump(lex) -- consume L
            local q = peek(lex, 0)
            table.insert(lex.tokens, read_string_like(lex, leading, q, q == "'" and TK_CHAR or TK_STRING, start_pos, start_line, start_col))
         elseif ch:match("[%a_]") then
            table.insert(lex.tokens, read_identifier_or_keyword(lex, leading))
         elseif ch:match("%d") then
            table.insert(lex.tokens, read_number(lex, leading))
         elseif ch == "'" then
            table.insert(lex.tokens, read_string_like(lex, leading, "'", TK_CHAR))
         elseif ch == '"' then
            table.insert(lex.tokens, read_string_like(lex, leading, '"', TK_STRING))
         else
            table.insert(lex.tokens, match_punctuator(lex, leading))
         end
      else break end
   end

   local eof_span = make_span(lex, lex.pos, lex.pos, lex.line, lex.col)
   local eof_leading = consume_whitespace(lex)
   table.insert(lex.tokens, TokenRecord.new(TK_EOF, "", eof_span, eof_leading, {}))
   return lex.tokens
end

return {
   lex = lex_all,
   keywords = keywords,
}