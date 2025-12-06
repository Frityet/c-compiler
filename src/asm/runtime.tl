local ffi = require("ffi")
local Result = require("util.result")
local LibLoader = require("util.lib_loader")
local LUA_VERSION<const> = "5.1"
local type CData = ffi.CData
local record VoidPtr
   is CData
end
local record SizeArray
   is {integer}, CData
end

local type BytePtr = ffi.Pointer<VoidPtr>
local type VoidPtrArray = ffi.Pointer<VoidPtr>

if not table.unpack then rawset(table, "unpack", (_G as {string:any}).unpack) end
local unpack = table.unpack


local record AssembleOptions
   entry: string | nil
   externs: {string: CData} | nil
end

local record DynasmArtifacts
   actionlist: {integer}
   maxsection: integer
   dasm_calls: {{integer}}
   pc_labels: {string: integer}
   globals: {string}
   externs: {string}
end

local record Assembled
   size: integer
   buffer: CData
   globals: {string: integer}
   globals_ptr: {string: CData}
   entry: string
   pc_labels: {string: integer}
   freed: boolean
   cast: function(self: Assembled, ctype: string): CData
   symbol: function(self: Assembled, name: string): CData | nil
   close: function(self: Assembled): nil
end

local record DynasmLib
   dasm_init: function(state: CData, maxsection: integer): nil
   dasm_free: function(state: CData): nil
   dasm_setupglobal: function(state: CData, globals: CData, maxgl: integer): nil
   dasm_growpc: function(state: CData, maxpc: integer): nil
   dasm_setup: function(state: CData, actionlist: CData): nil
   dasm_put: function(state: CData, start: integer, ...: integer): nil
   dasm_link: function(state: CData, size_out: CData): integer
   dasm_encode: function(state: CData, buffer: CData): integer
   dasm_getpclabel: function(state: CData, pc: integer): integer
   dasm_wrap_set_externs: function(ext: CData, count: integer): nil
end

local record PosixAPI
   mmap: function(addr: CData, length: integer, prot: integer, flags: integer, fd: integer, offset: integer): CData
   munmap: function(addr: CData, length: integer): integer
   getpagesize: function(): integer
end

local record WinAPI
   VirtualAlloc: function(addr: CData, size: integer, allocType: integer, prot: integer): CData
   VirtualFree: function(addr: CData, size: integer, freeType: integer): integer
end

local function trim(s: string): string
   return (s:gsub("^%s*", ""):gsub("%s*$", ""))
end

local function path_exists(p: string): boolean
   local fh = io.open(p, "rb")
   if not fh then
      return false
   end
   fh:close()
   return true
end

local function dirname(p: string): string
   local dir = p:match("^(.*)/[^/]+$")
   if dir then
      return dir
   end
   return "."
end

local function find_root_from_module(): string
   local info = debug.getinfo(1, "S")
   local src = info and info.source
   if src and src:sub(1, 1) == "@" then
      local base = dirname(src:sub(2))
      local current = base
      for _ = 1, 8 do
         local candidate = current .. "/extern/LuaJIT/dynasm/dynasm.lua"
         if path_exists(candidate) then
            return current
         end
         local parent = dirname(current)
         if parent == current then
            break
         end
         current = parent
      end
   end
   return "."
end

local PROJECT_ROOT = find_root_from_module()

local function dynasm_path(): string
   local candidate = PROJECT_ROOT .. "/extern/LuaJIT/dynasm/dynasm.lua"
   if path_exists(candidate) then
      return candidate
   end
   error("dynasm.lua not found relative to " .. PROJECT_ROOT)
end

local function load_dynasm_lib(): DynasmLib
   ffi.cdef([[
      typedef struct dasm_State dasm_State;
      void dasm_init(dasm_State **Dst, int maxsection);
      void dasm_free(dasm_State **Dst);
      void dasm_setupglobal(dasm_State **Dst, void **gl, unsigned int maxgl);
      void dasm_growpc(dasm_State **Dst, unsigned int maxpc);
      void dasm_setup(dasm_State **Dst, const void *actionlist);
      void dasm_put(dasm_State **Dst, int start, ...);
      int dasm_link(dasm_State **Dst, size_t *szp);
      int dasm_encode(dasm_State **Dst, void *buffer);
      int dasm_getpclabel(dasm_State **Dst, unsigned int pc);
      void dasm_wrap_set_externs(const void *const *ext, size_t count);
   ]])

   local load_result = LibLoader.load_shared({
      name = "dynasm-runtime",
      roots = { PROJECT_ROOT },
      lua_version = LUA_VERSION,
   })
   return load_result.lib as DynasmLib
