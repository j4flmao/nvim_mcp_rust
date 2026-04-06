-- lua/nvim-mcp/store.lua — persistent connection storage (connections.json)

local M = {}

local function path()
  local dir = vim.fn.stdpath("data") .. "/nvim-mcp"
  vim.fn.mkdir(dir, "p")
  return dir .. "/connections.json"
end

function M.load()
  local f = io.open(path(), "r")
  if not f then return {} end
  local raw = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, raw)
  return (ok and type(data) == "table") and data or {}
end

function M.save(list)
  local tmp = path() .. ".tmp"
  local f = assert(io.open(tmp, "w"))
  f:write(vim.json.encode(list))
  f:close()
  vim.uv.fs_rename(tmp, path())
end

function M.add(conn)
  local list = M.load()
  for _, c in ipairs(list) do
    c.active = false
  end
  conn.active = true
  table.insert(list, conn)
  M.save(list)
end

function M.set_active(id)
  local list = M.load()
  for _, c in ipairs(list) do
    c.active = (c.connection_id == id)
  end
  M.save(list)
end

function M.get_active()
  for _, c in ipairs(M.load()) do
    if c.active then return c end
  end
  return nil
end

function M.remove(id)
  local list = {}
  for _, c in ipairs(M.load()) do
    if c.connection_id ~= id then
      table.insert(list, c)
    end
  end
  local has_active = false
  for _, c in ipairs(list) do
    if c.active then has_active = true; break end
  end
  if not has_active and #list > 0 then
    list[1].active = true
  end
  M.save(list)
end

return M
