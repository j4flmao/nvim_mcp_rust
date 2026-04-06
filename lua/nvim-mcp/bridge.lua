-- lua/nvim-mcp/bridge.lua — Rust binary lifecycle + JSON-Lines IPC

local M = {}

local uv = vim.uv
local config

local handle
local stdin_pipe
local stdout_pipe
local stderr_pipe

local pending = {}
local next_id = 1
local buf = ""

local restart_delay = 1000
local consecutive_crashes = 0
local stream_callbacks = {}

M.on_usage = nil  -- callback set by UI

M.total_usage = {
  input_tokens = 0,
  output_tokens = 0,
  total_tokens = 0,
  cost_usd = 0.0,
}

local function binary_path()
  if config and config.binary then
    return config.binary
  end

  local src = debug.getinfo(1, "S").source:sub(2)
  local root = vim.fn.fnamemodify(src, ":h:h:h")

  local ext = ""
  if vim.fn.has("win32") == 1 then ext = ".exe" end

  local candidates = {
    vim.fn.stdpath("data") .. "/nvim-mcp/bin/nvim-mcp" .. ext,
    root .. "/target/release/nvim-mcp" .. ext,
    root .. "/target/debug/nvim-mcp" .. ext,
  }
  for _, p in ipairs(candidates) do
    if vim.fn.executable(p) == 1 then return p end
  end

  local path = vim.fn.exepath("nvim-mcp")
  if path ~= "" and vim.fn.executable(path) == 1 then
    return path
  end

  error("nvim-mcp: binary not found. Install the executable or set `binary` in config.")
end

function M.binary_path()
  return binary_path()
end

local function dispatch(msg)
  restart_delay = 1000
  consecutive_crashes = 0

  local msg_type = msg.type
  local id = msg.id

  if msg_type == "stream" then
    local cb = stream_callbacks[id]
    if cb then
      cb(msg.chunk, msg.done)
      if msg.done then
        stream_callbacks[id] = nil
      end
    end
  elseif msg_type == "result" then
    local cb = pending[id]
    if cb then
      pending[id] = nil
      cb(msg.data, nil)
    end
  elseif msg_type == "error" then
    local cb = pending[id] or stream_callbacks[id]
    if cb then
      pending[id] = nil
      stream_callbacks[id] = nil
      cb(nil, msg.message)
    end
  elseif msg_type == "event" then
    if msg.name == "usage" and msg.data then
      M.total_usage.input_tokens = M.total_usage.input_tokens + (msg.data.input_tokens or 0)
      M.total_usage.output_tokens = M.total_usage.output_tokens + (msg.data.output_tokens or 0)
      M.total_usage.total_tokens = M.total_usage.total_tokens + (msg.data.total_tokens or 0)
      M.total_usage.cost_usd = M.total_usage.cost_usd + (msg.data.cost_usd or 0)
      if M.on_usage then
        M.on_usage(msg.data)
      end
    end
  end
end

local function on_data(chunk)
  if not chunk then return end
  buf = buf .. chunk
  for line in buf:gmatch("([^\n]+)\n") do
    local ok, msg = pcall(vim.json.decode, line)
    if ok and type(msg) == "table" then
      dispatch(msg)
    end
  end
  buf = buf:match("[^\n]*$") or ""
end

local function on_exit(code)
  vim.schedule(function()
    handle = nil
    consecutive_crashes = consecutive_crashes + 1

    local level = consecutive_crashes >= 3
        and vim.log.levels.ERROR
        or vim.log.levels.WARN

    vim.notify(
      string.format("nvim-mcp: core exited (code %d), restarting in %ds",
        code, restart_delay / 1000),
      level
    )

    for _, cb in pairs(pending) do
      cb(nil, "binary restarted")
    end
    pending = {}
    for _, cb in pairs(stream_callbacks) do
      cb(nil, true)
    end
    stream_callbacks = {}
    buf = ""

    vim.defer_fn(function() M.start() end, restart_delay)
    restart_delay = math.min(restart_delay * 2, 30000)
  end)
