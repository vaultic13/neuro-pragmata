local M = {}

local PREFIX = "[pragmata] "

function M.info(msg)  log.info(PREFIX .. tostring(msg))   end
function M.warn(msg)  log.warn(PREFIX .. tostring(msg))   end
function M.error(msg) log.error(PREFIX .. tostring(msg))  end

return M
