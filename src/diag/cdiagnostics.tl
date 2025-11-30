local Span = require("util.span")
local ffi = require("ffi")

ffi.cdef [[
struct tl_diagnostic {
    enum severity {
        ERROR,
        WARNING,
        NOTE
    } severity;
     
    const char *message;
    struct TLSpan span;
    const char *code;

    size_t notes_count;
    const char **notes;

    const char *traceback;
};
]]

local record Diagnostic is ffi.CData where ffi.istype(self, "struct Diagnostic")
    ERROR: integer
    WARNING: integer
    NOTE: integer

    severity: integer
    message: ffi.CString
    span: Span
    code: ffi.CString
    notes: ffi.Array<ffi.CString>
    traceback: ffi.CString | nil

    metamethod __tostring: function(Diagnostic): string
end

Diagnostic.ERROR = ffi.C.ERROR as integer
Diagnostic.WARNING = ffi.C.WARNING as integer
Diagnostic.NOTE = ffi.C.NOTE as integer

ffi.metatype("struct tl_diagnostic", {
    __tostring = function(self: Diagnostic): string
        return string.format("%s[%s] %s at %s", 
            (self.severity == Diagnostic.ERROR and "error" or 
             self.severity == Diagnostic.WARNING and "warning" or 
             "note"),
            ffi.string(self.code),
            ffi.string(self.message),
            tostring(self.span))
    end,
    __index = Diagnostic,
})

function Diagnostic:severity_string(): string
   if self.severity == Diagnostic.ERROR then
      return "error"
   elseif self.severity == Diagnostic.WARNING then
      return "warning"
   else
      return "note"
   end
end

function Diagnostic.new(
    severity: integer,
    message: string,
    span: Span,
    code: string,
    notes?: {string},
    traceback?: string
): Diagnostic
    local tb_cstr: ffi.CString | nil = nil
    if traceback ~= nil then
        tb_cstr = ffi.new("const char[?]", #traceback + 1, traceback)
    else
        local tb = debug.traceback("", 3)
        tb_cstr = ffi.new("const char[?]", #tb + 1, tb)
    end

    local notes_array: ffi.Array<ffi.CString>
    local notes_count: integer = 0
    if not notes is nil then
        notes_count = #notes
        notes_array = ffi.new("const char *[?]", notes_count)
        for i = 1, notes_count do
            notes_array[i - 1] = ffi.new("const char[?]", #notes[i] + 1, notes[i])
        end
    else
        notes_array = ffi.new("const char *[1]")
    end

    return ffi.new("struct tl_diagnostic", {
        severity = severity,
        message = ffi.new("const char[?]", #message + 1, message),
        span = span,
        code = ffi.new("const char[?]", #code + 1, code),
        notes_count = notes_count,
        notes = notes_array,
        traceback = tb_cstr,
    })
end

return Diagnostic
