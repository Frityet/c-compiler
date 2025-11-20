local regalloc = require("backend.regalloc")
local macho = require("backend.macho")

local function emit_text(fn: regalloc.AllocatedFunction): string
   local lines: {string} = {}
   table.insert(lines, string.format("; function %s", fn.name))
   for _, line in ipairs(fn.body) do
      table.insert(lines, line)
   end
   return table.concat(lines, "\n")
end

local function compile_function(fn: regalloc.AllocatedFunction): macho.ObjectFile
   -- TODO: real instruction encoding + relocations.
   local obj = macho.new_object()
   macho.add_section(obj, "__TEXT,__text", emit_text(fn))
   return obj
end

return {
   compile_function = compile_function,
}
