local record Interner
   next_id: integer
   ids: {string}
   reverse: {string: integer}

   metamethod __len: function(Interner): integer
end

local interner_mt: metatable<Interner>
interner_mt = {
   __index = Interner,
   __len = function(self: Interner): integer
      return self.next_id - 1
   end,
}

function Interner.new(): Interner
   return setmetatable({
      next_id = 1,
      ids = {},
      reverse = {},
   }, interner_mt)
end

function Interner:intern(text: string): integer
   local existing = self.reverse[text]
   if existing then
      return existing
   end

   local id = self.next_id
   self.next_id = id + 1
   self.reverse[text] = id
   self.ids[id] = text
   return id
end

function Interner:resolve(id: integer): string
   local value = self.ids[id]
   if not value then
      error("invalid intern id: " .. tostring(id))
   end
   return value
end

return Interner
