-- Browz Forever : passages au coffre → pont (PC qui envoie à Discord)
-- Sortie 1 : chuchotements à soi-même (écrits dans Logs\WoWChatLog.txt si /chatlog est actif)
-- Sortie 2 : BrowzForeverDB.outbox (écrit sur le disque au /reload, à la déconnexion ou en quittant)
local _, BF = ...
local Bridge = {}
BF.Bridge = Bridge

local TAG = "BRWZ1"
local LINE = 200
local MAX_OUTBOX = 300

local function db() return BrowzForeverDB end
function Bridge.IsOn() return db() and db().bridge end

-- File de chuchotements (1 par seconde pour ne pas déclencher l'anti-spam)
local wqueue, wticker, lineSeq = {}, nil, 0
local function sendChat(msg, target)
  if C_ChatInfo and C_ChatInfo.SendChatMessage then C_ChatInfo.SendChatMessage(msg, "WHISPER", nil, target)
  else SendChatMessage(msg, "WHISPER", nil, target) end
end
local function wpump()
  local msg = table.remove(wqueue, 1)
  if not msg then wticker:Cancel(); wticker = nil; return end
  pcall(sendChat, msg, BF.MyName())
end
local function emitLine(kind, data)
  if LoggingChat and not LoggingChat() then pcall(LoggingChat, true) end
  lineSeq = (lineSeq + 1) % 10000
  -- découpage sans couper un caractère accentué (UTF-8) en deux
  local chunks, pos = {}, 1
  while pos <= #data do
    local stop = math.min(pos + LINE - 1, #data)
    while stop < #data and stop > pos do
      local b = data:byte(stop + 1)
      if b < 0x80 or b >= 0xC0 then break end
      stop = stop - 1
    end
    chunks[#chunks + 1] = data:sub(pos, stop)
    pos = stop + 1
  end
  for i, c in ipairs(chunks) do
    wqueue[#wqueue + 1] = ("%s %s %d %d %d %s"):format(TAG, kind, lineSeq, i, #chunks, c)
  end
  if not wticker then wticker = C_Timer.NewTicker(1, wpump) end
end

Bridge.Emit = function(kind, data) emitLine(kind, data) end

-- Cacher ces chuchotements des fenêtres de chat
local function hide(_, _, msg) return type(msg) == "string" and msg:sub(1, #TAG) == TAG end
if ChatFrame_AddMessageEventFilter then
  ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER", hide)
  ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER_INFORM", hide)
end

-- Boîte d'envoi ------------------------------------------------------------------------
local function store(e, ser, mine)
  local ob = db().outbox
  if ob[e.id] then return false end
  ob[e.id] = { data = ser, t = e.t, mine = mine, acked = false, at = GetServerTime() }
  -- ménage : on garde au plus MAX_OUTBOX passages, les plus récents
  local keys = {}
  for k, v in pairs(ob) do keys[#keys + 1] = { k = k, t = v.t or 0 } end
  if #keys > MAX_OUTBOX then
    table.sort(keys, function(a, b) return a.t < b.t end)
    for i = 1, #keys - MAX_OUTBOX do ob[keys[i].k] = nil end
  end
  return true
end

local function forward(e, ser)
  emitLine("E", ser)
  BF.Send("A", e.id) -- accusé de réception : l'auteur peut oublier ce passage
end

-- Nouveau passage au coffre (le mien si mine = true)
function Bridge.NewEvent(e, mine)
  local ser = BF.Bank.SerializeEvent(e)
  store(e, ser, mine)
  if mine then BF.Send("E", ser) end
  if Bridge.IsOn() then
    db().outbox[e.id].acked = true
    emitLine("E", ser)
  end
end

BF.OnMessage("E", function(data)
  if not Bridge.IsOn() then return end
  local e = BF.Bank.ParseEvent(data)
  if not e then return end
  if store(e, data, false) then db().outbox[e.id].acked = true; forward(e, data)
  else BF.Send("A", e.id) end
end)

BF.OnMessage("A", function(id)
  local it = db().outbox[id]
  if it then it.acked = true end
end)

-- « P » = un pont vient d'arriver : on lui renvoie nos passages pas encore confirmés
BF.OnMessage("P", function(_, sender)
  BF.SeenBridge(sender)
  C_Timer.After(2 + math.random() * 5, function()
    for _, it in pairs(db().outbox) do
      if it.mine and not it.acked then BF.Send("E", it.data) end
    end
  end)
end)

local function announce() if Bridge.IsOn() then BF.Send("P", "1") end end

-- Pont automatique : le client Browz (v16+) réécrit BrowzForever_Inbox au moins toutes les 12 h avec « client » et
-- la date. Récent (< 3 jours) = le client tourne sur ce PC → pont activé tout seul (sauf « /browz pont off »).
-- Plus rien depuis 7 jours alors que c'est l'automatique qui l'avait activé → pont coupé.
local function autoBridge()
  local inbox = _G.BrowzForeverInbox
  local age = inbox and inbox.client and inbox.t and inbox.t > 0 and (GetServerTime() - inbox.t) or nil
  if age and age < 3 * 86400 then
    if not Bridge.IsOn() and db().bridgeAuto ~= false then
      db().bridge, db().bridgeByAuto = true, true
      if LoggingChat then pcall(LoggingChat, true) end
      BF.Print("Client Browz détecté sur ce PC : |cff00ff00pont activé automatiquement|r (« /browz pont off » pour le couper).")
    end
  elseif db().bridgeByAuto and Bridge.IsOn() and (not age or age > 7 * 86400) then
    db().bridge, db().bridgeByAuto = false, nil
    BF.Print("Le client Browz ne tourne plus sur ce PC depuis une semaine : pont désactivé.")
  end
end

BF.OnActive(function()
  pcall(autoBridge)
  C_Timer.After(1, announce)   -- « un pont arrive » : les autres renvoient ce qui ne lui est pas parvenu
  if Bridge.IsOn() and LoggingChat and not LoggingChat() then pcall(LoggingChat, true) end
end)

BF.commands["pont"] = function(arg)
  arg = (arg or ""):lower()
  if arg == "on" then
    db().bridge, db().bridgeAuto, db().bridgeByAuto = true, nil, nil
    if LoggingChat then pcall(LoggingChat, true) end
    BF.Print("Pont |cff00ff00activé|r : ce PC transmet les passages au coffre à Discord (journal de chat activé).")
    announce()
  elseif arg == "off" then
    db().bridge, db().bridgeAuto, db().bridgeByAuto = false, false, nil   -- l'automatique ne le rallume plus
    BF.Print("Pont |cffff4444désactivé|r.")
  else
    local pending = 0
    for _, it in pairs(db().outbox) do if it.mine and not it.acked then pending = pending + 1 end end
    BF.Print("Pont : " .. (Bridge.IsOn() and "|cff00ff00activé|r" or "désactivé") .. " | passages en attente d'un pont : " .. pending)
  end
end