end

function M.init(cfg)
  config = cfg
end

function M.start()
  if handle then return true end

  local ok, bin = pcall(binary_path)
  if not ok then
    vim.schedule(function()
      vim.notify("nvim-mcp: " .. bin, vim.log.levels.ERROR)
    end)
    return false
  end

  stdin_pipe  = uv.new_pipe()
  stdout_pipe = uv.new_pipe()
  stderr_pipe = uv.new_pipe()

  local log_level = (config and config.log and config.log.level) or "info"

  handle = uv.spawn(bin, {
    stdio = { stdin_pipe, stdout_pipe, stderr_pipe },
    env   = { "NVIM_MCP_LOG=nvim_mcp=" .. log_level },
  }, function(code, signal)
    on_exit(code)
  end)

  if not handle then
    vim.schedule(function()
      vim.notify("nvim-mcp: failed to spawn binary: " .. bin, vim.log.levels.ERROR)
    end)
    return
  end

  uv.read_start(stdout_pipe, function(err, data)
    if err then return end
    vim.schedule(function()
      on_data(data)
    end)
  end)

  uv.read_start(stderr_pipe, function(err, data)
    -- stderr is for tracing logs, optionally write to log file
    if data and config and config.log and config.log.file then
      local f = io.open(config.log.file, "a")
      if f then f:write(data); f:close() end
    end
  end)
end

function M.stop()
  if handle then
    uv.process_kill(handle, "sigterm")
    handle = nil
  end
  if stdin_pipe then stdin_pipe:close() end
  if stdout_pipe then stdout_pipe:close() end
  if stderr_pipe then stderr_pipe:close() end
  stdin_pipe = nil
  stdout_pipe = nil
  stderr_pipe = nil
  pending = {}
  stream_callbacks = {}
  buf = ""
end

function M.request(method, params, callback)
  if not handle or not stdin_pipe then
    if not M.start() then
      if callback then
        vim.schedule(function()
          callback(nil, "binary not running")
        end)
      end
      return
    end
  end

  local id = next_id
  next_id = next_id + 1

  if callback then
    pending[id] = callback
  end

  local msg = vim.json.encode({
    id     = id,
    method = method,
    params = params or {},
  }) .. "\n"

  stdin_pipe:write(msg)
end

function M.request_stream(method, params, on_chunk, on_done)
  if not handle or not stdin_pipe then
    if not M.start() then
      if on_done then
        vim.schedule(function()
          on_done(nil, "binary not running")
        end)
      end
      return
    end
  end

  local id = next_id
  next_id = next_id + 1

  stream_callbacks[id] = function(chunk, done_or_err)
    if type(done_or_err) == "string" then
      -- error
      if on_done then on_done(nil, done_or_err) end
    elseif done_or_err == true then
      if on_done then on_done(nil, nil) end
    else
      if on_chunk and chunk and chunk ~= "" then
        on_chunk(chunk)
      end
      if done_or_err then
        if on_done then on_done(nil, nil) end
      end
    end
  end

  local msg = vim.json.encode({
    id     = id,
    method = method,
    params = params or {},
  }) .. "\n"

  stdin_pipe:write(msg)
end

function M.fetch_models(params, callback)
  M.request("fetch_models", params, callback)
end

function M.set_provider(conn, callback)
  M.request("set_provider", {
    connection_id = conn.connection_id,
    provider      = conn.provider,
    model         = conn.model,
    api_key       = conn.api_key,
    host          = conn.host,
    display_name  = conn.display_name,
  }, callback)
end

function M.is_running()
  return handle ~= nil
end

function M.get_usage()
  return M.total_usage
end

function M.reset_usage()
  M.total_usage = {
    input_tokens = 0,
    output_tokens = 0,
    total_tokens = 0,
    cost_usd = 0.0,
  }
end

return M
