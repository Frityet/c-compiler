local Span = require("util.span")
local Diagnostic = require("diag.diagnostics")

local record FileContext
   path: string | nil
   source: string | nil
   lines: {string} | nil
end

local record Reporter
   diagnostics: {Diagnostic}
   files: {integer: FileContext}
end

local reporter_mt: metatable<Reporter> = {
   __index = Reporter,
}

local no_color = os.getenv("NO_COLOR")
local use_color = no_color is nil

local function colorize(text: string, code: string): string
   if not use_color then
      return text
   end
   return string.format("\27[%sm%s\27[0m", code, text)
end

local function split_lines(src: string): {string}
   local lines: {string} = {}
   if #src == 0 then
      table.insert(lines, "")
      return lines
   end

   local start = 1
   while start <= #src do
      local nl = src:find("\n", start, true)
      if nl then
         table.insert(lines, string.sub(src, start, nl - 1))
         start = nl + 1
         if start > #src then
            table.insert(lines, "")
         end
      else
         table.insert(lines, string.sub(src, start))
         break
      end
   end
   return lines
end

local function format_traceback(tb: string | nil): {string}
   local out: {string} = {}
   if tb is nil then
      return out
   end
   if tb == "" then
      return out
   end
   local cleaned: string = tb
   cleaned = cleaned:gsub("^stack traceback:\n?", "")
   for line in cleaned:gmatch("[^\n]+") do
      local text: string = line as string
      if text == "stack traceback:" then
         goto continue
      end
      if text ~= "" then
         local trimmed = text:gsub("^%s*", "")
         table.insert(out, trimmed)
      end
      ::continue::
   end
   local max_frames = 6
   if #out > max_frames then
      local limited: {string} = {}
      for i = 1, max_frames do
         table.insert(limited, out[i])
      end
      table.insert(limited, string.format("... %d more frame(s)", #out - max_frames))
      return limited
   end
   return out
end

local function format_heading(diag: Diagnostic): string
   local sev = diag.severity
   local label = string.format("%s[%s]: %s", string.upper(sev), diag.code, diag.message)
   if sev == "error" then
      return colorize(label, "31")
   elseif sev == "warning" then
      return colorize(label, "33")
   else
      return colorize(label, "36")
   end
end

local function display_path(id: integer, ctx: FileContext | nil): string
   if not ctx is nil and ctx.path then
      return ctx.path
   end
   return string.format("<file %d>", id)
end

local function slice_line(span: Span, line_text: string): (string, string)
   local line_len = math.max(1, #line_text)
   local col = math.max(1, math.min(span.column, line_len))
   local width = math.max(1, span.end_offset - span.start_offset)
   if width > (line_len - col + 1) then
      width = line_len - col + 1
   end
   local max_len = 160
   local start_col = 1
   if line_len > max_len then
      local half = math.floor(max_len / 2)
      start_col = math.max(1, col - half)
      local max_start = line_len - max_len + 1
      if start_col > max_start then
         start_col = max_start
      end
   end
   local end_col = math.min(line_len, start_col + max_len - 1)
   local prefix = start_col > 1
   local suffix = end_col < line_len
   local snippet = string.sub(line_text, start_col, end_col)
   if prefix then
     snippet = "..." .. snippet
   end
   if suffix then
     snippet = snippet .. "..."
   end

   local caret_start = col - start_col + 1 + (prefix and 3 or 0)
   if caret_start < 1 then
      caret_start = 1
   end
   local caret_width = math.min(width, math.max(1, #snippet - caret_start + 1))
   local caret = string.rep(" ", math.max(0, caret_start - 1)) .. string.rep("^", caret_width)
   return snippet, caret
end

function Reporter.new(): Reporter
   return setmetatable({ diagnostics = {}, files = {} }, reporter_mt)
end

function Reporter:track_file(file_id: integer, path?: string, source?: string)
   local ctx = self.files[file_id] or { path = nil, source = nil, lines = nil }
   if path is string then
      ctx.path = path
   end
   if source is string then
      ctx.source = source
      ctx.lines = split_lines(source)
   end
   self.files[file_id] = ctx
end

function Reporter:get_file(file_id: integer): FileContext | nil
   return self.files[file_id]
end

function Reporter:report(diag: Diagnostic)
   local tb = diag.traceback
   if tb is nil then
      tb = debug.traceback("", 3)
      diag.traceback = tb
   end
   table.insert(self.diagnostics, diag)
end

function Reporter:has_errors(): boolean
   for _, d in ipairs(self.diagnostics) do
      if d.severity == "error" then
         return true
      end
   end
   return false
end

function Reporter:format(diag: Diagnostic): string
   local lines: {string} = {}
   local span = diag.span
   local ctx = self.files[span.file_id]
   local path = display_path(span.file_id, ctx)

   table.insert(lines, format_heading(diag))

   local width = math.max(0, span.end_offset - span.start_offset)
   local location = string.format("%s:%d:%d (file %d, bytes %d-%d, width %d)",
      path, span.line, span.column, span.file_id, span.start_offset, span.end_offset, math.max(width, 1))
   table.insert(lines, "  --> " .. location)

   local line_text: string | nil = nil
   if ctx and ctx.lines then
      local file_lines = ctx.lines as {string}
      line_text = file_lines[span.line]
   end
   if line_text then
      table.insert(lines, "   |")
      local snippet, caret = slice_line(span, line_text)
      table.insert(lines, string.format("%4d | %s", span.line, snippet))
      table.insert(lines, string.format("   | %s", caret))
   end

   if #diag.notes > 0 then
      table.insert(lines, "  notes:")
      for _, n in ipairs(diag.notes) do
         table.insert(lines, "    - " .. n)
      end
   end

   local tb_lines = format_traceback(diag.traceback)
   if #tb_lines > 0 then
      table.insert(lines, "  stack:")
      for _, l in ipairs(tb_lines) do
         table.insert(lines, "    " .. l)
      end
   end

   return table.concat(lines, "\n")
end

function Reporter:print_all(max_errors?: integer)
   local counts = { error = 0, warning = 0, note = 0 }
   local limit = max_errors
   if limit is nil or limit <= 0 then
      limit = #self.diagnostics
   end

   for idx, d in ipairs(self.diagnostics) do
      counts[d.severity] = (counts[d.severity] or 0) + 1
      if idx <= limit then
         io.stdout:write(self:format(d) .. "\n")
      end
   end

   if limit < #self.diagnostics then
      io.stdout:write(string.format("... omitted %d diagnostic(s)\n", #self.diagnostics - limit))
   end

   io.stdout:write(string.format("summary: %d error(s), %d warning(s), %d note(s)\n",
      counts.error, counts.warning, counts.note))
end

return Reporter
