local symbols = require("sema.symbols")

local record Scope
   parent: Scope | nil
   objects: {string: symbols.Symbol}
   tags: {string: symbols.Symbol}
   labels: {string: symbols.Symbol}
end

local scope_mt: metatable<Scope> = {
   __index = Scope,
}

function Scope.new(parent?: Scope): Scope
   return setmetatable({
      parent = parent,
      objects = {},
      tags = {},
      labels = {},
   }, scope_mt)
end

local function resolve_bucket(scope: Scope, namespace: string): {string: symbols.Symbol}
   if namespace == "tag" then
      return scope.tags
   elseif namespace == "label" then
      return scope.labels
   end
   return scope.objects
end

function Scope:define(sym: symbols.Symbol, namespace?: string)
   local bucket = resolve_bucket(self, namespace or "object")
   bucket[sym.name] = sym
end

function Scope:lookup(name: string, namespace?: string): symbols.Symbol | nil
   local ns = namespace or "object"
   local current: Scope | nil = self
   while true do
      if not current then
         break
      end
      local scope: Scope = current
      local bucket = resolve_bucket(scope, ns)
      local found = bucket[name]
      if found then
         return found
      end
      current = scope.parent
   end
   return nil
end

function Scope:lookup_here(name: string, namespace?: string): symbols.Symbol | nil
   local bucket = resolve_bucket(self, namespace or "object")
   return bucket[name]
end

return {
   Scope = Scope,
}
