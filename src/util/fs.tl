local function read_all(src: string): string | nil, string | nil
   local fh, err = io.open(src, "rb")
    if not fh then
       return nil, err
    end
    local data = fh:read("*a")
    fh:close()
    return data, nil
end

return {
    read_all = read_all,
}
