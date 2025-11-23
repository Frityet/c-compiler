local argparse = require("argparse")
local Result = require("util.result")
local Reporter = require("diag.reporter")
local Diagnostic = require("diag.diagnostics")
local pipeline = require("driver.pipeline")
local AutogenFFI = require("tooling.autogen_ffi")
local type FrontendOutput = pipeline.FrontendOutput
local type ArgparseArgs = argparse.Args
local type ArgValue = string | {string} | boolean | nil
local type NumberParseResult = Result.Ok<integer | nil, string> | Result.Err<integer | nil, string>

local record Options
   inputs: {string}
   output: string | nil
   emit_phase: string
   dump_tokens: boolean
   dump_ast: boolean
   max_errors: integer | nil
   strip_prefix: string | nil
   load_library: string | nil
   diagnostic_level: Diagnostic.Severity
end

local type ParseResult = Result.Ok<Options, string> | Result.Err<Options, string>
local type FFIParseResult = Result.Ok<AutogenFFI.GenerateOptions, string> | Result.Err<AutogenFFI.GenerateOptions, string>

local function severity_filter(level: Diagnostic.Severity): {Diagnostic.Severity:boolean}
   local filter: {Diagnostic.Severity:boolean} = { error = true }
   if level ~= "error" then
      filter.warning = true
      if level ~= "warning" then
         filter.note = true
      end
   end
   return filter
end

local function as_string(value: ArgValue): string | nil
   if value is string then
      return value
   end
   if value is {string} then
      return value[1]
   end
   return nil
end

local function as_strings(value: ArgValue): {string}
   if value is {string} then
      return value
   end
   if value is string then
      return { value }
   end
   return {}
end

local function as_boolean(value: ArgValue): boolean
   if value is boolean then
      return value
   end
   return false
end

local function parse_max_errors(value: ArgValue, opt_name: string): NumberParseResult
   if value is nil then
      return Result.ok(nil)
   end
   if value is boolean then
      return Result.err(opt_name .. " requires a value")
   end
   local raw = value
   if value is {string} then
      if #value == 0 then
         return Result.err(opt_name .. " requires a value")
      end
      raw = value[1]
   end
   if raw is string then
      local n = tonumber(raw)
      if n is nil then
         return Result.err("invalid number for " .. opt_name)
      end
      return Result.ok(math.floor(n))
   end
   return Result.err("invalid value for " .. opt_name)
end

local function parse_diagnostic_level(value: ArgValue): Diagnostic.Severity
   if value is {string} then
      if #value == 0 then
         return "warning"
      end
      return parse_diagnostic_level(value[1])
   end
   if value is string then
      if value == "note" or value == "warning" or value == "error" then
         return value
      end
   end
   return "warning"
end

local function build_compile_parser(): argparse.Parser
   local parser = argparse("cc", "C compiler")
   parser:add_help(false)
   parser:epilog("Use 'cc ffi-gen --help' to generate LuaJIT FFI bindings.")
   parser:flag("-h --help", "Show this help message and exit."):target("help")

   local emit_object = parser:flag("-c", "Compile only, emit object (not yet implemented)"):target("compile_only")
   local preprocess_only = parser:flag("-E", "Preprocess only (not yet implemented)"):target("preprocess_only")
   local emit_asm = parser:flag("-S", "Emit assembly (not yet implemented)"):target("emit_asm")
   parser:mutex(emit_object, preprocess_only, emit_asm)

   parser:option("-o --output", "Output file"):argname("<file>")
   parser:flag("--dump-tokens", "Dump tokens after preprocessing"):target("dump_tokens")
   parser:flag("--dump-ast", "Dump parsed AST (summary)"):target("dump_ast")
   parser:option("--max-errors", "Limit number of diagnostics printed"):argname("<n>"):target("max_errors")
   parser:option("--diagnostic-level", "Level of diagnostics to print. Default: warning")
      :choices({"note", "warning", "error"})
      :default("warning")
      :target("diagnostic_level")

   parser:argument("inputs", "C source files"):args("*")

   return parser
end

local function build_ffi_parser(): argparse.Parser
   local parser = argparse("cc ffi-gen", "Generate LuaJIT FFI bindings from C headers")
   parser:add_help(false)
   parser:flag("-h --help", "Show this help message and exit."):target("help")

   parser:option("-o --output", "Output .tl file name (default: <first header>.ffi.tl)"):argname("<file>")
   parser:option("--lib", "Pass to ffi.load; default uses ffi.C"):argname("<name>"):target("lib_name")
   parser:flag("--no-system-includes", "Exclude declarations originating in system headers from output"):target("ignore_system_includes")
   parser:option("--max-errors", "Limit number of diagnostics printed"):argname("<n>"):target("max_errors")
   parser:option("--load-library", "Pass name to ffi.load in generated module"):argname("<name>")
      :target("load_library")
   parser:option("--strip-prefix", "Strip C prefix 'p' for ergonomic lua functions"):argname("<p>")
      :target("strip_prefix")
   parser:option("--diagnostic-level", "Level of diagnostics to print. Default: warning")
      :choices({"note", "warning", "error"})
      :default("warning")
      :target("diagnostic_level")

   parser:argument("headers", "Header files"):args("*")

   return parser
