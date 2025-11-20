local record List<T> is {T}
    select: function<U>(self: self, f: function(T): U): List<U> = macroexp(self: self, f: function(T): U): List<U>
        return (function()
            local result: List<U> = {}
            for _, v in ipairs(self) do
                table.insert(result, (f)(v))
            end
            return result
        end)()
    end

    accumulate: function<U>(self: self, init: U, f: function(U, T): U): U = macroexp(self: self, init: U, f: function(U, T): U): U
        return (function()
            local acc: U = init
            for _, v in ipairs(self) do
                acc = (f)(acc, v)
            end
            return acc
        end)()
    end

    where: function(self: self, predicate: function(T): boolean): List<T> = macroexp(self: List<T>, predicate: function(T): boolean): List<T>
        return (function(): List<T>
            local result: List<T> = {}
            local p = (predicate)
            for _, v in ipairs(self) do
                if p(v) then
                    table.insert(result, v)
                end
            end
            return result
        end)()
    end

    select_many: function<U>(self: self, f: function(T): List<U>): List<U> = macroexp(self: List<T>, f: function(T): List<U>): List<U>
        return (function(): List<U>
            local result: List<U> = {}
            for _, v in ipairs(self) do
                local selected: List<U> = (f)(v)
                for _, sv in ipairs(selected) do
                    table.insert(result, sv)
                end
            end
            return result
        end)()
    end

    reverse: function(self: self): List<T> = macroexp(self: List<T>): List<T>
        return (function(): List<T>
            local s = self
            local result: List<T> = {}
            for i = #s, 1, -1 do
                table.insert(result, s[i])
            end
            return result
        end)()
    end

    sort: function(self: self, comparator: function(T, T): boolean): List<T> = macroexp(self: List<T>, comparator: function(T, T): boolean): List<T>
        return (function(): List<T>
            local result: List<T> = {}
            for _, v in ipairs(self) do
                table.insert(result, v)
            end
            table.sort(result, comparator)
            return result
        end)()
    end

    reduce: function(self: self, f: function(T, T): T): T = macroexp(self: List<T>, f: function(T, T): T): T
        return (function(): T
            local s = self
            if #s == 0 then
                error("cannot reduce an empty list")
            end
            local acc: T = s[1]
            for i = 2, #s do
                acc = (f)(acc, s[i])
            end
            return acc
        end)()
    end
    distinct: function(self: self): List<T> = macroexp(self: List<T>): List<T>
        return (function(): List<T>
            local seen: {T: boolean} = {}
            local result: List<T> = {}
            for _, v in ipairs(self) do
                if not seen[v] then
                    seen[v] = true
                    table.insert(result, v)
                end
            end
            return result
        end)()
    end
end

function List.range(start: integer, stop: integer, step?: integer): List<integer>
    local result: List<integer> = {}
    for i = start, stop, step or 1 do
        table.insert(result, i)
    end
    return result
end

return List