end

local dynasm_lib: DynasmLib = load_dynasm_lib()

local POSIX = ffi.os ~= "Windows"
if POSIX then
   ffi.cdef([[
      void *mmap(void *addr, size_t length, int prot, int flags, int fd, long offset);
      int munmap(void *addr, size_t length);
      int getpagesize(void);
   ]])
else
   ffi.cdef([[
      void *VirtualAlloc(void *addr, size_t size, unsigned long allocType, unsigned long prot);
      int VirtualFree(void *addr, size_t size, unsigned long freeType);
   ]])
end

local cposix: PosixAPI | nil = nil
local cwin: WinAPI | nil = nil
if POSIX then
   cposix = ffi.C as PosixAPI
else
   cwin = ffi.C as WinAPI
end

local PROT_READ = 1
local PROT_WRITE = 2
local PROT_EXEC = 4
local MAP_PRIVATE = 2
local MAP_ANON = 32
local MEM_COMMIT = 0x1000
local MEM_RESERVE = 0x2000
local MEM_RELEASE = 0x8000
local PAGE_EXECUTE_READWRITE = 0x40

local function page_size(): integer
   if POSIX then
      local api = cposix as PosixAPI
      local size = api.getpagesize()
      return math.floor(size)
   end
   return 4096
end

local function round_up(size: integer, align: integer): integer
   local rem = size % align
   if rem == 0 then
      return size
   end
   return size + (align - rem)
end

local function alloc_exec(size: integer): CData
   local aligned = round_up(size, page_size())
   if POSIX then
      local api = cposix as PosixAPI
      local buf = api.mmap(nil, aligned, PROT_READ + PROT_WRITE + PROT_EXEC, MAP_PRIVATE + MAP_ANON, -1, 0)
      if buf == ffi.cast("void *", -1) then
         error("mmap failed to allocate executable buffer")
      end
      return buf
   end

   local api = cwin as WinAPI
   local buf = api.VirtualAlloc(nil, aligned, MEM_RESERVE + MEM_COMMIT, PAGE_EXECUTE_READWRITE)
   if buf == nil then
      error("VirtualAlloc failed to allocate executable buffer")
   end
   return buf
end

local function free_exec(ptr: CData, size: integer): nil
   local aligned = round_up(size, page_size())
   if POSIX then
      local api = cposix as PosixAPI
      api.munmap(ptr, aligned)
      return
   end
   local api = cwin as WinAPI
   api.VirtualFree(ptr, aligned, MEM_RELEASE)
end