end

local function parse_args(argv: {string}): ParseResult
   local parser = build_compile_parser()
   local ok, parsed = parser:pparse(argv)
   if not ok then
      if parsed is string then
         return Result.err(parsed)
      end
      return Result.err("failed to parse arguments")
   end
   if parsed is string then
      return Result.err(parsed)
   end
   local args: ArgparseArgs = parsed

   if as_boolean(args.help) then
      print(parser:get_help())
      return Result.err("help")
   end

   local max_errors_result = parse_max_errors(args.max_errors, "--max-errors")
   if max_errors_result is Result.Err<integer | nil, string> then
      return Result.err(max_errors_result.err)
   end

   local inputs = as_strings(args.inputs)
   if #inputs == 0 then
      return Result.err("no input files")
   end

   local emit_phase = "link"
   if as_boolean(args.preprocess_only) then
      emit_phase = "pp"
   elseif as_boolean(args.emit_asm) then
      emit_phase = "asm"
   elseif as_boolean(args.compile_only) then
      emit_phase = "object"
   end

   local opts: Options = {
      inputs = inputs,
      output = as_string(args.output),
      emit_phase = emit_phase,
      dump_tokens = as_boolean(args.dump_tokens),
      dump_ast = as_boolean(args.dump_ast),
      max_errors = max_errors_result.value,
      strip_prefix = nil,
      load_library = nil,
      diagnostic_level = parse_diagnostic_level(args.diagnostic_level),
   }

   return Result.ok(opts)
end

local function parse_ffi_args(argv: {string}): FFIParseResult
   local parser = build_ffi_parser()
   local ok, parsed = parser:pparse(argv)
   if not ok then
      if parsed is string then
         return Result.err(parsed)
      end
      return Result.err("failed to parse arguments")
   end
   if parsed is string then
      return Result.err(parsed)
   end
   local args: ArgparseArgs = parsed

   if as_boolean(args.help) then
      print(parser:get_help())
      return Result.err("help")
   end

   local max_errors_result = parse_max_errors(args.max_errors, "--max-errors")
   if max_errors_result is Result.Err<integer | nil, string> then
      return Result.err(max_errors_result.err)
   end

   local headers = as_strings(args.headers)
   if #headers == 0 then
      return Result.err("no header files")
   end

   local opts: AutogenFFI.GenerateOptions = {
      headers = headers,
      output = as_string(args.output),
      lib_name = as_string(args.lib_name),
      ignore_system_includes = as_boolean(args.ignore_system_includes),
      max_errors = max_errors_result.value,
      diagnostic_level = parse_diagnostic_level(args.diagnostic_level),
      load_library = as_string(args.load_library),
      strip_prefix = as_string(args.strip_prefix),
   }

   return Result.ok(opts)
end

local function run(argv: {string})
   if #argv > 0 and argv[1] == "ffi-gen" then
      local subargs: {string} = {}
      for i = 2, #argv do
         table.insert(subargs, argv[i])
      end
      local parsed_ffi = parse_ffi_args(subargs)
      if parsed_ffi is Result.Err<AutogenFFI.GenerateOptions, string> then
         if parsed_ffi.err == "help" then
            return
         end
         return error(parsed_ffi.err)
      end
      local ffi_opts = parsed_ffi.value
      local rep = Reporter.new()
      local err = AutogenFFI.run(ffi_opts, rep)
      if err then
         return error(err)
      end
      if rep:has_errors() then
         rep:print_all(ffi_opts.max_errors, severity_filter(ffi_opts.diagnostic_level))
         return
      end
      print(string.format("cc ffi-gen: wrote %s", ffi_opts.output or "<auto>"))
      return
   end

   local parsed = parse_args(argv)
   if parsed is Result.Err<Options, string> then
      if parsed.err == "help" then
         return
      end
      return error(parsed.err)
   end

   local opts = parsed.value
   local rep = Reporter.new()
   local p_opts = { dump_tokens = opts.dump_tokens, dump_ast = opts.dump_ast, want_pp_output = opts.emit_phase == "pp" }
   for idx, path in ipairs(opts.inputs) do
      local out = pipeline.compile_file(path, idx, p_opts, rep)
      if out then
         local o: FrontendOutput = out
         if opts.emit_phase == "pp" then
            io.stdout:write(o.pp_text)
         end
      end
   end
   if rep:has_errors() then
      rep:print_all(opts.max_errors, severity_filter(opts.diagnostic_level))
      return
   end
   print(string.format("cc: processed %d input(s) phase=%s output=%s",
      #opts.inputs, opts.emit_phase, opts.output or "<auto>"))
end

return {
   run = run,
   parse_args = parse_args,
   parse_ffi_args = parse_ffi_args,
   Options = Options,
}
