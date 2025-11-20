local record signal
    SIGINT: integer

    signal: function(signum: integer, handler: function(signum: integer) | nil): function(signum: integer) | nil
end

return signal
