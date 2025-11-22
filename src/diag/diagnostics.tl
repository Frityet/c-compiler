local Span = require("util.span")

local record Diagnostic
   enum Severity
      "error"
      "warning"
      "note"
   end
   severity: Severity
   message: string
   span: Span
   code: string
   notes: {string}
   traceback: string | nil

   metamethod __tostring: function(Diagnostic): string
end

local diag_mt: metatable<Diagnostic>
diag_mt = {
   __index = Diagnostic,
   __tostring = function(self: Diagnostic): string
      return string.format("%s[%s] %s at %s", self.severity, self.code, self.message, tostring(self.span))
   end,
}

function Diagnostic.new(
   severity: Diagnostic.Severity,
   message: string,
   span: Span,
   code: string,
   notes?: {string},
   traceback?: string
): Diagnostic
   local tb = traceback
   if tb is nil then
      tb = debug.traceback("", 3)
   end
   return setmetatable({
      severity = severity,
      message = message,
      span = span,
      code = code,
      notes = notes or {},
      traceback = tb,
   }, diag_mt)
end

return Diagnostic
