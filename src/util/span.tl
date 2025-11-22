local record Span
   file_id: integer           -- interned filename id
   start_offset: integer       -- byte offset start (inclusive)
   end_offset: integer         -- byte offset end (exclusive)
   line: integer               -- 1-based line
   column: integer             -- 1-based column

   metamethod __tostring: function(Span): string
end

local span_mt: metatable<Span> = {
   __index = Span,
   __tostring = function(self: Span): string
      local width = self.end_offset - self.start_offset
      return string.format("%d:%d:%d (+%d)", self.file_id, self.line, self.column, width)
   end,
}

function Span.new(file_id: integer, start_offset: integer, end_offset: integer, line: integer, column: integer): Span
   return setmetatable({
      file_id = file_id,
      start_offset = start_offset,
      end_offset = end_offset,
      line = line,
      column = column,
   }, span_mt)
end

function Span:merge(other: Span): Span
   if self.file_id ~= other.file_id then
      return self
   end

   return Span.new(
      self.file_id,
      math.min(self.start_offset, other.start_offset),
      math.max(self.end_offset, other.end_offset),
      self.line,
      self.column
   )
end

return Span
