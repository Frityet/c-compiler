--turn off GC to speed up execution
collectgarbage("stop")
collectgarbage("stop")

local cli = require("driver.cli")

cli.run(arg)
