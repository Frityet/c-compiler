local Result = require("util.result")
local Reporter = require("diag.reporter")
local pipeline = require("driver.pipeline")
local AutogenFFI = require("tooling.autogen_ffi")
local type FrontendOutput = pipeline.FrontendOutput

local record Options
   inputs: {string}
   output: string | nil
   emit_phase: string
   dump_tokens: boolean
   dump_ast: boolean
   max_errors: integer | nil
   strip_prefix: string | nil
   load_library: string | nil
end

local function usage(): string
   return table.concat({
      "cc [options] file.c ...",
      "cc ffi-gen [options] header.h ...",
      "  -c              Compile only, emit object (not yet implemented)",
      "  -E              Preprocess only (not yet implemented)",
      "  -S              Emit assembly (not yet implemented)",
      "  -o <file>       Output file",
      "  --dump-tokens   Dump tokens after preprocessing",
      "  --dump-ast      Dump parsed AST (summary)",
      "  --max-errors <n>  Limit number of diagnostics printed",
      "ffi-gen options:",
      "  -o <file>       Output .tl file name (default: <first header>.ffi.tl)",
      "  --lib <name>    Pass to ffi.load; default uses ffi.C",
      "  --no-system-includes  Exclude declarations originating in system headers from output",
      "  --max-errors <n>  Limit number of diagnostics printed",
      "  --load-library <name>  Pass name to ffi.load in generated module",
      "  --strip-prefix <p>     Strip C prefix 'p' for ergonomic lua functions",
   }, "\n") .. "\n"
end

local type ParseResult = Result.Ok<Options, string> | Result.Err<Options, string>
local type FFIParseResult = Result.Ok<AutogenFFI.GenerateOptions, string> | Result.Err<AutogenFFI.GenerateOptions, string>

local function parse_args(argv: {string}): ParseResult
   local opts: Options = {
      inputs = {},
      output = nil,
      emit_phase = "link",
      dump_tokens = false,
      dump_ast = false,
      max_errors = nil,
      strip_prefix = nil,
      load_library = nil,
   }

   local i = 1
   while i <= #argv do
      local argi = argv[i]
      if argi == "-h" or argi == "--help" then
         return Result.err("help")
      elseif argi == "-c" then
         opts.emit_phase = "object"
      elseif argi == "-E" then
         opts.emit_phase = "pp"
      elseif argi == "-S" then
         opts.emit_phase = "asm"
      elseif argi == "--dump-tokens" then
         opts.dump_tokens = true
      elseif argi == "--dump-ast" then
         opts.dump_ast = true
      elseif argi == "--max-errors" then
         if i + 1 > #argv then
            return Result.err("missing count following --max-errors")
         end
         local n = tonumber(argv[i + 1])
         if n is nil then
            return Result.err("invalid number for --max-errors")
         end
         opts.max_errors = math.floor(n)
         i = i + 1
      elseif argi == "--load-library" then
         if i + 1 > #argv then
            return Result.err("missing name following --load-library")
         end
         opts.load_library = argv[i + 1]
         i = i + 1
      elseif argi == "--strip-prefix" then
         if i + 1 > #argv then
            return Result.err("missing prefix following --strip-prefix")
         end
         opts.strip_prefix = argv[i + 1]
         i = i + 1
      elseif argi == "--load-library" then
         if i + 1 > #argv then
            return Result.err("missing name following --load-library")
         end
         opts.load_library = argv[i + 1]
         i = i + 1
      elseif argi == "--strip-prefix" then
         if i + 1 > #argv then
            return Result.err("missing prefix following --strip-prefix")
         end
         opts.strip_prefix = argv[i + 1]
         i = i + 1
      elseif argi == "-o" then
         if i + 1 > #argv then
            return Result.err("missing output following -o")
         end
         opts.output = argv[i + 1]
         i = i + 1
      elseif string.sub(argi, 1, 1) == "-" then
         return Result.err("unknown option: " .. argi)
      else
         table.insert(opts.inputs, argi)
      end
      i = i + 1
   end

   if #opts.inputs == 0 then
      return Result.err("no input files")
   end

   return Result.ok(opts)
end

local function parse_ffi_args(argv: {string}): FFIParseResult
   local opts: AutogenFFI.GenerateOptions = {
      headers = {},
      output = nil,
      lib_name = nil,
      ignore_system_includes = false,
      max_errors = nil,
      strip_prefix = nil,
      load_library = nil,
   }

   local i = 1
   while i <= #argv do
      local argi = argv[i]
      if argi == "-h" or argi == "--help" then
         return Result.err("help")
      elseif argi == "-o" then
         if i + 1 > #argv then
            return Result.err("missing output following -o")
         end
         opts.output = argv[i + 1]
         i = i + 1
      elseif argi == "--lib" then
         if i + 1 > #argv then
            return Result.err("missing library name following --lib")
         end
         opts.lib_name = argv[i + 1]
         i = i + 1
      elseif argi == "--no-system-includes" then
         opts.ignore_system_includes = true
      elseif argi == "--max-errors" then
         if i + 1 > #argv then
            return Result.err("missing count following --max-errors")
         end
         local n = tonumber(argv[i + 1])
         if n is nil then
            return Result.err("invalid number for --max-errors")
         end
         opts.max_errors = math.floor(n)
         i = i + 1
      elseif argi == "--load-library" then
         if i + 1 > #argv then
            return Result.err("missing name following --load-library")
         end
         opts.load_library = argv[i + 1]
         i = i + 1
      elseif argi == "--strip-prefix" then
         if i + 1 > #argv then
            return Result.err("missing prefix following --strip-prefix")
         end
         opts.strip_prefix = argv[i + 1]
         i = i + 1
      elseif string.sub(argi, 1, 1) == "-" then
         return Result.err("unknown option: " .. argi)
      else
         table.insert(opts.headers, argi)
      end
      i = i + 1
   end

   if #opts.headers == 0 then
      return Result.err("no header files")
   end

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
            print(usage())
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
         rep:print_all(ffi_opts.max_errors)
         return
      end
      print(string.format("cc ffi-gen: wrote %s", ffi_opts.output or "<auto>"))
      return
   end

   local parsed = parse_args(argv)
   if parsed is Result.Err<Options, string> then
      if parsed.err == "help" then
         print(usage())
         return
      end
      return error(parsed.err)
   end

   local opts = parsed.value
   local rep = Reporter.new()
   local p_opts = { dump_tokens = opts.dump_tokens, dump_ast = opts.dump_ast }
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
      rep:print_all(opts.max_errors)
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
