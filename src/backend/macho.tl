local record Section
   name: string
   data: string
end

local record ObjectFile
   path: string | nil
   sections: {Section}
end

local function new_object(): ObjectFile
   return { path = nil, sections = {} }
end

local function add_section(obj: ObjectFile, name: string, data: string)
   table.insert(obj.sections, { name = name, data = data })
end

local function write_object(obj: ObjectFile, path: string): boolean
   local fh = io.open(path, "wb")
   if not fh then
      return false
   end
   -- TODO: real Mach-O encoding.
   for _, sec in ipairs(obj.sections) do
      fh:write(string.format(";; section %s\n", sec.name))
      fh:write(sec.data)
      fh:write("\n")
   end
   fh:close()
   obj.path = path
   return true
end

return {
   Section = Section,
   ObjectFile = ObjectFile,
   new_object = new_object,
   add_section = add_section,
   write_object = write_object,
}
