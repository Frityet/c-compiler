local Reporter = require("diag.reporter")
local Diagnostic = require("diag.diagnostics")
local Span = require("util.span")
local Preprocessor = require("pp.preprocessor")
local Parser = require("parser.parser")
local Checker = require("sema.checker")
local token_mod = require("lexer.token")
local ast = require("parser.ast")

local type Token = token_mod.Token
local type TranslationUnit = ast.TranslationUnit
local type CheckedTranslationUnit = Checker.CheckedTranslationUnit

local function path_dir(path: string): string
   local dir = path:match("^(.*)/[^/]+$") or "."
   return dir
end

local record PipelineOptions
   dump_tokens: boolean
   dump_ast: boolean
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

local function dump_tokens(tokens: {Token})
   for _, t in ipairs(tokens) do
      io.stdout:write(string.format("%s\t%s\n", t.kind, t.lexeme))
   end
end

local function compile_file(path: string, file_id: integer, opts?: PipelineOptions, reporter?: Reporter): FrontendOutput | nil
   local rep = reporter or Reporter.new()
   local options = opts or { dump_tokens = false, dump_ast = false }
   rep:track_file(file_id, path)
   local src, read_err = read_file(path)
   if not src then
      rep:report(Diagnostic.new("error", "failed to read file: " .. tostring(read_err), Span.new(file_id, 0, 0, 1, 1), "DRV001"))
      return nil
   end
   rep:track_file(file_id, path, src)

   local dir = path_dir(path)
   local pp = Preprocessor.preprocess(src, file_id, rep, {
      search_paths = { dir },
      defines = {},
      undefs = {},
      current_dir = dir,
      source_path = path,
   })
   if options.dump_tokens then
      dump_tokens(pp.tokens)
   end

   local tu = Parser.parse(pp.text, file_id, rep, pp.tokens)
   local checked = Checker.check(tu, rep)
   local out: FrontendOutput = {
      path = path,
      tu = tu,
      tokens = pp.tokens,
      pp_text = pp.text,
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
