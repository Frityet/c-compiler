local Span = require("util.span")

local enum TriviaKind
   "whitespace"
   "newline"
   "comment"
end

local record Trivia
   kind: TriviaKind
   lexeme: string
   span: Span
end

local enum TokenKind
   "identifier"
   "number"
   "string"
   "char"
   "keyword"
   "punctuator"
   "eof"
end

local record Token
   kind: TokenKind
   lexeme: string
   span: Span
   leading: {Trivia}
   trailing: {Trivia}
   has_newline: boolean
end

local token_mt: metatable<Token> = {
   __index = Token,
}

function Token.new(kind: TokenKind, lexeme: string, span: Span, leading?: {Trivia}, trailing?: {Trivia}, has_newline?: boolean): Token
   return setmetatable({
      kind = kind,
      lexeme = lexeme,
      span = span,
      leading = leading or {},
      trailing = trailing or {},
      has_newline = has_newline or false,
   }, token_mt)
end

return {
   Token = Token,
   TokenKind = TokenKind,
   Trivia = Trivia,
   TriviaKind = TriviaKind,
}