local function normalize_body(body: string): {string}
   local lines: {string} = {}
   for line in body:gmatch("[^\r\n]+") do
      if line:match("%S") then
         local l = line
         if not l:match("^%s*|") then
            l = "|" .. l
         end
         lines[#lines + 1] = l
      end
   end
   return lines
end

local function build_dasc(body: string, entry: string): string
   local lines = {
      "|.arch x64",
      "|.section text",
      "|.actionlist actions",
      "|.globals lbl_",
      "|.globalnames globnames",
      "|.externnames extnames",
   }

   local has_entry = false
   for l in body:gmatch("[^\r\n]+") do
      if l:match("->%s*" .. entry) then
         has_entry = true
         break
      end
   end
   if not has_entry then
      lines[#lines + 1] = "|->" .. entry .. ":"
   end

   local normalized = normalize_body(body)
   for _, l in ipairs(normalized) do
      lines[#lines + 1] = l
   end

   return table.concat(lines, "\n") .. "\n"
end

local record DynasmRun
   ok: boolean
   output: string
end

local function run_dynasm(source: string): DynasmRun
   local tmp = os.tmpname()
   local fh, ferr = io.open(tmp, "wb")
   if not fh then
      return { ok = false, output = "failed to open temp file: " .. tostring(ferr) }
   end
   fh:write(source)
   fh:close()

   local capture = assert(io.tmpfile())
   local saved_stdout = io.stdout
   local saved_exit = os.exit
   local saved_arg = _G.arg

   local dyn_path = dynasm_path()

   -- Ensure DynASM arch module is reloaded to avoid stale section state.
   local saved_x64 = package.loaded["dasm_x64"]
   local saved_x86 = package.loaded["dasm_x86"]
   package.loaded["dasm_x64"] = nil
   package.loaded["dasm_x86"] = nil

   io.stdout = capture
   os.exit = function(code?: integer)
      error("__dynasm_exit__:" .. tostring(code or 0), 0)
   end
   local args = { "-o", "-", tmp }
   _G.arg = { [0] = dyn_path, [1] = "-o", [2] = "-", [3] = tmp }

   local chunk, load_err = loadfile(dyn_path)
   if not chunk then
      io.stdout = saved_stdout
      os.exit = saved_exit
      _G.arg = saved_arg
      capture:close()
      os.remove(tmp)
      return { ok = false, output = "failed to load dynasm: " .. tostring(load_err) }
   end

   local ok, err = pcall(chunk, args[1], args[2], args[3])

   io.stdout = saved_stdout
   os.exit = saved_exit
   _G.arg = saved_arg
   package.loaded["dasm_x64"] = saved_x64
   package.loaded["dasm_x86"] = saved_x86
   capture:seek("set")
   local output = capture:read("*a") or ""
   capture:close()
   os.remove(tmp)

   if not ok then
      local msg = tostring(err)
      local exit_code = msg:match("^__dynasm_exit__:(%-?%d+)$")
      if exit_code then
         if tonumber(exit_code) == 0 then
            return { ok = true, output = output }
         end
         return { ok = false, output = "dynasm exited with code " .. exit_code }
      end
      return { ok = false, output = msg }
   end

   return { ok = true, output = output }
end

local function parse_actionlist(out: string): Result.Result<{integer}, string>
   local block = out:match("static const unsigned char [%w_]+%[[^%]]+%]%s*=%s*{(.-)};")
   if not block then
      return Result.err("missing actionlist in dynasm output")
   end
   local bytes: {integer} = {}
   for num in block:gmatch("(%-?%d+)") do
      local value = tonumber(num) or 0
      bytes[#bytes + 1] = math.floor(value)
   end
   return Result.ok(bytes)
end

local function parse_names(out: string, name: string): {string}
   local pat = "static const char %*const%s+" .. name .. "%[%]%s*=%s*{(.-)};"
   local block = out:match(pat)
   local names: {string} = {}
   if not block then
      return names
   end
   for entry in block:gmatch("\"([^\"]+)\"") do
      names[#names + 1] = entry
   end
   return names
end

local record ParsedCalls
   calls: {{integer}}
   pc_labels: {string: integer}
end

local function parse_calls(out: string): Result.Result<ParsedCalls, string>
   local calls: {{integer}} = {}
   local pcmap: {string: integer} = {}
   local pcnames: {string} = {}
   local function pcindex(label: string): integer
      local existing = pcmap[label]
      if existing ~= nil then
         return existing
      end
      local idx = #pcnames
      pcmap[label] = idx
      pcnames[#pcnames + 1] = label
      return idx
   end

   for line in out:gmatch("dasm_put%([^;]+%);") do
      local args_str = line:match("dasm_put%(%s*Dst%s*,%s*([^)]+)%)")
      if not args_str then
         return Result.err("failed to parse dasm_put line: " .. line)
      end
      local args: {integer} = {}
      for token in args_str:gmatch("([^,]+)") do
         local t = trim(token)
         local num = tonumber(t)
         if num then
            args[#args + 1] = math.floor(num)
         else
            if not t:match("^[%a_][%w_]*$") then
               return Result.err("unsupported dasm_put argument: " .. t)
            end
            args[#args + 1] = pcindex(t)
         end
      end
      calls[#calls + 1] = args
   end
   return Result.ok({ calls = calls, pc_labels = pcmap })
end

local function parse_output(out: string): Result.Result<DynasmArtifacts, string>
   local action_res = parse_actionlist(out)
   if action_res is Result.Err<{integer}, string> then
      return Result.err(action_res.err)
   end
   local maxsec_num = tonumber(out:match("#define%s+DASM_MAXSECTION%s+(%d+)")) or 1
   local maxsec = math.floor(maxsec_num)
   local calls_res = parse_calls(out)
    if calls_res is Result.Err<ParsedCalls, string> then
      return Result.err(calls_res.err)
   end
   local globals = parse_names(out, "globnames")
   local externs = parse_names(out, "extnames")

   return Result.ok({
      actionlist = action_res.value,
      maxsection = maxsec,
      dasm_calls = calls_res.value.calls,
      pc_labels = calls_res.value.pc_labels,
      globals = globals,
      externs = externs,
   })
end

local function count_pc_labels(map: {string: integer}): integer
   local max = -1
   for _, idx in pairs(map) do
      if idx > max then
         max = idx
      end
   end
   return max + 1
end

local function build_artifacts(body: string, entry: string): Result.Result<DynasmArtifacts, string>
   local source = build_dasc(body, entry)
   local run_res = run_dynasm(source)
   if not run_res.ok then
      return Result.err(run_res.output)
   end
   return parse_output(run_res.output)
end

local function to_cbuffer(bytes: {integer}): CData
   local buf = ffi.new("unsigned char[?]", #bytes)
   if #bytes > 0 then
      local chars: {string} = {}
      for i, b in ipairs(bytes) do
         chars[i] = string.char(b)
      end
      local raw = table.concat(chars)
      ffi.copy(buf, raw, #bytes)
   end
   return buf as CData
end

local function ensure_externs(names: {string}, provided: {string: CData} | nil): CData | nil
   if #names == 0 then
      return nil
   end
   if not provided then
      error("extern symbols required but no addresses provided")
   end
   local addresses = provided as {string: CData}
   local ext = ffi.new("const void *[?]", #names)
   local extptr = ffi.cast("const void **", ext) as BytePtr
   for idx, name in ipairs(names) do
      local addr = addresses[name]
      if not addr then
         error("missing extern address for " .. name)
      end
      extptr[idx - 1] = ffi.cast("const void *", addr)
   end
   return ext
end

local function assemble(body: string, options: AssembleOptions | nil): Assembled
   local entry = "entry"
   local extern_table: {string: CData} | nil = nil
   local opts = options
   if opts ~= nil then
      local concrete = opts as AssembleOptions
      if concrete.entry then
         entry = concrete.entry
      end
      extern_table = concrete.externs
   end
   local artifacts_res = build_artifacts(body, entry)
   local artifacts = Result.expect(artifacts_res, "failed to run dynasm")
   local actionbuf = to_cbuffer(artifacts.actionlist)

   local state = ffi.new("dasm_State*[1]")
   dynasm_lib.dasm_init(state, artifacts.maxsection)

   local globals: {string: integer} = {}
   for idx, name in ipairs(artifacts.globals) do
      globals[name] = idx - 1
   end
   local glbuf = ffi.new("void *[?]", math.max(#artifacts.globals, 1)) as VoidPtrArray
   dynasm_lib.dasm_setupglobal(state, glbuf, #artifacts.globals)

   local pc_needed = count_pc_labels(artifacts.pc_labels)
   if pc_needed > 0 then
      dynasm_lib.dasm_growpc(state, pc_needed)
   end

   dynasm_lib.dasm_setup(state, actionbuf)

   for _, args in ipairs(artifacts.dasm_calls) do
      dynasm_lib.dasm_put(state, unpack(args))
   end

   local size_out = ffi.new("size_t[1]") as SizeArray
   local link_status = dynasm_lib.dasm_link(state, size_out)
   if link_status ~= 0 then
      dynasm_lib.dasm_free(state)
      error("dasm_link failed with status " .. tostring(link_status))
   end

   local size_num = math.floor(tonumber(size_out[0]))
   local buffer = alloc_exec(size_num)

   local extern_ptrs = ensure_externs(artifacts.externs, extern_table)
   if extern_ptrs then
      dynasm_lib.dasm_wrap_set_externs(extern_ptrs, #artifacts.externs)
   else
      dynasm_lib.dasm_wrap_set_externs(nil, 0)
   end

   local encode_status = dynasm_lib.dasm_encode(state, buffer)
   dynasm_lib.dasm_free(state)
   if encode_status ~= 0 then
      free_exec(buffer, size_num)
      error("dasm_encode failed with status " .. tostring(encode_status))
   end

   local global_ptrs: {string: CData} = {}
   for name, idx in pairs(globals) do
      global_ptrs[name] = glbuf[idx]
   end

   local entry_idx = globals[entry]
   if entry_idx is nil then
      free_exec(buffer, size_num)
      error("entry label '" .. entry .. "' not found in globals")
   end

   local asm_obj: Assembled = {
      size = size_num,
      buffer = buffer,
      globals = globals,
      globals_ptr = global_ptrs,
      entry = entry,
      pc_labels = artifacts.pc_labels,
      freed = false,
      cast = function(self: Assembled, ctype: string): CData
         local ptr = self:symbol(self.entry)
         if not ptr then
            error("entry label missing")
         end
         return ffi.cast(ctype, ptr)
      end,
      symbol = function(self: Assembled, name: string): CData | nil
         if self.freed then
            return nil
         end
         return self.globals_ptr[name]
      end,
      close = function(self: Assembled): nil
         if self.freed then
            return
         end
         self.freed = true
         free_exec(self.buffer, self.size)
      end,
   }

   return asm_obj
end

return {
   assemble = assemble,
}
