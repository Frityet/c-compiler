local ffi = require("ffi")

local LUA_VERSION_FALLBACK<const> = "5.1"

local record LoadOptions
   name: string
   roots: {string}
   lua_version: string | nil
   env_var: string | nil
   extra_dirs: {string} | nil
   allow_plain: boolean | nil
end

local record LoadResult
   lib: ffi.CNamespace
   path: string
   tried: {string}
end

local function platform_lib_names(name: string): {string}
   local ext = ".so"
   if ffi.os == "OSX" then
      ext = ".dylib"
   elseif ffi.os == "Windows" then
      ext = ".dll"
   end
   local prefix = ffi.os == "Windows" and "" or "lib"
   return {
      prefix .. name .. ext,
      name .. ext,
      name,
   }
end

local function default_library_dirs(lua_version: string): {string}
   return {
      "build/lua_modules/lib/lua/" .. lua_version,
      "lua_modules/lib/lua/" .. lua_version,
      "build/lua_modules/lib",
      "lua_modules/lib",
      "build",
   }
end

local function project_root_from_source(source_path: string, lua_version: string): string
   local path = source_path
   if path:sub(1, 1) == "@" then
      path = path:sub(2)
   end
   local escaped_ver = lua_version:gsub("(%p)", "%%%1")
   local patterns = {
      "^(.*)/build/lua_modules/share/lua/" .. escaped_ver .. "/.+$",
      "^(.*)/lua_modules/share/lua/" .. escaped_ver .. "/.+$",
      "^(.*)/src/.+$",
   }
   for _, pat in ipairs(patterns) do
      local root = path:match(pat)
      if root then
         return root
      end
   end
   local dir = path:match("^(.*)/[^/]+$")
   if dir then
      return dir
   end
   return "."
end

local function candidates(opt: LoadOptions): {string}
   local lua_version = opt.lua_version or LUA_VERSION_FALLBACK
   local names = platform_lib_names(opt.name)
   local allow_plain = opt.allow_plain
   local candidate_paths: {string} = {}

   local dirs: {string}
   if opt.extra_dirs then
      dirs = opt.extra_dirs
   else
      dirs = default_library_dirs(lua_version)
   end

   local env_path = opt.env_var and os.getenv(opt.env_var) or nil
   if env_path and env_path ~= "" then
      table.insert(candidate_paths, env_path)
   end

   for _, root in ipairs(opt.roots) do
      for _, dir in ipairs(dirs) do
         local base = root .. "/" .. dir
         for _, n in ipairs(names) do
            table.insert(candidate_paths, base .. "/" .. n)
         end
      end
   end

   if allow_plain ~= false then
      for _, n in ipairs(names) do
         table.insert(candidate_paths, n)
      end
   end

   return candidate_paths
end

local function load_shared(opt: LoadOptions): LoadResult
   local tried: {string} = {}
   for _, path in ipairs(candidates(opt)) do
      local ok, lib = pcall(ffi.load, path)
      if ok then
         return { lib = lib, path = path, tried = tried }
      end
      table.insert(tried, path)
   end
   error("failed to load " .. opt.name .. " (tried: " .. table.concat(tried, ", ") .. ")")
end

return {
   platform_lib_names = platform_lib_names,
   default_library_dirs = default_library_dirs,
   project_root_from_source = project_root_from_source,
   candidates = candidates,
   load_shared = load_shared,
}
