-- Browz Forever : transport invisible entre membres (messages d'addon GUILD, découpés en morceaux)
local _, BF = ...

local PREFIX = "BrowzF"
local CHUNK = 220
local queue = {}
local handlers = {}
local partial = {}   -- [sender..id] = { n=, got=, parts={}, t= }
local seq = 0

function BF.OnMessage(kind, fn)            -- plusieurs modules peuvent écouter le même type
  handlers[kind] = handlers[kind] or {}
  table.insert(handlers[kind], fn)
end

local function isOk(res)
  return res == nil or res == true or res == 0
    or (Enum and Enum.SendAddonMessageResult and res == Enum.SendAddonMessageResult.Success)
end

local ticker
local function pump()
  local item = queue[1]
  if not item then ticker:Cancel(); ticker = nil; return end
  local res = C_ChatInfo.SendAddonMessage(PREFIX, item.msg, item.channel or "GUILD", item.target)
  if isOk(res) then
    table.remove(queue, 1)
  else
    item.tries = (item.tries or 0) + 1
    if item.tries > 40 then table.remove(queue, 1) end -- abandon après ~20 s de refus
  end
end

-- Envoie `data` (texte sans « ~ » au début des morceaux) à la guilde
function BF.Send(kind, data, channel, target)
  if not BF.active then return end
  seq = (seq + 1) % 100000
  local id = tostring(GetServerTime() % 100000) .. "." .. seq
  local n = math.max(1, math.ceil(#data / CHUNK))
  for i = 1, n do
    local part = data:sub((i - 1) * CHUNK + 1, i * CHUNK)
    queue[#queue + 1] = { msg = kind .. "~" .. id .. "~" .. i .. "~" .. n .. "~" .. part, channel = channel, target = target }
  end
  if not ticker then ticker = C_Timer.NewTicker(0.5, pump) end
end

function BF.QueueSize() return #queue end

local f = CreateFrame("Frame")
f:RegisterEvent("CHAT_MSG_ADDON")
f:SetScript("OnEvent", function(_, _, prefix, msg, _, sender)
  if prefix ~= PREFIX or not BF.active then return end
  if sender == BF.MyName() then return end -- nos propres messages reviennent : on les ignore
  local kind, id, i, n, part = msg:match("^([^~]+)~([^~]+)~(%d+)~(%d+)~(.*)$")
  if not kind then return end
  i, n = tonumber(i), tonumber(n)
  local key = sender .. "|" .. id
  local p = partial[key]
  if not p then p = { n = n, got = 0, parts = {}, t = GetTime() }; partial[key] = p end
  if not p.parts[i] then p.parts[i] = part; p.got = p.got + 1 end
  if p.got >= p.n then
    partial[key] = nil
    local data = table.concat(p.parts)
    for _, fn in ipairs(handlers[kind] or {}) do
      local ok, err = pcall(fn, data, sender)
      if not ok then BF.Debug("Erreur message " .. kind .. " : " .. tostring(err)) end
    end
  end
  -- ménage des messages incomplets de plus de 2 minutes
  for k, v in pairs(partial) do if GetTime() - v.t > 120 then partial[k] = nil end end
end)

C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
