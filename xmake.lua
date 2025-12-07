add_rules("mode.debug", "mode.release")

local import_fn = import
local PROJECT_ROOT = os.projectdir()
local LUA_VERSION = "5.1"

local function ensure_absolute(root)
    if not path.is_absolute(root) then
        return path.join(PROJECT_ROOT, root)
    end
    return root
end

local function active_builddir()
    local cfg = import_fn and import_fn("core.project.config") or nil
    if cfg and cfg.builddir then
        return ensure_absolute(cfg.builddir())
    end
    if cfg and cfg.buildir then
        return ensure_absolute(cfg.buildir())
    end
    return ensure_absolute("build")
end

local function teal_output_root(builddir)
    local root = ensure_absolute(builddir or active_builddir())
    return path.join(root, "lua_modules", "share", "lua", LUA_VERSION)
end

local function lua_lib_output_root(builddir)
    local root = ensure_absolute(builddir or active_builddir())
    return path.join(root, "lua_modules", "lib", "lua", LUA_VERSION)
end

local function lua_share_install_root()
    return path.join(PROJECT_ROOT, "lua_modules", "share", "lua", LUA_VERSION)
end

local function lua_lib_install_root()
    return path.join(PROJECT_ROOT, "lua_modules", "lib", "lua", LUA_VERSION)
end

rule("teal")
    set_extensions(".tl")
    add_imports("lib.detect.find_tool")
    add_imports("lib.detect.find_program")
    add_imports("core.project.config")

    local function collect_teal_deps(sourcefile)
        local deps = {}
        local seen = {}
        local src_root = path.join(os.projectdir(), "src")
        local io_mod = import_fn and import_fn("core.base.io") or nil
        local content = io_mod and io_mod.readfile(sourcefile) or nil
        if not content then
            return deps
        end
        local patterns = {
            [=[require%s*%(%s*["']([%w%._/%-]+)["']%s*%)]=],
            [=[require%s*["']([%w%._/%-]+)["']]=]
        }

        for line in content:gmatch("[^\r\n]+") do
            for _, pattern in ipairs(patterns) do
                for module_name in line:gmatch(pattern) do
                    if not seen[module_name] then
                        seen[module_name] = true
                        local mod_path = module_name:gsub("%.", "/")
                        local candidates = {
                            path.join(src_root, mod_path .. ".tl"),
                            path.join(src_root, mod_path .. ".lua")
                        }

                        for _, candidate in ipairs(candidates) do
                            if os.isfile(candidate) then
                                table.insert(deps, candidate)
                                break
                            end
                        end
                    end
                end
            end
        end

        return deps
    end

    on_buildcmd_file(function (target, batchcmds, sourcefile, opt)
        local builddir = active_builddir()
        local extern_dir = path.join(os.projectdir(), "extern", "tl")
        local lua = assert(find_program(path.join(os.projectdir(), "lua"), { check = function(prog) os.run("%s -v", prog) end }), "lua interpreter not found")
        local tl_path = path.join(extern_dir, "tl")
        -- local tl_prelude = string.format([[%s -e 'package.path = "%s/?.lua;%s/?/init.lua;"..package.path' -e 'package.cpath = "%s/?.so;"..package.cpath']], lua, extern_dir, extern_dir, extern_dir)
        local function lua_args(...)
            return {
                "-e",
                string.format('package.path = "%s/?.lua;%s/?/init.lua;"..package.path', extern_dir, extern_dir),
                "-e",
                string.format('package.cpath = "%s/?.so;"..package.cpath', extern_dir),
                ...
            }
        end
        local tl = assert(find_program(tl_path, {
            check = function (prog)
                return os.runv(lua, lua_args(prog, "--version"))
            end
        }), "tl compiler not found (tried "..table.concat({ lua, table.unpack(lua_args(tl_path, "--version")) }, " ")..")")
        local lua_modules = teal_output_root(builddir)

        --todo: make `src` automatically detected
        local tlout = path.join(lua_modules, (path.relative(sourcefile, "src")))
    
        batchcmds:show_progress(opt.progress, "${color.build.object}tl %s", sourcefile)
        batchcmds:mkdir(path.directory(tlout))
        local argv = lua_args(tl, "gen", "-c", sourcefile, "-o", (tlout:gsub("%.tl$", ".lua")))
        local flags = target:values("teal.flags")
        if flags then
            for _, f in ipairs(flags) do
                table.insert(argv, f)
            end
        end

        batchcmds:execv(lua, argv)

        --copy tl files too
        batchcmds:cp(sourcefile, tlout)

        batchcmds:add_depfiles(sourcefile)
        local deps = collect_teal_deps(sourcefile)
        if #deps > 0 then
            batchcmds:add_depfiles(deps)
        end
        batchcmds:set_depmtime(os.mtime(tlout))
        batchcmds:set_depcache(target:dependfile(tlout))
    end)

    on_install(function (target)
        local builddir = active_builddir()
        local build_root = teal_output_root(builddir)
        local install_root = lua_share_install_root()

        if os.isdir(build_root) then
            print("Installing teal files to " .. install_root)
            os.mkdir(install_root)
            os.cp(path.join(build_root, "**"), install_root, {rootdir = build_root})
        end
    end)

target("c-compiler")
    set_kind("object")
    add_rules("teal")
    add_deps("dynasm-runtime")
    add_files("src/**.tl")

target("dynasm-runtime")
    set_kind("shared")
    add_files("src/asm/dasm_wrapper.c")
    add_includedirs("extern/LuaJIT/dynasm", { public = true })
    set_targetdir(lua_lib_output_root())
    on_install(function (target)
        local install_root = lua_lib_install_root()
        os.mkdir(install_root)
        os.cp(target:targetfile(), install_root)
    end)
