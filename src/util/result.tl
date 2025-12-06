

local record result
   interface ResultBase
      ok: boolean
   end

   record Ok<T, E>
      is ResultBase
      where self.ok == true

      ok: boolean
      value: T
   end

   record Err<T, E>
      is ResultBase
      where self.ok == false

      ok: boolean
      err: E
   end

   type Result<T, E> = result.Ok<T, E> | result.Err<T, E>
end


function result.ok<T, E>(value: T): result.Ok<T, E>
   return { ok = true, value = value }
end

function result.err<T, E>(msg: E): result.Err<T, E>
   return { ok = false, err = msg }
end

function result.unwrap<T, E>(r: result.Result<T, E>): T
   if r is result.Ok<T, E> then
      return r.value
   end

   local e = r.err
   error("attempted to unwrap err: " .. tostring(e))
end

function result.expect<T, E>(r: result.Result<T, E>, message: string): T
   if r is result.Ok<T, E> then
      return r.value
   end

   local e = r.err
   error(message .. ": " .. tostring(e))
end



return result
