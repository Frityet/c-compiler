local ffi = require("ffi")

local record TargetInfo
   os: string
   arch: string
   is_64bit: boolean
   is_posix: boolean
   is_linux: boolean
   is_macos: boolean
   is_windows: boolean
   is_bsd: boolean
   multiarch: string | nil
end

local CLANG_VERSIONS: {string} = {
   "20", "19", "18", "17", "16", "15", "14", "13", "12", "11", "10",
}

local GCC_VERSIONS: {string} = { "13", "12", "11", "10", "9" }

local function detect(): TargetInfo
   local osname = tostring(ffi.os)
   local arch = tostring(ffi.arch)
   local is_64 = arch == "x64" or arch == "arm64" or arch == "mips64" or arch == "mips64el" or arch == "s390x"
   local multiarch: string | nil = nil
   if osname == "Linux" then
      if arch == "x64" then
         multiarch = "x86_64-linux-gnu"
      elseif arch == "x86" then
         multiarch = "i386-linux-gnu"
      elseif arch == "arm64" then
         multiarch = "aarch64-linux-gnu"
      elseif arch == "arm" then
         multiarch = "arm-linux-gnueabihf"
      end
   end
   local is_linux = osname == "Linux"
   local is_macos = osname == "OSX"
   local is_windows = osname == "Windows"
   local is_bsd = osname == "BSD"
   local is_posix = is_linux or is_macos or is_bsd or osname == "POSIX"
   return {
      os = osname,
      arch = arch,
      is_64bit = is_64,
      is_posix = is_posix,
      is_linux = is_linux,
      is_macos = is_macos,
      is_windows = is_windows,
      is_bsd = is_bsd,
      multiarch = multiarch,
   }
end

local function split_paths(list: string | nil, sep: string): {string}
   if list is nil then
      return {}
   end
   if list == "" then
      return {}
   end
   local value = list
   local pattern = string.format("([^%s]+)", sep)
   local out: {string} = {}
   for entry in value:gmatch(pattern) do
      out[#out + 1] = entry
   end
   return out
end

local function append_versioned(out: {string}, pattern: string, versions: {string})
   for _, v in ipairs(versions) do
      out[#out + 1] = string.format(pattern, v, v)
   end
end

local function default_include_paths(info: TargetInfo): {string}
   local paths: {string} = {}
   local seen: {string:boolean} = {}
   local function add(p: string | nil)
      if p is nil or p == "" then
         return
      end
      if not seen[p] then
         paths[#paths + 1] = p
         seen[p] = true
      end
   end

   for _, envp in ipairs(split_paths(os.getenv("CPATH"), ":")) do
      add(envp)
   end
   for _, envp in ipairs(split_paths(os.getenv("C_INCLUDE_PATH"), ":")) do
      add(envp)
   end
   if info.is_windows then
      for _, envp in ipairs(split_paths(os.getenv("INCLUDE"), ";")) do
         add(envp)
      end
   end

   add("/usr/local/include")
   add("/usr/include")

   if info.is_linux then
      if info.multiarch then
         add("/usr/include/" .. info.multiarch)
         for _, ver in ipairs(GCC_VERSIONS) do
            add(string.format("/usr/lib/gcc/%s/%s/include", info.multiarch, ver))
            add(string.format("/usr/lib/gcc/%s/%s/include-fixed", info.multiarch, ver))
         end
      end
      append_versioned(paths, "/usr/lib/clang/%s/include", CLANG_VERSIONS)
      append_versioned(paths, "/usr/lib/llvm-%s/lib/clang/%s/include", CLANG_VERSIONS)
      append_versioned(paths, "/usr/lib/llvm-%s/lib/clang/%s.0.0/include", CLANG_VERSIONS)
   elseif info.is_macos then
      add("/Library/Developer/CommandLineTools/usr/include")
      add("/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include")
      add("/Library/Developer/CommandLineTools/usr/lib/clang/14.0.3/include")
      add("/Library/Developer/CommandLineTools/usr/lib/clang/14.0.0/include")
      local sdkroot = os.getenv("SDKROOT")
      if sdkroot is string then
         add(sdkroot .. "/usr/include")
         add(sdkroot .. "/usr/lib/clang")
      end
   end

   return paths
end

local function default_defines(info: TargetInfo, include_extensions: boolean): {string:string}
   local defs: {string:string} = {
      __STDC__ = "1",
      __STDC_VERSION__ = "199901L",
      __STDC_HOSTED__ = "1",
   }

   if info.is_posix then
      defs["__unix__"] = "1"
   end
   if info.is_linux then
      defs["__linux__"] = "1"
      defs["__gnu_linux__"] = "1"
      defs["__ELF__"] = "1"
   elseif info.is_macos then
      defs["__APPLE__"] = "1"
      defs["__MACH__"] = "1"
   elseif info.is_windows then
      defs["_WIN32"] = "1"
      if info.is_64bit then
         defs["_WIN64"] = "1"
      end
   end

   if info.is_64bit then
      defs["__LP64__"] = "1"
      defs["_LP64"] = "1"
   end
   if info.arch == "x64" then
      defs["__x86_64__"] = "1"
      defs["__amd64__"] = "1"
   elseif info.arch == "x86" then
      defs["__i386__"] = "1"
   elseif info.arch == "arm64" then
      defs["__aarch64__"] = "1"
   elseif info.arch == "arm" then
      defs["__arm__"] = "1"
   end

    if include_extensions then
      local gnu_major = info.is_macos and "4" or "12"
      local gnu_minor = info.is_macos and "2" or "0"
      local gnu_patch = info.is_macos and "1" or "0"
      defs["__GNUC__"] = gnu_major
      defs["__GNUC_MINOR__"] = gnu_minor
      defs["__GNUC_PATCHLEVEL__"] = gnu_patch
      defs["__GNUG__"] = gnu_major

      local cc = os.getenv("CC")
      local prefers_clang = info.is_macos or (cc is string and cc:match("clang") ~= nil)
      if prefers_clang then
         defs["__clang__"] = "1"
         defs["__clang_major__"] = "14"
         defs["__clang_minor__"] = "0"
         defs["__clang_patchlevel__"] = "3"
         defs["__llvm__"] = "1"
      end
   end

   return defs
end

local function system_prefixes(info: TargetInfo): {string}
   local prefixes: {string} = {}
   for _, p in ipairs(default_include_paths(info)) do
      local pref = p
      if pref:sub(-1) ~= "/" then
         pref = pref .. "/"
      end
      prefixes[#prefixes + 1] = pref
   end
   return prefixes
end

return {
   TargetInfo = TargetInfo,
   detect = detect,
   default_include_paths = default_include_paths,
   default_defines = default_defines,
   system_prefixes = system_prefixes,
}
