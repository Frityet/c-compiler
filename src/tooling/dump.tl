local function dump_table(tbl: any, indent: integer)
   indent = indent or 0
   local pad = string.rep(" ", indent)
   if not tbl is {any:any} then
      print(pad .. tostring(tbl))
      return
   end

   for k, v in pairs(tbl) do
      if v is table then
         print(string.format("%s%s:", pad, tostring(k)))
         dump_table(v, indent + 2)
      else
         print(string.format("%s%s = %s", pad, tostring(k), tostring(v)))
      end
   end
end

return {
   dump_table = dump_table,
}
