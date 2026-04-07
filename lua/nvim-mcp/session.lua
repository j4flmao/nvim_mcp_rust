-- lua/nvim-mcp/session.lua — chat session state management with persistent history

local M = {}

local current = nil
local history_file = nil

local function get_history_path()
  if history_file then return history_file end
  local dir = vim.fn.stdpath("data") .. "/nvim-mcp"
  vim.fn.mkdir(dir, "p")
  history_file = dir .. "/history.json"
  return history_file
end

function M.new()
  current = {
    id           = vim.fn.strftime("%Y%m%d_%H%M%S"),
    messages     = {},
    response_lines = {},
    created_at   = vim.fn.strftime("%Y-%m-%d %H:%M:%S"),
  }
  return current
end

function M.get()
  return current
end

function M.ensure()
  if not current then
    return M.new()
  end
  return current
end

function M.add_user_message(content)
  local s = M.ensure()
  table.insert(s.messages, { role = "user", content = content, timestamp = vim.fn.strftime("%H:%M:%S") })
end

function M.add_assistant_message(content)
  local s = M.ensure()
  table.insert(s.messages, { role = "assistant", content = content, timestamp = vim.fn.strftime("%H:%M:%S") })
end

function M.save_response_lines(lines)
  local s = M.ensure()
  s.response_lines = lines or {}
end

function M.clear()
  if current and #current.messages > 0 then
    M.save_to_file()
  end
  current = nil
end

function M.has_history()
  return current ~= nil and #current.messages > 0
end

function M.get_messages()
  if not current then return {} end
  return current.messages
end

function M.load_history()
  local path = get_history_path()
  local f = io.open(path, "r")
  if not f then return {} end
  local raw = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, raw)
  return (ok and type(data) == "table") and data or {}
end

function M.save_to_file()
  if not current or #current.messages == 0 then return end
  
  local history = M.load_history()
  
  local session_entry = {
    id            = current.id,
    messages      = current.messages,
    response_lines = current.response_lines or {},
    created_at    = current.created_at,
    saved_at      = vim.fn.strftime("%Y-%m-%d %H:%M:%S"),
  }
  
  table.insert(history, 1, session_entry)
  
  if #history > 50 then
    history = { unpack(history, 1, 50) }
  end
  
  local tmp = get_history_path() .. ".tmp"
  local f = assert(io.open(tmp, "w"))
  f:write(vim.json.encode(history))
  f:close()
  vim.uv.fs_rename(tmp, get_history_path())
end

function M.get_history_list()
  local history = M.load_history()
  local list = {}
  for i, entry in ipairs(history) do
    local first_msg = ""
    for _, msg in ipairs(entry.messages) do
      if msg.role == "user" then
        first_msg = msg.content:sub(1, 60)
        if #msg.content > 60 then first_msg = first_msg .. "..." end
        break
      end
    end
    table.insert(list, {
      index     = i,
      id        = entry.id,
      preview   = first_msg,
      messages  = entry.messages,
      created_at = entry.created_at,
    })
  end
  return list
end

function M.load_session(index)
  local history = M.load_history()
  local entry = history[index]
  if not entry then return nil end
  
  current = {
    id            = entry.id,
    messages      = entry.messages,
    response_lines = entry.response_lines or {},
    created_at    = entry.created_at,
  }
  
  vim.notify("nvim-mcp: loaded session " .. current.id .. " with " .. #current.messages .. " messages", vim.log.levels.INFO)
  
  return current
end

function M.delete_session(index)
  local history = M.load_history()
  table.remove(history, index)
  
  local tmp = get_history_path() .. ".tmp"
  local f = assert(io.open(tmp, "w"))
  f:write(vim.json.encode(history))
  f:close()
  vim.uv.fs_rename(tmp, get_history_path())
end

function M.get_messages_for_display()
  if not current then return {} end
  local list = {}
  for i, msg in ipairs(current.messages) do
    local prefix = msg.role == "user" and "You" or "AI"
    local preview = msg.content:sub(1, 80)
    if #msg.content > 80 then preview = preview .. "..." end
    table.insert(list, {
      index   = i,
      role    = msg.role,
      content = msg.content,
      label   = string.format("#%d [%s] %s", i, prefix, preview),
      hint    = msg.timestamp or "",
    })
  end
  return list
end

function M.revert_to(index)
  if not current then return false end
  if index > #current.messages then return false end
  
  if index < 1 then
    current.messages = {}
    current.response_lines = {}
    return true
  end

  local new_messages = {}
  for i = 1, index do
    table.insert(new_messages, current.messages[i])
  end
  current.messages = new_messages

  if current.response_lines and #current.response_lines > 0 then
    current.response_lines = {}
  end

  return true
end

function M.update_message(index, new_content)
  if not current then return false end
  if index < 1 or index > #current.messages then return false end
  
  current.messages[index].content = new_content
  
  for i = #current.messages, index + 1, -1 do
    table.remove(current.messages, i)
  end

  if current.response_lines then
    current.response_lines = {}
  end
  
  return true
end

function M.update_response_lines(lines)
  if not current then return false end
  current.response_lines = lines or {}
  return true
end

return M
