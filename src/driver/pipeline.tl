local Reporter = require("diag.reporter")
local Diagnostic = require("diag.diagnostics")
local Span = require("util.span")
local Preprocessor = require("pp.preprocessor")
local Parser = require("parser.parser")
local Checker = require("sema.checker")
local lexer = require("lexer.lexer")
local ast = require("parser.ast")

local type Token = lexer.Token
local K_PUNCT = lexer.K_PUNCT
local K_IDENTIFIER = lexer.K_IDENTIFIER
local K_EOF = lexer.K_EOF
local type TranslationUnit = ast.TranslationUnit
local type CheckedTranslationUnit = Checker.CheckedTranslationUnit

local function path_dir(path: string): string
   local dir = path:match("^(.*)/[^/]+$") or "."
   return dir
end

local record PipelineOptions
   dump_tokens: boolean
   dump_ast: boolean
   want_pp_output: boolean
end

local record FrontendOutput
   path: string
   tu: TranslationUnit
   tokens: {Token}
   pp_text: string
   checked: CheckedTranslationUnit
end

local function read_file(path: string): string | nil, string | nil
   local fh, err = io.open(path, "r")
   if not fh then
      return nil, err
   end
   local data = fh:read("*a")
   fh:close()
   return data, nil
end

local function dump_tokens(state: lexer.LexerState, next_token: function(): Token)
   while true do
      local t = next_token()
      if not t or t.kind == K_EOF then
         break
      end
      io.stdout:write(string.format("%d\t%s\n", t.kind, lexer.lexeme(t, state.src_ptr)))
   end
end

local function should_insert_space(prev: Token, cur: Token): boolean
   if prev.kind == K_PUNCT or cur.kind == K_PUNCT then
      return prev.kind == K_IDENTIFIER and cur.kind == K_IDENTIFIER
   end
   return true
end

local record WrappedIterator
   iter: function(): Token
   tokens: {Token}
   text: function(): string
end

local function wrap_iterator(state: lexer.LexerState, base: function(): Token, capture_tokens: boolean, build_text: boolean): WrappedIterator
   local tokens: {Token} = {}
   local parts: {string} = {}
   local prev: Token | nil = nil

   local function append_text(tok: Token)
      if not build_text or tok.kind == K_EOF then
         return
      end
      if prev and should_insert_space(prev, tok) then
         parts[#parts + 1] = " "
      end
      parts[#parts + 1] = tostring(lexer.lexeme(tok, state.src_ptr))
   end

   local function iter(): Token
      local t = base()
      if capture_tokens then
         tokens[#tokens + 1] = t
      end
      append_text(t)
      if t.kind ~= K_EOF then
         prev = t
      end
      return t
   end

   local function text(): string
      if not build_text then
         return ""
      end
      return table.concat(parts)
   end

   return {
      iter = iter,
      tokens = tokens,
      text = text,
   }
end

local function compile_file(path: string, file_id: integer, opts?: PipelineOptions, reporter?: Reporter): FrontendOutput | nil
   local rep = reporter or Reporter.new()
   local options = opts or { dump_tokens = false, dump_ast = false, want_pp_output = false }
   rep:track_file(file_id, path)
   local src, read_err = read_file(path)
   if not src then
      rep:report(Diagnostic.new("error", "failed to read file: " .. tostring(read_err), Span.new(file_id, 0, 0, 1, 1), "DRV001"))
      return nil
   end
   rep:track_file(file_id, path, src)

   local dir = path_dir(path)
   local pp = Preprocessor.preprocess(src, file_id, rep --[[, {
      search_paths = { dir },
      defines = {},
      undefs = {},
      current_dir = dir,
      source_path = path,
   }]])

   local lex = pp.lexer
   local mgr = pp.mgr
   if lex is nil or mgr is nil then
      rep:report(Diagnostic.new("error", "preprocessor failed to return lexer state", Span.new(file_id, 0, 0, 1, 1), "DRV002"))
      return nil
   end
   local ptrs = mgr.ptrs

   local need_tokens = options.dump_tokens
   local need_text = options.want_pp_output

   local wrapped = wrap_iterator(lex, pp.next, need_tokens, need_text)
   -- local iter = wrapped.iter

   local tu: TranslationUnit = Parser.parse(lex.src_ptr, pp.next, rep, ptrs, mgr.sources)

   local checked = Checker.check(tu, rep)
   -- if need_tokens then
   --    dump_tokens(pp.lexer, pp.next)
   -- end

   local pp_text = need_text and wrapped.text() or ""
   local tokens_out = need_tokens and wrapped.tokens or {}
   local out: FrontendOutput = {
      path = path,
      tu = tu,
      tokens = tokens_out,
      pp_text = pp_text,
      checked = checked,
   }

   if options.dump_ast then
      -- crude AST printer for now
      local function print_decl(indent: integer, decl: ast.DeclNode)
         local prefix = string.rep("  ", indent)
         io.stdout:write(prefix .. decl.kind .. "\n")
      end
      for _, d in ipairs(tu.decls) do
         print_decl(0, d)
      end
   end

   return out
end

return {
   PipelineOptions = PipelineOptions,
   FrontendOutput = FrontendOutput,
   compile_file = compile_file,
}
