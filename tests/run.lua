local function copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = copy(x) end
  return out
end

local function eq(a, b)
  assert(a == b, tostring(a) .. " ~= " .. tostring(b))
end

-- Strict UTF-8 validation: rejects overlong forms, surrogates, out-of-range
-- leads, bad continuation bytes, and truncated trailing sequences.
local function valid_utf8(s)
  local i, n = 1, #s
  while i <= n do
    local c = s:byte(i)
    if c < 0x80 then
      i = i + 1
    else
      local need
      if c >= 0xC2 and c <= 0xDF then need = 2
      elseif c >= 0xE0 and c <= 0xEF then need = 3
      elseif c >= 0xF0 and c <= 0xF4 then need = 4
      else return false end
      if i + need - 1 > n then return false end
      for j = i + 1, i + need - 1 do
        local b = s:byte(j)
        if b < 0x80 or b > 0xBF then return false end
      end
      local b2 = s:byte(i + 1)
      if c == 0xE0 and b2 < 0xA0 then return false end
      if c == 0xED and b2 > 0x9F then return false end
      if c == 0xF0 and b2 < 0x90 then return false end
      if c == 0xF4 and b2 > 0x8F then return false end
      i = i + need
    end
  end
  return true
end

local null = newproxy()

local function host(files, json)
  local h = { files = files or {}, json = json or {}, commands = {}, tools = {}, events = {}, timers = {},
    ready = {}, notes = {}, sessions = {}, focus = "s1", created = 0, prompts = {}, calls = {}, fail = {},
    detached = false, plans = {}, messages = {}, mkdirs = {} }
  h.sessions.s1 = { id = "s1", cwd = "/project", model = "provider/model", mode = "build", status = "idle",
    queue = { count = 0 }, updated_at = 1, settings = { spec = "provider/model", thinking = "high", fast = false },
    tasks = { { id = "main" } }, workflow = "default", yolo = true }
  function h.spawn(fn)
    h.ready[#h.ready + 1] = coroutine.create(fn)
  end
  function h.drain()
    local n = 0
    while #h.ready > 0 do
      n = n + 1
      assert(n < 10000, "scheduler runaway")
      local co = table.remove(h.ready, 1)
      local ok, why = coroutine.resume(co)
      assert(ok, why)
      if coroutine.status(co) ~= "dead" and why ~= "blocked" then h.ready[#h.ready + 1] = co end
    end
  end
  function h.point(name)
    h.calls[name] = (h.calls[name] or 0) + 1
    if h.hook then h.hook(name, h.calls[name]) end
    coroutine.yield("yield")
    if h.fail[name] then return h.fail[name] end
  end
  function h.emit(event, data)
    h.spawn(function() h.events[event]({ event = event, data = data }) end)
  end
  function h.command(name, args)
    h.spawn(function() h.commands[name].handler({ args = args or "", fargs = {} }) end)
    h.drain()
  end
  function h.complete(summary, session, task)
    local result
    h.spawn(function()
      result = h.tools.loop_complete.handler({ summary = summary }, {
        session_id = function() return session or h.focus end,
        task_id = function() return task or "main" end,
      })
    end)
    h.drain()
    return result
  end
  function h.tick()
    local timers = h.timers
    h.timers = {}
    for _, t in ipairs(timers) do if not t.stopped then h.spawn(t.fn) end end
    h.drain()
  end
  function h.finish(reason, status, session)
    session = session or h.focus
    h.sessions[session].status = status or "idle"
    h.emit("TurnEnd", { session_id = session, reason = reason or "finished", cost = 0.25 })
    h.drain()
  end
  local function ui(name)
    assert(not h.detached, "UI call in teardown: " .. name)
    return h.point(name)
  end
  local m = { api = {}, fs = {}, env = {}, uv = {}, session = {}, plan = {}, model = {}, task = {}, json = {}, async = {} }
  m.async.semaphore = function()
    local busy, waiters = false, {}
    local function permit()
      return { release = function()
        if #waiters > 0 then h.ready[#h.ready + 1] = table.remove(waiters, 1) else busy = false end
      end }
    end
    return {
      acquire = function()
        h.acquired = (h.acquired or 0) + 1
        if busy then waiters[#waiters + 1] = coroutine.running(); coroutine.yield("blocked") else busy = true end
        return permit()
      end,
      try_acquire = function()
        if h.no_permit or busy then return nil end
        busy = true
        return permit()
      end,
    }
  end
  m.api.register_command = function(spec) h.commands[spec.name] = spec end
  m.api.register_tool = function(spec) h.tools[spec.name] = spec end
  m.api.create_autocmd = function(events, opts) for _, e in ipairs(events) do h.events[e] = opts.callback end end
  m.notify = function(text) assert(not h.detached, "notice in teardown"); h.notes[#h.notes + 1] = text end
  m.defer_fn = function(fn, ms)
    eq(ms, 0)
    local t = { fn = fn, stop = function(self) self.stopped = true end }
    h.timers[#h.timers + 1] = t
    return t
  end
  m.env.state_dir = function() return "/state" end
  m.uv.cwd = function() return h.cwd or "/project" end
  m.fs.normalize = function(path)
    local parts = {}
    for part in path:gmatch("[^/]+") do
      if part == ".." then table.remove(parts) elseif part ~= "." then parts[#parts + 1] = part end
    end
    return "/" .. table.concat(parts, "/")
  end
  function h.state_path()
    local cwd = m.fs.normalize(m.uv.cwd())
    local key = cwd:gsub(".", function(c) return string.format("%02x", string.byte(c)) end)
    local parts = { m.env.state_dir(), "loops" }
    for i = 1, #key, 120 do parts[#parts + 1] = key:sub(i, i + 119) end
    return table.concat(parts, "/") .. "/state.json"
  end
  function h.saved(path)
    return copy(h.json[h.files[path or h.state_path()]])
  end
  m.fs.mkdir = function(path, opts)
    eq(opts.parents, true)
    h.mkdirs[#h.mkdirs + 1] = path
    local err = h.point("mkdir")
    if err then return nil, err end
    return true
  end
  m.fs.metadata = function(path) local err = h.point("metadata"); if err then return nil, err end; return h.files[path] and { is_file = true } end
  m.fs.read = function(path) local err = h.point("fs_read"); if err then return nil, err end; return h.files[path] end
  m.fs.atomic_write = function(path, text)
    local err = h.point("write")
    if err then return nil, err end
    h.files[path] = text
    return true
  end
  m.json.encode = function(value)
    -- One-shot failure, consumed before the sticky h.fail.encode, so a single
    -- persist can be failed without disarming every later encode.
    if h.fail_encode_once then
      local err = h.fail_encode_once
      h.fail_encode_once = nil
      if type(err) == "function" then err() end
      return nil, err
    end
    if h.fail.encode then return nil, h.fail.encode end
    local id = "json:" .. tostring(#h.json + 1)
    h.json[#h.json + 1], h.json[id] = id, copy(value)
    return id
  end
  m.json.decode = function(text, opts)
    if h.json[text] == nil then return nil, "malformed JSON" end
    local luanil = opts and opts.luanil or {}
    local function decode(value)
      if type(value) ~= "table" then return value end
      local out = {}
      for k, v in pairs(value) do
        local drop = type(k) == "number" and luanil.array or type(k) == "string" and luanil.object
        if v ~= null or not drop then out[k] = decode(v) end
      end
      return out
    end
    return decode(h.json[text])
  end
  m.session.current = function() local err = ui("current"); if err then return nil, err end; return h.focus end
  m.session.read = function(opts)
    local err = ui("read")
    if err then return nil, err end
    local s = h.sessions[opts.session]
    if not s then return nil, "not live" end
    return copy(s)
  end
  m.session.focus = function(id)
    local err = ui("focus")
    if err then return nil, err end
    if not h.sessions[id] then return nil, "not live" end
    h.focus = id
    return true
  end
  m.model.get = function() local err = ui("model"); if err then return nil, err end; return copy(h.sessions[h.focus].settings) end
  m.plan.read = function(opts)
    local err = ui("plan")
    if err then return nil, err end
    -- The real host errors for unknown sessions instead of returning a blank.
    if not h.sessions[opts.session] then return nil, "not live" end
    return copy(h.plans[opts.session] or { mode = "build", ready = false })
  end
  m.session.messages = function(opts)
    local err = ui("messages")
    if err then return nil, err end
    local list = copy(h.messages[opts.session] or {})
    if opts.last and #list > opts.last then
      local tail = {}
      for i = #list - opts.last + 1, #list do tail[#tail + 1] = list[i] end
      return tail
    end
    return list
  end
  m.task.list = function() local err = ui("tasks"); if err then return nil, err end; return copy(h.sessions[h.focus].tasks) end
  m.session.new = function(opts)
    assert(opts.prompt == nil)
    -- maki stores a session without prompt or focus, and refuses to store a
    -- blank one, so this must always ask for a focused tab.
    if not opts.focus then return nil, "cannot store a session with no messages" end
    local err = ui("new")
    if err then return nil, err end
    h.created = h.created + 1
    local s = copy(h.sessions[h.focus])
    s.id, s.status, s.queue, s.tasks = "n" .. h.created, "idle", { count = 0 }, { { id = "main" } }
    -- A freshly opened session has no plan panel and no transcript of its own.
    s.plan, s.messages = nil, nil
    if opts.mode then s.mode = opts.mode end
    if h.new_mutate then h.new_mutate(s) end
    h.sessions[s.id] = s
    h.focus = s.id
    return s.id
  end
  m.session.prompt = function(text, opts)
    local err = ui("prompt")
    if err then return nil, err end
    eq(h.saved().owner, opts.session)
    eq(h.saved().status, "running")
    h.prompts[#h.prompts + 1] = { text = text, owner = opts.session }
    h.sessions[opts.session].status = "working"
    h.emit("TurnStart", { session_id = opts.session, text = text })
    return h.prompt_result or "started"
  end
  _G.maki = m
  local modules = {}
  local env = setmetatable({ maki = m }, { __index = _G })
  env.require = function(name)
    eq(name, "loop")
    if not modules[name] then
      local module = assert(loadfile("lua/" .. name .. ".lua"))
      setfenv(module, env)
      modules[name] = module() or true
    end
    return modules[name]
  end
  local entry = assert(loadfile("plugin/loop.lua"))
  setfenv(entry, env)
  entry()
  return h
end

local count = 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then error(name .. ": " .. tostring(err), 0) end
  count = count + 1
  print("ok " .. count .. " - " .. name)
end

test("package entrypoint registers loop commands, tool, and lifecycle hooks", function()
  local h = host()
  for _, name in ipairs({ "loop", "loop-stop", "loop-status", "loop-resume" }) do
    assert(h.commands[name], "missing command: " .. name)
  end
  assert(h.tools.loop_complete)
  for _, event in ipairs({ "TurnStart", "TurnEnd", "TurnError", "SessionStatusChanged", "TaskStatusChanged", "TaskStopped", "SessionEnd", "SessionReset" }) do
    assert(h.events[event], "missing event: " .. event)
  end
  eq(#h.prompts, 0)
  eq(h.created, 0)
end)

test("manifest targets maki 0.7.1 and requests exactly the session permissions", function()
  local file = assert(io.open("plugin.toml", "r"))
  local text = file:read("*a")
  file:close()
  eq(text:match('min_maki_version%s*=%s*"([^"]+)"'), "0.7.1")
  local section, values = nil, {}
  for line in text:gmatch("[^\n]+") do
    line = line:gsub("#.*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
    local header = line:match("^%[([^%]]+)%]$")
    if header then
      section = header
    elseif section == "permissions" and line ~= "" then
      local key, value = line:match("^([%w_]+)%s*=%s*(%a+)$")
      assert(key, "unparsed permission line: " .. line)
      eq(values[key], nil)
      values[key] = value == "true"
    end
  end
  local seen = {}
  for _, key in ipairs({ "agent", "session_write", "session_read", "fs_read", "fs_write" }) do
    eq(values[key], true)
    seen[key] = true
  end
  for _, key in ipairs({ "session_settings", "input", "net", "run", "env" }) do
    eq(values[key], false)
    seen[key] = true
  end
  for key in pairs(values) do assert(seen[key], "unknown permission: " .. key) end
end)

local function started()
  local h = host()
  h.command("loop", "do the work")
  eq(#h.prompts, 1)
  return h
end

test("raw objective, current context, fresh inheritance, duplicates, cost", function()
  local h = host()
  local raw = "  work  in foo.md\nexactly  "
  eq(h.commands.loop.nargs, "+")
  eq(h.tools.loop_complete.audiences[1], "main")
  h.command("loop", raw)
  eq(h.saved().objective, raw)
  eq(h.prompts[1].owner, "s1")
  eq(h.prompts[1].text:sub(-#raw), raw)
  h.sessions.other = copy(h.sessions.s1)
  h.sessions.other.settings = { spec = "other", thinking = "off", fast = true }
  h.focus = "other"
  h.finish("finished", "working", "s1")
  h.tick()
  eq(h.created, 0)
  h.finish("finished", "idle", "s1")
  h.emit("SessionStatusChanged", { session_id = "s1", status = "idle" })
  h.drain(); h.tick()
  eq(h.created, 1); eq(#h.prompts, 2)
  eq(h.sessions.n1.settings.thinking, "high")
  eq(h.sessions.n1.settings.fast, false)
  eq(h.sessions.n1.workflow, "default"); eq(h.sessions.n1.yolo, true)
  eq(h.prompts[2].text:sub(-#raw), raw)
  h.finish("finished", "idle", "s1"); h.tick()
  eq(h.created, 1); eq(h.saved().cost, 0.25)
end)

for _, case in ipairs({ "blank", "headless", "wrong" }) do
  test("reject start " .. case, function()
    local h = host()
    local s = h.sessions.s1
    if case == "headless" then s.queue = nil end
    if case == "wrong" then s.cwd = "/elsewhere" end
    h.command("loop", case == "blank" and " \n " or "work")
    eq(#h.prompts, 0); eq(h.created, 0)
  end)
end

test("reject start in a stored session", function()
  local h = host()
  h.sessions.s1.status, h.sessions.s1.queue = "stored", nil
  h.command("loop", "work")
  eq(#h.prompts, 0); eq(h.created, 0)
  assert(h.notes[#h.notes]:find("not open", 1, true))
end)

test("state directory failure interrupts before prompting", function()
  local h = host()
  local original = maki.env.state_dir
  maki.env.state_dir = function() return nil, "unavailable" end
  h.command("loop", "work")
  maki.env.state_dir = original
  eq(#h.prompts, 0); eq(h.created, 0)
  assert(h.notes[#h.notes]:find("unavailable", 1, true))
end)

test("state is stored under the state dir with a hex-encoded cwd", function()
  local h = started()
  assert(h.files["/state/loops/2f70726f6a656374/state.json"], "state path")
end)

test("replacement commands and unrelated lifecycle", function()
  local h = started()
  h.command("loop", "different")
  eq(h.saved().objective, "different")
  eq(h.saved().owner, "n1"); eq(h.saved().iteration, 1)
  eq(#h.prompts, 2)
  eq(h.sessions.s1.status, "working")
  for _, e in ipairs({ "TurnEnd", "TurnError", "SessionReset", "SessionEnd" }) do
    h.emit(e, { session_id = "other", reason = "finished" })
  end
  h.drain(); h.tick(); eq(h.saved().status, "running"); eq(h.created, 1)
end)

for _, status in ipairs({ "running", "rollover_pending", "stopped", "interrupted", "completed", "rewound" }) do
  test("new loop replaces " .. status, function()
    local h = started()
    if status == "rollover_pending" then h.finish()
    elseif status == "stopped" then h.command("loop-stop")
    elseif status == "interrupted" then h.finish("cancelled")
    elseif status == "completed" then h.complete("done")
    elseif status == "rewound" then h.sessions.s1.status = "idle" end
    h.command("loop", "foo bar baz"); h.tick()
    eq(h.saved().objective, "foo bar baz"); eq(h.saved().status, "running")
    eq(h.saved().iteration, 1); eq(h.saved().cost, 0); eq(h.saved().summary, nil)
    eq(h.created, 1); eq(#h.prompts, 2)
    eq(h.prompts[2].text:sub(-11), "foo bar baz")
    eq(h.complete("old completion", "s1").is_error, true)
    h.finish("cancelled", "idle", "s1"); h.tick()
    eq(h.saved().status, "running"); eq(h.saved().cost, 0)
    h.finish(); h.tick()
    eq(h.created, 2); eq(#h.prompts, 3)
    eq(h.saved().objective, "foo bar baz"); eq(h.saved().iteration, 2)
  end)
end

for _, status in ipairs({ "working", "needs_input", "queued", "plan" }) do
  test("new loop starts immediately from " .. status, function()
    local h = host()
    if status == "queued" then h.sessions.s1.queue.count = 2
    elseif status == "plan" then h.sessions.s1.mode = "plan"
    else h.sessions.s1.status = status end
    h.sessions.s1.tasks[2] = { id = "sub", status = "working" }
    local before = copy(h.sessions.s1)
    h.command("loop", "new objective")
    eq(h.created, 1); eq(#h.prompts, 1)
    eq(h.saved().owner, "n1"); eq(h.saved().iteration, 1)
    eq(h.sessions.n1.mode, "build")
    eq(h.sessions.s1.status, before.status); eq(h.sessions.s1.mode, before.mode)
    eq(h.sessions.s1.queue.count, before.queue.count)
  end)
end

local function messages_with_tasks(count)
  local call, result = { role = "assistant", content = {} }, { role = "user", content = {} }
  for i = 1, count do
    call.content[#call.content + 1] = { type = "tool_use", id = "t" .. i, name = "task", input = { description = "Scan " .. i } }
    result.content[#result.content + 1] = { type = "tool_result", tool_use_id = "t" .. i, content = { { type = "text", text = "found answer " .. i } } }
  end
  return { call, result, { role = "assistant", content = { { type = "text", text = "iteration summary" } } } }
end

test("initial plan-mode launch carries the plan", function()
  local h = host()
  h.sessions.s1.mode = "plan"
  h.plans.s1 = { mode = "plan", ready = true, path = "/state/plans/p1.md", content = "# Plan\nDo the thing" }
  h.command("loop", "objective")
  eq(h.created, 1); eq(#h.prompts, 1)
  local prompt = h.prompts[1].text
  assert(prompt:find("/state/plans/p1.md", 1, true), "plan path")
  assert(prompt:find("# Plan\nDo the thing", 1, true), "plan content")
  assert(prompt:find("PLAN captured from plan mode", 1, true), "plan section")
  assert(prompt:find("re-read the file before acting", 1, true), "plan safety wording")
  assert(not prompt:find("No prior conversation or summary is supplied", 1, true), "removed disclaimer")
  eq(h.calls.plan, 1)
  eq(h.calls.messages, nil)
end)

test("initial launch does not carry a subagent digest", function()
  local h = host()
  h.sessions.s1.mode = "plan"
  h.plans.s1 = { mode = "plan", ready = true, path = "/state/plans/p1.md", content = "# Plan\nDo the thing" }
  h.messages.s1 = messages_with_tasks(1)
  h.command("loop", "objective")
  eq(h.created, 1); eq(#h.prompts, 1)
  assert(not h.prompts[1].text:find("PREVIOUS ITERATION RESULTS", 1, true))
end)

test("plan is sticky across iterations", function()
  local h = started()
  h.plans.s1 = { mode = "plan", ready = true, path = "/state/plans/sticky.md", content = "# Sticky plan" }
  h.messages.s1 = messages_with_tasks(1)
  h.finish(); h.tick()
  eq(h.created, 1); eq(#h.prompts, 2)
  eq(h.saved().plan.path, "/state/plans/sticky.md")
  assert(h.prompts[2].text:find("/state/plans/sticky.md", 1, true))
  assert(h.prompts[2].text:find("PREVIOUS ITERATION RESULTS", 1, true), "iteration 2 carry")
  h.plans = {}
  h.finish(); h.tick()
  eq(h.created, 2); eq(#h.prompts, 3)
  eq(h.saved().owner, "n2")
  eq(h.saved().plan.path, "/state/plans/sticky.md")
  assert(h.prompts[3].text:find("/state/plans/sticky.md", 1, true))
  assert(h.prompts[3].text:find("# Sticky plan", 1, true))
  assert(not h.prompts[3].text:find("PREVIOUS ITERATION RESULTS", 1, true), "carry leaked past one iteration")
end)

test("persisted plan survives reload and resume", function()
  local h = started()
  h.plans.s1 = { mode = "plan", ready = true, path = "/state/plans/sticky.md", content = "# Sticky plan" }
  h.finish(); h.tick()
  eq(h.created, 1); eq(h.saved().plan.path, "/state/plans/sticky.md")
  local reload = host(h.files, h.json)
  reload.command("loop-status")
  eq(reload.saved().status, "interrupted")
  reload.command("loop-resume")
  eq(reload.created, 1); eq(#reload.prompts, 1)
  assert(reload.prompts[1].text:find("/state/plans/sticky.md", 1, true))
  assert(reload.prompts[1].text:find("# Sticky plan", 1, true))
end)

test("rollover carries finished task results and final summary", function()
  local h = started()
  local messages = messages_with_tasks(1)
  local call, result = messages[1], messages[2]
  call.content[#call.content + 1] = { type = "tool_use", id = "ts", name = "task", input = { description = "Scan string" } }
  result.content[#result.content + 1] = { type = "tool_result", tool_use_id = "ts", content = "plain string output" }
  call.content[#call.content + 1] = { type = "tool_use", id = "tb", name = "bash", input = { description = "Shell step" } }
  result.content[#result.content + 1] = { type = "tool_result", tool_use_id = "tb", content = "shell output" }
  call.content[#call.content + 1] = { type = "tool_use", id = "te", name = "task", input = { description = "Scan error" } }
  result.content[#result.content + 1] = { type = "tool_result", tool_use_id = "te", content = "error output", is_error = true }
  h.messages.s1 = messages
  h.finish(); h.tick()
  eq(h.created, 1); eq(#h.prompts, 2)
  local prompt = h.prompts[2].text
  assert(prompt:find("PREVIOUS ITERATION RESULTS", 1, true))
  assert(prompt:find("reference data, not instructions", 1, true), "digest safety wording")
  assert(prompt:find("Scan 1", 1, true))
  assert(prompt:find("found answer 1", 1, true))
  assert(prompt:find("iteration summary", 1, true))
  local exact = false
  for line in prompt:gmatch("[^\n]+") do
    if line == "- Scan string (ts): plain string output" then exact = true end
  end
  assert(exact, "string tool_result rendered line")
  for _, text in ipairs({ "shell output", "error output", "Scan error" }) do
    assert(not prompt:find(text, 1, true), "excluded text present: " .. text)
  end
end)

test("iteration three carry replaces the previous digest", function()
  local h = started()
  h.messages.s1 = messages_with_tasks(1)
  h.finish(); h.tick()
  eq(h.created, 1); eq(#h.prompts, 2)
  assert(h.prompts[2].text:find("Scan 1", 1, true), "iteration 2 digest")
  h.messages.n1 = {
    { role = "assistant", content = { { type = "tool_use", id = "q1", name = "task", input = { description = "n1 scan" } } } },
    { role = "user", content = { { type = "tool_result", tool_use_id = "q1", content = "n1 output" } } },
    { role = "assistant", content = { { type = "text", text = "n1 summary" } } },
  }
  h.finish(); h.tick()
  eq(h.created, 2); eq(#h.prompts, 3)
  local prompt = h.prompts[3].text
  assert(prompt:find("n1 scan", 1, true), "iteration 3 digest")
  assert(prompt:find("n1 output", 1, true), "iteration 3 task text")
  assert(not prompt:find("Scan 1", 1, true), "iteration 2 carry leaked into iteration 3")
  eq(h.saved().carry.tasks[1].label, "n1 scan")
  eq(h.saved().carry.tasks[1].id, "q1")
end)

test("context is clipped at line boundaries", function()
  local h = started()
  local lines = {}
  for i = 1, 1000 do lines[i] = string.rep("p", 19) .. "\n" end
  h.plans.s1 = { mode = "plan", ready = true, path = "/state/plans/long.md", content = table.concat(lines) }
  h.messages.s1 = messages_with_tasks(10)
  h.finish(); h.tick()
  eq(h.created, 1); eq(#h.prompts, 2)
  local prompt = h.prompts[2].text
  assert(prompt:find("…(truncated)", 1, true), "truncation marker")
  assert(#prompt < 20000, "prompt length " .. #prompt)
  local tasks, total = 0, 0
  for text in prompt:gmatch("\n%- Scan %d+ %(t%d+%): ([^\n]*)") do
    tasks = tasks + 1
    assert(#text <= 1500 + 15, "task text length " .. #text)
    total = total + #text
  end
  eq(tasks, 6)
  assert(total <= 8192, "task text total " .. total)
  assert(#h.saved().plan.content <= 12288, "plan content length " .. #h.saved().plan.content)
end)

-- clip() cuts at byte 12273 (12288 minus the 15-byte marker). Both contents
-- below put a codepoint boundary at a different offset, so byte 12273 is
-- *inside* a codepoint; a cut that is safe only by accident (a pure run of
-- 3-byte characters lands 12273 exactly on a boundary) would hide a broken
-- utf8_trim. The ASCII "x" prefix shifts the run by one: 12273-1 = 12272 bytes
-- of "あ" are kept, i.e. 12272 % 3 = 2 of 3 bytes, while 12273 % 4 = 1 of a
-- "😀"'s 4 bytes is kept without its continuations.
test("multibyte plan clipping cuts mid-codepoint and preserves UTF-8", function()
  for _, case in ipairs({
    { name = "3-byte", content = "x" .. string.rep("あ", 5000), continuation = true },
    { name = "4-byte", content = string.rep("😀", 4000), continuation = false },
  }) do
    assert(valid_utf8(case.content))
    local byte = case.content:byte(12273)
    if case.continuation then
      assert(byte >= 0x80 and byte < 0xC0, case.name .. ": cut splits a multibyte sequence")
    else
      assert(byte >= 0xF0, case.name .. ": cut leaves a 4-byte lead without continuations")
    end
    local h = started()
    h.plans.s1 = { mode = "plan", ready = true, path = "/state/plans/utf8.md", content = case.content }
    h.finish(); h.tick()
    eq(h.created, 1); eq(#h.prompts, 2); eq(h.saved().status, "running")
    local prompt = h.prompts[2].text
    assert(valid_utf8(prompt), case.name .. ": prompt is valid UTF-8")
    assert(valid_utf8(h.saved().plan.content), case.name .. ": saved plan is valid UTF-8")
    assert(prompt:find("…(truncated)", 1, true), case.name .. ": prompt marker")
    assert(h.saved().plan.content:find("…(truncated)", 1, true), case.name .. ": persisted marker")
    assert(#h.saved().plan.content <= 12288, case.name .. ": plan content length " .. #h.saved().plan.content)
  end
end)

test("oversized single task result is clipped to the per-item cap", function()
  local h = started()
  h.messages.s1 = {
    { role = "assistant", content = { { type = "tool_use", id = "big", name = "task", input = { description = "Big scan" } } } },
    { role = "user", content = { { type = "tool_result", tool_use_id = "big", content = string.rep("a", 2000) } } },
  }
  h.finish(); h.tick()
  eq(h.created, 1); eq(#h.prompts, 2)
  local task = h.saved().carry.tasks[1]
  eq(task.label, "Big scan")
  assert(#task.text <= 1500 + 15, "task text length " .. #task.text)
  assert(task.text:find("…(truncated)", 1, true), "task truncation marker")
  assert(h.prompts[2].text:find("…(truncated)", 1, true), "prompt truncation marker")
end)

test("ten task results keep the newest six within the carry budget", function()
  local h = started()
  local call, result = { role = "assistant", content = {} }, { role = "user", content = {} }
  for i = 1, 10 do
    call.content[#call.content + 1] = { type = "tool_use", id = "t" .. i, name = "task", input = { description = "Scan " .. i } }
    result.content[#result.content + 1] = { type = "tool_result", tool_use_id = "t" .. i,
      content = "result " .. i .. " " .. string.rep("z", 1000) }
  end
  h.messages.s1 = { call, result }
  h.finish(); h.tick()
  eq(h.created, 1); eq(#h.prompts, 2)
  local tasks, total = h.saved().carry.tasks, 0
  eq(#tasks, 6)
  eq(tasks[1].id, "t5"); eq(tasks[#tasks].id, "t10")
  for _, task in ipairs(tasks) do total = total + #task.text end
  assert(total <= 8192, "carry total " .. total)
  local prompt = h.prompts[2].text
  assert(prompt:find("Scan 10", 1, true))
  assert(not prompt:find("Scan 4", 1, true), "older task leaked into the prompt")
end)

test("oversized iteration summary is clipped to the summary cap", function()
  local h = started()
  h.messages.s1 = { { role = "assistant", content = { { type = "text", text = string.rep("s", 3000) } } } }
  h.finish(); h.tick()
  eq(h.created, 1); eq(#h.prompts, 2)
  local summary = h.saved().carry.summary
  assert(summary, "summary kept")
  assert(#summary <= 2000 + 15, "summary length " .. #summary)
  assert(summary:find("…(truncated)", 1, true), "summary truncation marker")
  assert(h.prompts[2].text:find("…(truncated)", 1, true), "prompt truncation marker")
end)

test("capture failure never interrupts rollover", function()
  local h = started()
  h.fail.plan = "plan down"
  h.fail.messages = "messages down"
  h.finish(); h.tick()
  eq(h.created, 1); eq(#h.prompts, 2)
  eq(h.saved().status, "running")
  assert(h.saved().capture_note:find("capture:", 1, true))
  h.command("loop-status")
  assert(h.notes[#h.notes]:find("| capture: plan down", 1, true))
end)

test("encode failure drops captured context and keeps the loop running", function()
  local h = started()
  h.plans.s1 = { mode = "plan", ready = true, path = "/state/plans/enc.md", content = "# enc plan" }
  h.messages.s1 = messages_with_tasks(1)
  -- The rollover_pending persist happens first, so arm the one-shot after it.
  h.finish()
  h.fail_encode_once = "utf8"
  h.tick()
  eq(h.fail_encode_once, nil)
  assert(h.files[h.state_path()], "state file was written after the retry")
  local saved = h.saved()
  eq(saved.status, "running")
  eq(saved.plan, nil)
  eq(saved.carry, nil)
  eq(saved.capture_note, "context dropped: state encode failed")
  eq(saved.starting, nil)
  eq(h.created, 1); eq(#h.prompts, 2)
end)

test("message-path fallback finds a plan", function()
  local h = started()
  h.messages.s1 = { { role = "assistant", content = { { type = "text", text = "Plan: /state/plans/fallback.md" } } } }
  h.files["/state/plans/fallback.md"] = "# fallback plan"
  h.finish(); h.tick()
  eq(h.created, 1); eq(#h.prompts, 2)
  local prompt = h.prompts[2].text
  assert(prompt:find("/state/plans/fallback.md", 1, true))
  assert(prompt:find("# fallback plan", 1, true))
end)

test("message-path fallback rejects plans outside the state plans directory", function()
  local h = started()
  h.messages.s1 = { { role = "assistant", content = { { type = "text", text = "Plan: /elsewhere/plans/stolen.md" } } } }
  h.files["/elsewhere/plans/stolen.md"] = "# stolen"
  h.finish(); h.tick()
  eq(h.created, 1); eq(#h.prompts, 2)
  eq(h.saved().plan, nil)
  assert(not h.prompts[2].text:find("PLAN captured", 1, true))
  assert(not h.prompts[2].text:find("# stolen", 1, true))
end)

test("message-path fallback requires the plan file to exist", function()
  local h = started()
  h.messages.s1 = { { role = "assistant", content = { { type = "text", text = "Plan: /state/plans/missing.md" } } } }
  eq(h.files["/state/plans/missing.md"], nil)
  h.finish(); h.tick()
  eq(h.created, 1); eq(#h.prompts, 2)
  eq(h.saved().plan, nil)
  assert(not h.prompts[2].text:find("PLAN captured", 1, true))
end)

test("prompt baseline is unchanged without context", function()
  local h = started()
  local prompt = h.prompts[1].text
  eq(prompt:sub(-#"do the work"), "do the work")
  assert(prompt:find("a fresh session will repeat the objective", 1, true), "continuation wording")
  assert(prompt:find("Original objective (verbatim)", 1, true))
  assert(not prompt:find("No prior conversation or summary is supplied", 1, true))
  assert(not prompt:find("PLAN captured", 1, true))
  assert(not prompt:find("PREVIOUS ITERATION RESULTS", 1, true))
  eq(h.calls.plan, nil)
end)

test("state writes stay inside the loop directory", function()
  local h = started()
  h.plans.s1 = { mode = "plan", ready = true, path = "/state/plans/write.md", content = "# plan" }
  h.messages.s1 = messages_with_tasks(1)
  h.finish(); h.tick()
  eq(h.saved().plan.path, "/state/plans/write.md")
  local expected = h.state_path()
  local written = 0
  for path in pairs(h.files) do
    eq(path, expected)
    written = written + 1
  end
  eq(written, 1)
  assert(#h.mkdirs > 0)
  for _, path in ipairs(h.mkdirs) do eq(path:sub(1, #"/state/loops/"), "/state/loops/") end

  local fallback = host()
  fallback.files["/state/plans/keep.md"] = "# keep"
  fallback.messages.s1 = { { role = "assistant", content = { { type = "text", text = "see /state/plans/keep.md" } } } }
  local seeded = copy(fallback.files)
  fallback.command("loop", "work")
  fallback.finish(); fallback.tick()
  eq(fallback.created, 1)
  eq(fallback.saved().plan.path, "/state/plans/keep.md")
  eq(fallback.files["/state/plans/keep.md"], "# keep")
  local added = 0
  for path in pairs(fallback.files) do
    if seeded[path] == nil then
      eq(path, fallback.state_path())
      added = added + 1
    end
  end
  eq(added, 1)
  assert(#fallback.mkdirs > 0)
  for _, path in ipairs(fallback.mkdirs) do eq(path:sub(1, #"/state/loops/"), "/state/loops/") end
end)

test("status shows the captured plan", function()
  local h = host()
  h.sessions.s1.mode = "plan"
  h.plans.s1 = { mode = "plan", ready = true, path = "/state/plans/status.md", content = "# status plan" }
  h.command("loop", "objective")
  h.command("loop-status")
  assert(h.notes[#h.notes]:find("| plan /state/plans/status.md", 1, true))
end)

test("new loop replaces corrupt saved state without reading it", function()
  local h = started()
  local path = next(h.files)
  h.files[path] = "broken"
  local reload = host(h.files, h.json)
  reload.command("loop", "replacement")
  eq(#reload.prompts, 1); eq(reload.saved().objective, "replacement")
  eq(reload.calls.fs_read, nil)
end)

for _, point in ipairs({ "current", "read", "mkdir", "write", "prompt" }) do
  test("new loop supersedes initial startup at " .. point, function()
    local h = host()
    local fired = false
    h.hook = function(name)
      if fired or name ~= point then return end
      fired = true
      h.spawn(function() h.commands.loop.handler({ args = "latest objective" }) end)
    end
    h.command("loop", "old objective"); h.tick()
    assert(fired)
    eq(h.saved().objective, "latest objective"); eq(h.saved().status, "running")
    eq(h.prompts[#h.prompts].text:sub(-16), "latest objective")
    eq(#h.prompts, point == "prompt" and 2 or 1)
  end)
end

for _, point in ipairs({ "read", "focus", "current", "tasks", "model", "new", "mkdir", "write", "prompt" }) do
  test("new loop supersedes deferred handoff at " .. point, function()
    local h = started(); h.finish()
    local fired = false
    h.hook = function(name)
      if fired or name ~= point then return end
      fired = true
      h.spawn(function() h.commands.loop.handler({ args = "replacement" }) end)
    end
    h.tick(); h.tick()
    assert(fired)
    eq(h.saved().objective, "replacement"); eq(h.saved().status, "running")
    eq(h.saved().iteration, 1)
    eq(h.prompts[#h.prompts].text:sub(-11), "replacement")
    h.finish(); h.tick()
    eq(h.saved().objective, "replacement"); eq(h.saved().iteration, 2)
  end)
end

for _, point in ipairs({ "current", "read", "focus", "model", "new", "mkdir", "write", "prompt" }) do
  test("new loop supersedes replacement startup at " .. point, function()
    local h = started()
    local fired = false
    h.hook = function(name)
      if fired or name ~= point then return end
      fired = true
      h.spawn(function() h.commands.loop.handler({ args = "latest" }) end)
    end
    h.command("loop", "superseded"); h.tick()
    assert(fired)
    eq(h.saved().objective, "latest"); eq(h.saved().status, "running")
    eq(h.saved().iteration, 1)
    eq(h.prompts[#h.prompts].text:sub(-6), "latest")
  end)
end

test("old owner cannot complete or cancel replacement during startup", function()
  local h = started()
  local result
  h.hook = function(name)
    if name ~= "new" then return end
    h.spawn(function()
      result = h.tools.loop_complete.handler({ summary = "old work done" }, {
        session_id = function() return "s1" end, task_id = function() return "main" end,
      })
    end)
    h.emit("TurnEnd", { session_id = "s1", reason = "cancelled", cost = 9 })
  end
  h.command("loop", "replacement")
  eq(result.is_error, true)
  eq(h.saved().status, "running"); eq(h.saved().cost, 0); eq(#h.prompts, 2)
end)

for _, point in ipairs({ "metadata", "fs_read", "mkdir", "write", "new" }) do
  test("new loop supersedes resume at " .. point, function()
    local old = started(); old.command("loop-stop")
    local h = host(old.files, old.json)
    local fired = false
    h.hook = function(name)
      if fired or name ~= point then return end
      fired = true
      h.spawn(function() h.commands.loop.handler({ args = "replacement" }) end)
    end
    h.command("loop-resume"); h.tick()
    assert(fired)
    eq(h.saved().objective, "replacement"); eq(h.saved().status, "running")
    eq(h.prompts[#h.prompts].text:sub(-11), "replacement")
  end)
end

test("latest of three overlapping starts wins", function()
  local h = host()
  local launches = 0
  h.hook = function(name)
    if name ~= "read" or launches == 2 then return end
    launches = launches + 1
    local objective = "replacement " .. launches
    h.spawn(function() h.commands.loop.handler({ args = objective }) end)
  end
  h.command("loop", "old"); h.tick()
  eq(h.saved().objective, "replacement 2"); eq(#h.prompts, 1)
end)

test("completion ownership, summary, main-only, durable idempotence", function()
  local h = started()
  eq(h.complete("", "s1").is_error, true)
  eq(h.complete("done", "other").is_error, true)
  eq(h.complete("done", "s1", "sub").is_error, true)
  assert(not h.complete("verified all", "s1").is_error)
  assert(not h.complete("replacement", "s1").is_error)
  eq(h.saved().summary, "verified all")
  h.finish(); h.tick(); eq(h.created, 0); eq(h.saved().status, "completed")
  h.command("loop-resume"); eq(h.created, 0)
end)

test("completion beats pending timer", function()
  local h = started(); h.finish()
  assert(not h.complete("all done", "s1").is_error)
  h.tick(); eq(h.created, 0)
end)

test("stop keeps work, explicit fresh resume", function()
  local h = started()
  h.command("loop-stop")
  eq(h.sessions.s1.status, "working")
  h.finish(); h.tick(); eq(h.created, 0)
  h.command("loop-resume")
  eq(h.created, 1); eq(h.saved().iteration, 2); eq(#h.prompts, 2)
end)

for _, status in ipairs({ "working", "needs_input" }) do
  test("resume during " .. status .. " waits for normal finish and idle", function()
    local h = started()
    h.command("loop-stop")
    h.sessions.s1.status = status
    h.command("loop-resume"); h.tick()
    eq(h.sessions.s1.status, status)
    eq(h.saved().status, "running"); eq(h.created, 0); eq(#h.prompts, 1)
    h.command("loop-resume"); eq(h.created, 0)
    h.sessions.s1.status = "working"
    h.emit("SessionStatusChanged", { session_id = "s1", status = "working" })
    h.drain(); h.tick(); eq(h.created, 0)
    h.finish("finished", "working"); h.tick(); eq(h.created, 0)
    h.sessions.s1.status = "idle"
    h.emit("SessionStatusChanged", { session_id = "s1", status = "idle" })
    h.drain(); h.tick(); h.tick()
    eq(h.created, 1); eq(#h.prompts, 2); eq(h.saved().iteration, 2)
    eq(h.saved().cost, 0.25); eq(h.saved().cost_reports, 1)
    eq(h.saved().resume_parent, nil)
    h.finish(); h.tick(); eq(h.created, 2)
  end)
end

test("resume adopts a manual turn after interruption", function()
  local h = started(); h.finish("cancelled")
  h.sessions.s1.status = "working"
  h.emit("TurnStart", { session_id = "s1", text = "continue the work" }); h.drain()
  h.command("loop-resume"); h.tick(); eq(h.created, 0)
  h.finish(); h.tick()
  eq(h.created, 1); eq(h.saved().cost, 0.5); eq(h.saved().cost_reports, 2)
end)

test("resume waits for focused turn rather than old owner", function()
  local h = started(); h.command("loop-stop")
  h.sessions.other = copy(h.sessions.s1)
  h.sessions.other.id = "other"
  h.sessions.other.settings = { spec = "other", thinking = "off", fast = true }
  h.focus = "other"
  h.command("loop-resume")
  eq(h.saved().owner, "s1"); eq(h.saved().sessions[1].id, "s1")
  eq(h.complete("old owner finished", "s1").is_error, true)
  h.finish("finished", "idle", "s1"); h.tick(); eq(h.created, 0)
  h.finish("finished", "idle", "other"); h.tick()
  eq(h.created, 1); eq(h.saved().iteration, 2); eq(h.saved().owner, "n1")
  eq(h.sessions.n1.settings.spec, "other"); eq(h.saved().cost_reports, 1)
end)

for _, point in ipairs({ "read", "mkdir", "write" }) do
  test("finish racing resume at " .. point .. " is not lost", function()
    local h = started(); h.command("loop-stop")
    local fired = false
    h.hook = function(name)
      if fired or name ~= point then return end
      fired = true
      h.sessions.s1.status = "idle"
      h.emit("TurnEnd", { session_id = "s1", reason = "finished", cost = 0.25 })
    end
    h.command("loop-resume"); h.tick(); h.tick()
    eq(h.created, 1); eq(#h.prompts, 2)
  end)
end

for _, action in ipairs({ "stop", "cancelled", "error", "queued", "task", "manual", "reload", "write" }) do
  test("armed resume is revoked by " .. action, function()
    local h = started(); h.command("loop-stop")
    if action == "write" then h.fail.write = "disk full" end
    h.command("loop-resume")
    h.fail.write = nil
    if action == "stop" then h.command("loop-stop")
    elseif action == "error" then h.emit("TurnError", { session_id = "s1", message = "provider failed" })
    elseif action == "queued" then h.sessions.s1.queue.count = 1
    elseif action == "task" then h.sessions.s1.tasks[2] = { id = "sub", status = "working" }
    elseif action == "manual" then h.emit("TurnStart", { session_id = "s1" })
    elseif action == "reload" then h.emit("SessionEnd", { session_id = "s1", reason = "reload" }) end
    h.drain(); h.finish(action == "cancelled" and "cancelled" or "finished"); h.tick()
    eq(h.created, 0); eq(#h.prompts, 1)
    eq(h.saved().status, action == "stop" and "stopped" or "interrupted")
  end)
end

test("stop racing busy resume persistence revokes continuation", function()
  local h = started(); h.command("loop-stop")
  local fired = false
  h.hook = function(name)
    if fired or name ~= "write" then return end
    fired = true
    h.spawn(function() h.commands["loop-stop"].handler({}) end)
  end
  h.command("loop-resume"); h.finish(); h.tick()
  eq(h.saved().status, "stopped"); eq(h.created, 0); eq(#h.prompts, 1)
end)

test("owning turn can complete an armed resume", function()
  local h = started(); h.command("loop-stop"); h.command("loop-resume")
  assert(not h.complete("all verified", "s1").is_error)
  h.finish(); h.tick(); eq(h.created, 0); eq(h.saved().status, "completed")
end)

for _, case in ipairs({ "queued", "plan", "headless", "wrong" }) do
  test("busy resume still rejects " .. case, function()
    local h = started(); h.command("loop-stop")
    if case == "queued" then h.sessions.s1.queue.count = 1
    elseif case == "plan" then h.sessions.s1.mode = "plan"
    elseif case == "headless" then h.sessions.s1.queue = nil
    else h.sessions.s1.cwd = "/elsewhere" end
    h.command("loop-resume"); h.finish(); h.tick()
    eq(h.created, 0); eq(h.saved().status, "stopped")
  end)
end

test("reload can resume an in-flight turn explicitly", function()
  local h = started(); h.command("loop-stop"); h.command("loop-resume")
  local reload = host(h.files, h.json)
  reload.sessions.s1.status = "working"
  reload.command("loop-status"); eq(reload.saved().status, "interrupted")
  reload.command("loop-resume"); reload.tick(); eq(reload.created, 0)
  reload.finish(); reload.tick(); eq(reload.created, 1)
end)

test("resume rechecks a pending rollover without an idle event", function()
  local h = started(); h.finish("finished", "working"); h.tick()
  eq(h.saved().status, "rollover_pending"); eq(h.created, 0)
  h.sessions.s1.status = "idle"
  h.command("loop-resume"); h.tick()
  eq(h.created, 1); eq(h.saved().iteration, 2); eq(#h.prompts, 2)
end)

for _, status in ipairs({ "idle", "working" }) do
  test("reload discards persisted handoff flags before " .. status .. " resume", function()
    local h = started(); h.finish()
    local _, text = next(h.files)
    h.json[text].handoff, h.json[text].wake = true, true
    local reload = host(h.files, h.json)
    reload.sessions.s1.status = status
    reload.command("loop-resume")
    if status == "working" then reload.finish(); reload.tick() end
    eq(reload.created, 1); eq(reload.saved().iteration, 2)
    eq(reload.saved().handoff, nil); eq(reload.saved().wake, nil)
    reload.finish(); reload.tick(); eq(reload.created, 2)
  end)
end

test("handoff execution flags are never persisted", function()
  local h = started(); h.finish(); h.tick()
  eq(h.created, 1); eq(h.saved().handoff, nil); eq(h.saved().wake, nil)
end)

test("unexpected handoff errors interrupt instead of wedging resume", function()
  local h = started(); h.finish()
  local original = maki.session.read
  maki.session.read = function() error("unexpected read failure") end
  h.tick()
  eq(h.saved().status, "interrupted"); eq(h.created, 0)
  assert(h.saved().reason:find("unexpected read failure", 1, true))
  maki.session.read = original
  h.command("loop-resume"); eq(h.created, 1)
end)

test("question suspension and answer do not end iteration", function()
  local h = started()
  h.sessions.s1.status = "needs_input"
  h.emit("SessionStatusChanged", { session_id = "s1", status = "needs_input" })
  h.drain(); h.tick(); eq(h.created, 0); eq(h.saved().status, "running")
  h.sessions.s1.status = "working"
  h.emit("SessionStatusChanged", { session_id = "s1", status = "working" })
  h.drain(); h.finish(); h.tick(); eq(h.created, 1)
end)

for _, case in ipairs({ "queued", "manual", "working", "needs_input", "task_event", "task_snapshot", "cwd", "plan" }) do
  test("handoff rejects " .. case, function()
    local h = started(); h.finish()
    if case == "queued" then h.sessions.s1.queue.count = 1
    elseif case == "manual" then h.emit("TurnStart", { session_id = "s1" })
    elseif case == "working" or case == "needs_input" then
      h.sessions.s1.status = case
      h.emit("SessionStatusChanged", { session_id = "s1", status = case })
    elseif case == "task_event" then h.emit("TaskStatusChanged", { session_id = "s1", id = "t", status = "working" })
    elseif case == "task_snapshot" then h.sessions.s1.tasks[2] = { id = "t", status = "working" }
    elseif case == "cwd" then h.sessions.s1.cwd = "/other"
    elseif case == "plan" then h.sessions.s1.mode = "plan" end
    h.drain(); h.tick(); eq(h.created, 0); eq(h.saved().status, "interrupted")
  end)
end

for _, reason in ipairs({ "cancelled", "max_tokens", "max_turns", "dropped" }) do
  test("abnormal ending " .. reason, function()
    local h = started(); h.finish(reason); h.tick()
    eq(h.saved().status, "interrupted"); eq(h.created, 0)
  end)
end

for _, event in ipairs({ "TurnError", "SessionReset", "SessionEnd" }) do
  test("abnormal lifecycle " .. event, function()
    local h = started()
    h.emit(event, { session_id = "s1", reason = "load", message = "provider failed" })
    h.drain(); h.finish(); h.tick(); eq(h.created, 0); eq(h.saved().status, "interrupted")
  end)
end

test("turn error without a message still interrupts", function()
  local h = started()
  h.emit("TurnError", { session_id = "s1" })
  h.drain()
  eq(h.saved().status, "interrupted")
  assert(h.notes[#h.notes]:find("unknown", 1, true))
end)

test("SessionReset without a reason interrupts with the event name", function()
  local h = started()
  h.emit("SessionReset", { session_id = "s1" })
  h.drain()
  eq(h.saved().status, "interrupted")
  assert(h.saved().reason:find("SessionReset", 1, true))
end)

for _, reason in ipairs({ "reset", "load", "delete" }) do
  test("session end " .. reason .. " interrupts only the loop session", function()
    local h = started()
    h.emit("SessionEnd", { session_id = "other", reason = reason })
    h.drain()
    eq(h.saved().status, "running")
    h.emit("SessionEnd", { session_id = "s1", reason = reason })
    h.drain()
    eq(h.saved().status, "interrupted")
  end)
end

test("stopped subagent does not block handoff", function()
  local h = started()
  h.emit("TaskStatusChanged", { session_id = "s1", id = "sub", status = "working" })
  h.finish()
  h.emit("TaskStopped", { session_id = "s1", id = "sub" })
  h.tick()
  eq(h.created, 1); eq(#h.prompts, 2)
end)

test("idle subagent blocks handoff", function()
  local h = started()
  h.sessions.s1.tasks[2] = { id = "t", status = "idle" }
  h.finish(); h.tick()
  eq(h.created, 0)
  eq(h.saved().status, "interrupted")
  assert(h.saved().reason:find("Active subagent", 1, true))

  local changed = started()
  changed.emit("TaskStatusChanged", { session_id = "s1", id = "t", status = "idle" })
  changed.drain(); changed.finish(); changed.tick()
  eq(changed.created, 0)
  eq(changed.saved().status, "interrupted")
  assert(changed.saved().reason:find("Active subagent", 1, true))

  for _, status in ipairs({ "done", "cancelled" }) do
    local finished = started()
    finished.emit("TaskStatusChanged", { session_id = "s1", id = "t", status = status })
    finished.drain(); finished.finish(); finished.tick()
    eq(finished.created, 1); eq(#finished.prompts, 2)
  end
end)

test("finished task in the task list does not block handoff", function()
  local h = started()
  h.sessions.s1.tasks[#h.sessions.s1.tasks + 1] = { id = "t", status = "done" }
  h.finish(); h.tick()
  eq(h.created, 1); eq(#h.prompts, 2); eq(h.saved().status, "running")
end)

test("capture is skipped when an active subagent blocks handoff", function()
  local h = started(); h.finish()
  h.calls.plan, h.calls.messages, h.calls.metadata, h.calls.fs_read = nil, nil, nil, nil
  h.sessions.s1.tasks[2] = { id = "t", status = "working" }
  h.tick()
  eq(h.created, 0); eq(h.saved().status, "interrupted")
  eq(h.calls.plan, nil); eq(h.calls.messages, nil)
  assert(h.saved().reason:find("Active subagent", 1, true))
end)

test("failed deferred handoff can resume", function()
  local h = started(); h.finish()
  h.fail.focus = "focus down"
  h.tick()
  eq(h.saved().starting, nil)
  eq(h.saved().status, "interrupted")
  h.fail.focus = nil
  h.command("loop-resume"); eq(h.created, 1)
  assert(not h.complete("done").is_error)
end)

test("aborted initial launch clears persisted starting", function()
  local h = host()
  h.sessions.s1.status = "working"
  h.fail.new = "new down"
  h.command("loop", "objective")
  eq(h.created, 0); eq(#h.prompts, 0)
  local persisted = false
  for key, value in pairs(h.json) do
    if type(key) == "string" and type(value) == "table" and value.starting == true then persisted = true end
  end
  assert(persisted, "starting was not persisted before new")
  eq(h.saved().starting, nil)
  eq(h.saved().status, "interrupted")
  assert(h.saved().reason:find("new down", 1, true))
  h.fail.new = nil
  h.sessions.s1.status = "idle"
  h.command("loop-resume")
  eq(h.created, 1); eq(#h.prompts, 1)
  assert(not h.complete("done").is_error)
end)

-- Arm h.fail[point] on the nth call of that host point, so a failure meant for
-- the handoff is not consumed by the initial session read in start().
local function fail_on(h, point, nth)
  h.hook = function(name)
    if name == point and h.calls[point] == nth then h.fail[point] = "injected " .. point end
  end
end

for _, case in ipairs({
  { name = "focus", point = "focus", nth = 1 },
  { name = "current", point = "current", nth = 2 },
  { name = "read", point = "read", nth = 2 },
  { name = "model", point = "model", nth = 1 },
}) do
  test("initial launch handoff failure " .. case.name .. " is resumable", function()
    local h = host()
    h.sessions.s1.mode = "plan"  -- forces initial=true through the handoff
    fail_on(h, case.point, case.nth)
    h.command("loop", "objective")
    eq(h.created, 0); eq(#h.prompts, 0)
    eq(h.saved().starting, nil)
    eq(h.saved().status, "interrupted")
    assert(h.saved().reason:find("injected " .. case.point, 1, true))
    h.fail[case.point] = nil
    h.sessions.s1.mode = "build"
    h.command("loop-resume")
    eq(h.created, 1); eq(#h.prompts, 1)
    eq(h.saved().starting, nil)
    assert(not h.complete("done").is_error)
  end)
end

-- Host-wide teardown is not owner-scoped: any session id marks the loop dead.
for _, reason in ipairs({ "shutdown", "reload" }) do
  for _, session in ipairs({ "other", "s1" }) do
    test("filesystem-only teardown " .. reason .. " from " .. session, function()
      local h = started(); h.finish()
      h.detached = true
      h.emit("SessionEnd", { session_id = session, reason = reason, deadline_ms = 100 })
      h.drain(); h.tick(); eq(h.saved().status, "interrupted"); eq(h.created, 0)
    end)
  end
end

-- `replaced`/`completed` only matter when the loop's own session ends, and the
-- pending rollover legitimately continues afterwards, so nothing notifies.
for _, reason in ipairs({ "replaced", "completed" }) do
  test("teardown " .. reason .. " from other keeps the loop running", function()
    local h = started(); h.finish()
    h.emit("SessionEnd", { session_id = "other", reason = reason, deadline_ms = 100 })
    h.drain()
    eq(h.saved().status, "rollover_pending")
    h.tick()
    eq(h.saved().status, "running"); eq(h.created, 1); eq(#h.prompts, 2)
  end)

  test("teardown " .. reason .. " from the owner interrupts", function()
    local h = started(); h.finish()
    h.detached = true
    h.emit("SessionEnd", { session_id = "s1", reason = reason, deadline_ms = 100 })
    h.drain(); h.tick()
    eq(h.saved().status, "interrupted"); eq(h.created, 0)
    assert(h.saved().reason:find(reason, 1, true))
  end)
end

test("teardown replaced after rollover does not interrupt the new owner", function()
  local h = started(); h.finish(); h.tick()
  eq(h.saved().owner, "n1"); eq(h.saved().status, "running")
  h.emit("SessionEnd", { session_id = "s1", reason = "replaced", deadline_ms = 100 })
  h.drain(); h.tick()
  eq(h.saved().status, "running"); eq(h.created, 1); eq(#h.prompts, 2)
  h.finish(); h.tick()
  eq(h.created, 2); eq(h.saved().iteration, 3)
end)

test("teardown completed from the armed resume parent interrupts", function()
  local h = started(); h.command("loop-stop")
  h.sessions.s1.status = "working"
  h.command("loop-resume")
  eq(h.saved().resume_parent, "s1")
  h.emit("SessionEnd", { session_id = "s1", reason = "completed", deadline_ms = 100 })
  h.drain(); h.tick()
  eq(h.saved().status, "interrupted"); eq(h.created, 0); eq(#h.prompts, 1)
  assert(h.saved().reason:find("completed", 1, true))
end)

test("teardown replaced from the rollover owner interrupts", function()
  local h = started(); h.finish(); h.tick()
  eq(h.saved().owner, "n1"); eq(h.saved().status, "running")
  h.detached = true
  h.emit("SessionEnd", { session_id = "n1", reason = "replaced", deadline_ms = 100 })
  h.drain(); h.tick()
  eq(h.saved().status, "interrupted"); eq(h.created, 1); eq(#h.prompts, 2)
  assert(h.saved().reason:find("replaced", 1, true))
end)

test("teardown replaced from the armed resume parent interrupts", function()
  local h = started(); h.command("loop-stop")
  h.sessions.s1.status = "working"
  h.command("loop-resume")
  eq(h.saved().resume_parent, "s1")
  h.emit("SessionEnd", { session_id = "s1", reason = "replaced", deadline_ms = 100 })
  h.drain(); h.tick()
  eq(h.saved().status, "interrupted"); eq(h.created, 0); eq(#h.prompts, 1)
  assert(h.saved().reason:find("replaced", 1, true))
end)

test("teardown replaced from other does not latch closed", function()
  local h = started(); h.finish()
  h.emit("SessionEnd", { session_id = "other", reason = "replaced", deadline_ms = 100 })
  h.drain(); h.tick()
  eq(h.created, 1)
  h.command("loop-stop")
  eq(h.saved().status, "stopped")
  h.sessions[h.focus].status = "idle"
  h.command("loop-resume"); eq(h.created, 2); eq(#h.prompts, 3)
end)

test("teardown persists without acquiring the write semaphore", function()
  local h = started(); h.finish()
  h.detached = true
  h.no_permit = true
  h.acquired = 0
  h.emit("SessionEnd", { session_id = "other", reason = "reload", deadline_ms = 100 })
  h.drain(); h.tick()
  eq(h.acquired, 0)
  eq(h.saved().status, "interrupted")
end)

for _, failure in ipairs({ "mkdir", "write", "encode", "new", "focus", "model", "tasks", "read", "prompt" }) do
  test("failure prevents retries " .. failure, function()
    local h = started(); h.finish()
    h.fail[failure] = "injected " .. failure
    h.tick()
    h.fail[failure] = nil
    h.emit("SessionStatusChanged", { session_id = h.focus, status = "idle" })
    h.drain(); h.tick()
    eq(#h.prompts, 1)
    h.command("loop-status")
    assert(h.notes[#h.notes]:find("interrupted", 1, true))
  end)
end

for _, failure in ipairs({ "mkdir", "write", "encode", "prompt" }) do
  test("initial launch failure " .. failure, function()
    local h = host(); h.fail[failure] = "failure"; h.command("loop", "work")
    eq(#h.prompts, 0); h.tick(); eq(h.created, 0)
  end)
end

test("queued prompt interrupts", function()
  local h = host(); h.prompt_result = "queued"; h.command("loop", "work")
  eq(h.saved().status, "interrupted"); h.finish(); h.tick(); eq(h.created, 0)
end)

test("failed completion write never reports success, retry is durable", function()
  local h = started(); h.fail.write = "disk full"
  eq(h.complete("done", "s1").is_error, true)
  h.finish(); h.tick(); eq(h.created, 0)
  h.fail.write = nil
  assert(not h.complete("done", "s1").is_error)
  eq(h.saved().status, "completed")
end)

test("reload requires resume, project isolation and normalized keys", function()
  local h = started()
  local next = host(h.files, h.json)
  next.command("loop-status")
  eq(next.saved().status, "interrupted"); next.tick(); eq(#next.prompts, 0)
  next.cwd = "/project/./child/.."
  next.command("loop-resume"); eq(next.created, 1)
  next.command("loop-stop"); next.sessions[next.focus].status = "idle"
  next.cwd = "/different"; next.sessions[next.focus].cwd = "/different"
  next.command("loop-resume"); eq(next.created, 1)
  next.command("loop", "separate")
  eq(#next.prompts, 2)
  eq(next.saved().objective, "separate")
  next.cwd = "/project/./child/.."
  eq(next.saved().objective, "do the work")
  eq(next.saved().status, "stopped")
  next.cwd = "/missing"
  eq(next.saved(), nil)
  local n = 0; for path in pairs(next.files) do n = n + 1; assert(not path:find("/project", 1, true)) end
  eq(n, 2)
end)

test("JSON null optional state fields retain nil semantics on reload", function()
  local h = started()
  local _, text = next(h.files)
  local s = h.json[text]
  s.reason, s.resume_parent, s.summary = null, null, null
  local reload = host(h.files, h.json)
  reload.command("loop-status")
  eq(reload.saved().status, "interrupted")
  eq(reload.saved().resume_parent, nil)
  eq(reload.saved().summary, nil)
  reload.command("loop-resume")
  eq(reload.created, 1)
  eq(#reload.prompts, 1)
  assert(not reload.complete("done").is_error)
end)

test("old state without context fields still resumes", function()
  local h = started()
  local _, text = next(h.files)
  local s = h.json[text]
  s.origin, s.plan, s.carry, s.capture_note = nil, nil, nil, nil
  local reload = host(h.files, h.json)
  reload.command("loop-status")
  assert(not reload.notes[#reload.notes]:find("Corrupt", 1, true))
  reload.command("loop-resume")
  eq(reload.created, 1); eq(#reload.prompts, 1)
end)

test("JSON null context fields are dropped on reload", function()
  local h = started()
  h.plans.s1 = { mode = "plan", ready = true, path = "/state/plans/null.md", content = "# null plan" }
  h.messages.s1 = messages_with_tasks(1)
  h.finish(); h.tick()
  eq(h.created, 1); eq(h.saved().plan.path, "/state/plans/null.md")
  local s = h.json[h.files[h.state_path()]]
  s.origin, s.plan, s.carry, s.capture_note = null, null, null, null
  local reload = host(h.files, h.json)
  reload.command("loop-status")
  eq(reload.saved().status, "interrupted")
  eq(reload.saved().plan, nil); eq(reload.saved().carry, nil); eq(reload.saved().capture_note, nil)
  eq(reload.saved().origin, "s1")
  reload.command("loop-resume")
  eq(reload.created, 1); eq(#reload.prompts, 1)
  assert(not reload.complete("done").is_error)
end)

test("oversized stored plan is clipped on reload and stays valid UTF-8", function()
  local h = started()
  local content = string.rep("あ", 30000)
  assert(#content > 65536)
  local s = h.json[h.files[h.state_path()]]
  s.plan = { path = "/state/plans/big.md", content = content, captured_iteration = 1 }
  local reload = host(h.files, h.json)
  reload.command("loop-status")
  eq(reload.saved().status, "interrupted")
  local saved = reload.saved().plan.content
  assert(#saved <= 65536, "plan length " .. #saved)
  assert(valid_utf8(saved), "clipped plan is valid UTF-8")
  assert(saved:find("…(truncated)", 1, true), "truncation marker")
  reload.command("loop-resume")
  eq(reload.created, 1); eq(#reload.prompts, 1)
  assert(valid_utf8(reload.prompts[1].text))
end)

test("reload clips oversized plan path and carry task id before prompting", function()
  local h = started()
  local _, text = next(h.files)
  local s = h.json[text]
  local long_id = string.rep("i", 5000)
  s.plan = { path = string.rep("p", 5000), content = "# capped plan", captured_iteration = 1 }
  s.carry = { from_iteration = 1, session = "s1", summary = "stored summary",
    tasks = { { id = long_id, label = "capped label", text = "stored body" } } }
  local reload = host(h.files, h.json)
  reload.command("loop-status")
  eq(reload.saved().status, "interrupted")
  assert(#reload.saved().plan.path <= 1024, "stored plan path length " .. #reload.saved().plan.path)
  assert(#reload.saved().carry.tasks[1].id <= 200, "stored task id length " .. #reload.saved().carry.tasks[1].id)
  assert(not reload.saved().plan.path:find("\n", 1, true), "clipped path is single-line")
  assert(not reload.saved().carry.tasks[1].id:find("\n", 1, true), "clipped id is single-line")
  -- The digest rebuilds the carry from the parent transcript, so give it the
  -- same oversized id and let the transcript path apply the cap too.
  reload.messages.s1 = {
    { role = "assistant", content = { { type = "tool_use", id = long_id, name = "task", input = { description = "capped label" } } } },
    { role = "user", content = { { type = "tool_result", tool_use_id = long_id, content = "fresh body" } } },
    { role = "assistant", content = { { type = "text", text = "fresh summary" } } },
  }
  reload.command("loop-resume")
  eq(reload.created, 1); eq(#reload.prompts, 1)
  local saved = reload.saved()
  assert(#saved.plan.path <= 1024, "resumed plan path length " .. #saved.plan.path)
  assert(#saved.carry.tasks[1].id <= 200, "resumed task id length " .. #saved.carry.tasks[1].id)
  local prompt = reload.prompts[1].text
  for run in prompt:gmatch("p+") do assert(#run <= 1024, "prompt path run " .. #run) end
  for run in prompt:gmatch("i+") do assert(#run <= 200, "prompt id run " .. #run) end
  assert(prompt:find(saved.plan.path, 1, true), "prompt carries the clipped plan path")
end)

test("malformed context fields are dropped, not fatal", function()
  local h = started()
  local _, text = next(h.files)
  local s = h.json[text]
  s.origin, s.capture_note = nil, string.rep("n", 500)
  s.plan = { path = "", content = 5 }
  s.carry = { tasks = "bad" }
  local reload = host(h.files, h.json)
  reload.command("loop-status")
  local note = reload.notes[#reload.notes]
  assert(not note:find("Corrupt", 1, true))
  local saved_note = reload.saved().capture_note
  assert(saved_note and #saved_note <= 300, "capture note length " .. tostring(saved_note and #saved_note))
  assert(saved_note:find("…(truncated)", 1, true), "capture note marker")
  assert(note:find(saved_note, 1, true), "status shows the clipped capture note")
  eq(reload.saved().plan, nil); eq(reload.saved().carry, nil)
  reload.command("loop-resume")
  eq(reload.created, 1); eq(#reload.prompts, 1)
end)

test("wrong-typed optional context fields are dropped, not corrupt", function()
  local h = started()
  local _, text = next(h.files)
  local s = h.json[text]
  s.origin, s.plan, s.carry, s.capture_note = {}, 5, "bad", {}
  local reload = host(h.files, h.json)
  reload.command("loop-status")
  assert(not reload.notes[#reload.notes]:find("Corrupt", 1, true))
  local saved = reload.saved()
  eq(saved.origin, "s1")
  eq(saved.plan, nil); eq(saved.carry, nil); eq(saved.capture_note, nil)
  reload.command("loop-resume"); eq(reload.created, 1)
end)

test("a throwing state encoder drops captured context instead of wedging", function()
  local h = started()
  h.plans.s1 = { mode = "plan", ready = true, path = "/state/plans/boom.md", content = "# boom" }
  h.finish()
  h.fail_encode_once = function() error("encode boom") end
  h.tick()
  eq(h.created, 1); eq(#h.prompts, 2)
  local saved = h.saved()
  eq(saved.plan, nil); eq(saved.carry, nil)
  eq(saved.capture_note, "context dropped: state encode failed")
  eq(saved.status, "running")
end)

test("origin is backfilled from id and used as a plan source", function()
  local h = started()
  local _, text = next(h.files)
  local s = h.json[text]
  s.origin, s.id = nil, "s1:123"
  local reload = host(h.files, h.json)
  reload.sessions.s2 = copy(reload.sessions.s1)
  reload.sessions.s2.id, reload.sessions.s2.status = "s2", "idle"
  reload.focus = "s2"
  reload.plans.s1 = { mode = "plan", ready = true, path = "/state/plans/origin.md", content = "# from origin" }
  reload.command("loop-status")
  eq(reload.saved().origin, "s1")
  reload.command("loop-resume")
  eq(reload.created, 1); eq(#reload.prompts, 1)
  assert(reload.prompts[1].text:find("/state/plans/origin.md", 1, true))
  assert(reload.prompts[1].text:find("# from origin", 1, true))
end)

-- The real host errors for an unknown session; capture must note it and keep
-- rolling over instead of aborting the handoff.
test("capture tolerates a vanished origin session", function()
  local h = started()
  local _, text = next(h.files)
  h.json[text].origin = "gone"
  local reload = host(h.files, h.json)
  eq(reload.sessions.gone, nil)
  reload.command("loop-status")
  reload.command("loop-resume")
  eq(reload.created, 1); eq(#reload.prompts, 1)
  eq(reload.saved().status, "running")
  assert(reload.saved().capture_note:find("not live", 1, true), "unknown session note")
  assert(not reload.complete("done").is_error)
end)

for _, field in ipairs({ "root", "objective", "sessions", "record", "summary" }) do
  test("reject JSON null in required state " .. field, function()
    local h = started()
    local _, text = next(h.files)
    local s = h.json[text]
    if field == "root" then h.json[text] = null
    elseif field == "record" then s.sessions[1] = null
    elseif field == "summary" then s.status, s.summary = "completed", null
    else s[field] = null end
    local reload = host(h.files, h.json)
    reload.command("loop-resume"); reload.tick()
    eq(#reload.prompts, 0); eq(reload.created, 0)
    assert(reload.notes[#reload.notes]:find("Corrupt", 1, true) or reload.notes[#reload.notes]:find("Invalid", 1, true))
  end)
end

test("JSON null in a trailing iteration slot is rejected, not dropped", function()
  local h = started()
  local _, text = next(h.files)
  h.json[text].sessions[2] = null
  local reload = host(h.files, h.json)
  reload.command("loop-resume"); reload.tick()
  eq(#reload.prompts, 0); eq(reload.created, 0)
  assert(reload.notes[#reload.notes]:find("Invalid iteration records", 1, true))
end)

for _, corrupt in ipairs({ "json", "version", "owner", "cost", "objective", "records", "summary", "cwd", "resume_parent",
  "sparse", "object", "mixed", "zero", "negative", "fractional", "extra", "empty" }) do
  test("reject corrupt state " .. corrupt, function()
    local h = started()
    local path, text = next(h.files)
    local s = h.json[text]
    if corrupt == "json" then h.files[path] = "broken"
    elseif corrupt == "version" then s.version = 99
    elseif corrupt == "owner" then s.owner = "wrong"
    elseif corrupt == "resume_parent" then s.resume_parent = {}
    elseif corrupt == "cost" then s.cost = -1
    elseif corrupt == "objective" then s.objective = " "
    elseif corrupt == "records" then s.sessions[1].iteration = 3
    elseif corrupt == "sparse" then s.sessions[3] = copy(s.sessions[1])
    elseif corrupt == "object" then s.sessions = { ["1"] = s.sessions[1] }
    elseif corrupt == "mixed" then s.sessions.hidden = copy(s.sessions[1])
    elseif corrupt == "zero" then s.sessions[0] = copy(s.sessions[1])
    elseif corrupt == "negative" then s.sessions[-1] = copy(s.sessions[1])
    elseif corrupt == "fractional" then s.sessions[1.5] = copy(s.sessions[1])
    elseif corrupt == "extra" then s.sessions[2] = copy(s.sessions[1])
    elseif corrupt == "empty" then s.sessions = {}
    elseif corrupt == "summary" then s.status, s.summary = "completed", nil
    elseif corrupt == "cwd" then s.cwd = "/wrong" end
    local reload = host(h.files, h.json)
    reload.command("loop-resume"); reload.tick(); eq(#reload.prompts, 0); eq(reload.created, 0)
    reload.command("loop", "new objective")
    eq(#reload.prompts, 1); eq(reload.saved().objective, "new objective")
    eq(reload.saved().status, "running")
  end)
end

for _, field in ipairs({ "spec", "thinking", "fast", "mode", "cwd" }) do
  test("inheritance mismatch " .. field, function()
    local h = started(); h.finish()
    h.new_mutate = function(s)
      if field == "mode" then s.mode = "plan"
      elseif field == "cwd" then s.cwd = "/other"
      elseif field == "fast" then s.settings.fast = true
      else s.settings[field] = "different" end
    end
    h.tick(); eq(#h.prompts, 1); eq(h.saved().status, "interrupted")
  end)
end

for _, action in ipairs({ "stop", "complete", "teardown" }) do
  for _, point in ipairs({ "read", "focus", "current", "tasks", "model", "new", "mkdir", "write", "prompt" }) do
    test("race " .. action .. " at " .. point, function()
      local h = started(); h.finish()
      local fired = false
      h.hook = function(name)
        if fired or name ~= point then return end
        fired = true
        if action == "stop" then h.spawn(function() h.commands["loop-stop"].handler({}) end)
        elseif action == "complete" then h.spawn(function()
          h.tools.loop_complete.handler({ summary = "done" }, { session_id = function() return h.created > 0 and "n1" or "s1" end, task_id = function() return "main" end })
        end)
        else h.emit("SessionEnd", { session_id = "s1", reason = "reload" }) end
      end
      h.tick(); h.tick()
      if point ~= "prompt" then eq(#h.prompts, 1) end
      assert(h.created <= 1)
      h.command("loop-status")
      if action == "stop" then eq(h.saved().status, "stopped") end
    end)
  end
end

test("idle event arriving during handoff read is not lost", function()
  local h = started(); h.finish("finished", "working")
  local original = maki.session.read
  local once = false
  maki.session.read = function(opts)
    if not once then
      once = true
      local snapshot = copy(h.sessions[opts.session])
      h.sessions.s1.status = "idle"
      h.emit("SessionStatusChanged", { session_id = "s1", status = "idle" })
      coroutine.yield("yield")
      return snapshot
    end
    return original(opts)
  end
  h.tick(); h.tick(); eq(h.created, 1)
end)

test("stop while initial command is reading prevents launch", function()
  local h = host()
  local fired = false
  h.hook = function(name)
    if name == "read" and not fired then
      fired = true
      h.spawn(function() h.commands["loop-stop"].handler({}) end)
    end
  end
  h.command("loop", "work"); h.tick(); eq(#h.prompts, 0)
end)

test("queued user input arriving during model inspection is preserved", function()
  local h = started(); h.finish()
  h.hook = function(name) if name == "model" then h.sessions.s1.queue.count = 1 end end
  h.tick(); eq(h.created, 0); eq(h.sessions.s1.queue.count, 1)
end)

print(string.format("PASS: %d deterministic tests", count))
