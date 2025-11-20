local function dump_table(tbl: any, indent: integer)
   indent = indent or 0
   local pad = string.rep(" ", indent)
   if type(tbl) ~= "table" then
      print(pad .. tostring(tbl))
      return
   end

   local t = tbl as {any:any}
   for k, v in pairs(t) do
      if type(v) == "table" then
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
