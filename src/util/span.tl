local ffi = require("ffi")

ffi.cdef [[
struct TLSpan {
    int file_id;
    int start_offset, end_offset;
    int line, column;
};
]]
local TLSpanType = ffi.typeof("struct TLSpan") as function(...: any): Span

local record Span is ffi.CData where ffi.istype("struct TLSpan", self)
    file_id: integer           -- interned filename id
    start_offset: integer       -- byte offset start (inclusive)
    end_offset: integer         -- byte offset end (exclusive)
    line: integer               -- 1-based line
    column: integer             -- 1-based column
    
    metamethod __tostring: function(Span): string
end

function Span.new(file_id: integer, start_offset: integer, end_offset: integer, line: integer, column: integer): Span
    return TLSpanType(file_id, start_offset, end_offset, line, column)
end

function Span:merge(other: Span): Span
    if self.file_id ~= other.file_id then
        return self
    end

    return Span.new (
        self.file_id,
        math.min(self.start_offset, other.start_offset),
        math.max(self.end_offset, other.end_offset),
        self.line,
        self.column
    )
end

ffi.metatype("struct TLSpan", {
    __index = Span,
    __tostring = function(self: Span): string
        local width = self.end_offset - self.start_offset
        return string.format("%d:%d:%d (+%d)", self.file_id, self.line, self.column, width)
    end,
    __new = function(ct: ffi.CType, file_id: integer, start_offset: integer, end_offset: integer, line: integer, column: integer): Span
        return ffi.new(ct, file_id, start_offset, end_offset, line, column)
    end,
})

return Span
