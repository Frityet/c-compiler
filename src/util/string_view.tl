local ffi = require("ffi")

ffi.cdef [[
struct TLStringView {
   const uint8_t *ptr;
   uint32_t len;
};

int memcmp(const void *s1, const void *s2, size_t n);
int strlen(const char *s);
]]

local C = ffi.C

local record TLStringView is ffi.CData where ffi.istype("struct TLStringView", self)
   ptr: ffi.CString | nil
   len: integer

   metamethod __tostring: function(self): string
   metamethod __eq: function(self, other: ffi.CString | string | TLStringView): boolean
   metamethod __len: function(self): integer = macroexp(self: self): integer return self.len end
   metamethod __concat: function(self, other: string | TLStringView): string
end

local function to_string(self: TLStringView): string
   return ffi.string(self.ptr, self.len)
end

local function equals(self: TLStringView, other: ffi.CString | string | TLStringView): boolean
   local other_len: integer
   if other is string then
      other_len = #other
   elseif other is TLStringView then
      other_len = other.len
   else
      other_len = (C.strlen as function(ffi.CData): integer)(other)
   end

   if self.len ~= other_len then
      return false
   end
   return (C.memcmp as function(ffi.CData, ffi.CData | string, integer))(self.ptr, other, self.len) == 0
end

ffi.metatype("struct TLStringView", {
   __index = TLStringView,
   __tostring = to_string,
   __eq = equals,
   __concat = function(self: string | TLStringView, other: string | TLStringView): string
      return tostring(self) .. tostring(other)
   end,
})

function TLStringView.new(ptr: ffi.CString | nil, len: integer): TLStringView
   return ffi.new("struct TLStringView", ptr, len)
end

return TLStringView
