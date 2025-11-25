--turn off GC to speed up execution
collectgarbage("stop")
collectgarbage("stop")

require("driver.cli").run(arg)
