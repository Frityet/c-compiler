add_rules("mode.debug", "mode.release")

rule("teal")
    set_extensions(".tl")
    add_imports("lib.detect.find_tool")
    add_imports("lib.detect.find_program")

    on_buildcmd_file(function (target, batchcmds, sourcefile, opt)
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
        }), "tl compiler not found")
        local lua_modules = path.join(os.projectdir(), "lua_modules", "share", "lua", "5.1")

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
        batchcmds:set_depmtime(os.mtime(tlout))
        batchcmds:set_depcache(target:dependfile(tlout))
    end)


target("c-compiler")
    set_kind("object")
    add_rules("teal")

    add_files("src/**.tl")
