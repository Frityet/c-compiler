local Span = require("util.span")
local types = require("sema.types")

local enum SymbolKind
   "object"
   "function"
   "typedef"
   "tag"
   "enum"
   "label"
end

local enum Linkage
   "none"
   "internal"
   "external"
end

local enum StorageDuration
   "auto"
   "static"
   "thread"
end

local interface Symbol where self.kind
   name: string
   kind: SymbolKind
   type: types.TypeNode

   span: Span
   is_defined: boolean
end

local interface Constant is Symbol where self.kind == "enum" end
local interface Dynamic is Symbol where (function(k: SymbolKind): boolean return k == "object" or k == "function" or k == "tag" or k == "label" or k == "typedef" end)(self.kind)
   is_tentative: boolean
   linkage: Linkage
end

local interface Storable is Dynamic where (function(k: SymbolKind): boolean return k == "function" or k == "object" end)(self.kind)
   storage: StorageDuration
end

local record Enum is Constant where self.kind == "enum"
   enum_value: integer
end

local record Tag is Dynamic where self.kind == "tag"
end

local record TypeDef is Dynamic where self.kind == "typedef"
end

local record Label is Dynamic where self.kind == "label"

end

local record Object is Storable where self.kind == "object"

end

local record Function is Storable where self.kind == "function"

end

return {
   SymbolKind = SymbolKind,
   Linkage = Linkage,
   StorageDuration = StorageDuration,
   Symbol = Symbol,
   Enum = Enum,
   TypeDef = TypeDef,
   Tag = Tag,
   Label = Label,
   Object = Object,
   Function = Function,
   Constant = Constant,
   Dynamic = Dynamic,
   Storable = Storable
}
