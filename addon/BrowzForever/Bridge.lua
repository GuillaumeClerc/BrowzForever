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
BF.OnMessage("P", function()
  C_Timer.After(2 + math.random() * 5, function()
    for _, it in pairs(db().outbox) do
      if it.mine and not it.acked then BF.Send("E", it.data) end
    end
  end)
end)

local function announce() if Bridge.IsOn() then BF.Send("P", "1") end end
BF.OnActive(function()
  C_Timer.After(1, announce)   -- « un pont arrive » : les autres renvoient ce qui ne lui est pas parvenu
  if Bridge.IsOn() and LoggingChat and not LoggingChat() then pcall(LoggingChat, true) end
end)

BF.commands["pont"] = function(arg)
  arg = (arg or ""):lower()
  if arg == "on" then
    db().bridge = true
    if LoggingChat then pcall(LoggingChat, true) end
    BF.Print("Pont |cff00ff00activé|r : ce PC transmet les passages au coffre à Discord (journal de chat activé).")
    announce()
  elseif arg == "off" then
    db().bridge = false
    BF.Print("Pont |cffff4444désactivé|r.")
  else
    local pending = 0
    for _, it in pairs(db().outbox) do if it.mine and not it.acked then pending = pending + 1 end end
    BF.Print("Pont : " .. (Bridge.IsOn() and "|cff00ff00activé|r" or "désactivé") .. " | passages en attente d'un pont : " .. pending)
  end
end


-- Test : le chat Officier relié à Discord (/browz testofficier) -------------------------------------
-- 1) envoie une ligne de test dans le canal Officier 2 s plus tard, SANS clic (comme le ferait le pont) ;
-- 2) écoute pendant 2 minutes le canal Officier et affiche les messages venus de Discord (avec leurs infos)
--    pour savoir si le bot peut aussi parler au jeu.
local listenUntil = 0
local function sendChat2(msg)
  if C_ChatInfo and C_ChatInfo.SendChatMessage then C_ChatInfo.SendChatMessage(msg, "OFFICER")
  else SendChatMessage(msg, "OFFICER") end
end
local tf = CreateFrame("Frame")
tf:RegisterEvent("ADDON_ACTION_BLOCKED")
tf:RegisterEvent("ADDON_ACTION_FORBIDDEN")
tf:RegisterEvent("CHAT_MSG_OFFICER")
tf:RegisterEvent("CHAT_MSG_GUILD")
tf:SetScript("OnEvent", function(_, e, a1, a2, ...)
  if GetTime() > listenUntil then return end
  if e == "ADDON_ACTION_BLOCKED" or e == "ADDON_ACTION_FORBIDDEN" then
    BF.Print(("|cffff4444%s|r : %s / %s"):format(e, tostring(a1), tostring(a2)))
  else
    local args = { ... }
    -- a1 = texte, a2 = auteur ; on montre aussi les infos qui disent si le message vient de Discord
    BF.Print(("%s de %s : « %s » | guid=%s | infos : %s"):format(e == "CHAT_MSG_OFFICER" and "Officier" or "Guilde",
      tostring(a2), tostring(a1):sub(1, 60), tostring(args[10]), table.concat((function()
        local o = {} for i = 1, math.min(#args, 16) do o[#o + 1] = tostring(args[i]) end return o end)(), ",")))
  end
end)

BF.commands["testofficier"] = function()
  listenUntil = GetTime() + 120
  BF.Print("Test : une ligne part dans le canal |cff40ff40Officier|r dans 2 s, sans clic. Regarde si elle arrive sur Discord.")
  BF.Print("Pendant 2 min, écris aussi un message dans le salon Discord relié : je l'afficherai ici avec ses infos.")
  C_Timer.After(2, function()
    local ok, err = pcall(sendChat2, "BRWZ1 TEST " .. date("%H:%M:%S") .. " (ligne automatique de l'addon Browz)")
    BF.Print(ok and "Ligne envoyée (si aucun message rouge ADDON_ACTION_BLOCKED : le jeu l'a acceptée)."
      or ("|cffff4444Envoi refusé :|r " .. tostring(err)))
  end)
end

-- Test : canaux de communauté / guilde (/browz testclub, puis /browz testclub <n>) --------------------------
-- Liste les communautés et leurs canaux (dont un éventuel canal « Discord » séparé), puis envoie une ligne
-- de test dans le canal n° n, 2 s plus tard et sans clic.
local streamsList = {}
BF.commands["testclub"] = function(arg)
  if not (C_Club and C_Club.GetSubscribedClubs) then BF.Print("C_Club absent."); return end
  local n = tonumber(arg or "")
  if not n then
    wipe(streamsList)
    for _, club in ipairs(C_Club.GetSubscribedClubs() or {}) do
      for _, st in ipairs(C_Club.GetStreams(club.clubId) or {}) do
        streamsList[#streamsList + 1] = { club = club.clubId, stream = st.streamId }
        BF.Print(("%d) %s — %s (type de canal %s, type de communauté %s)"):format(#streamsList, tostring(club.name),
          tostring(st.name), tostring(st.streamType), tostring(club.clubType)))
      end
    end
    BF.Print("Tape |cffffd100/browz testclub <numéro>|r pour envoyer une ligne de test dans ce canal (sans clic).")
    return
  end
  local s = streamsList[n]
  if not s then BF.Print("Numéro inconnu : tape d'abord /browz testclub."); return end
  listenUntil = GetTime() + 120
  C_Timer.After(2, function()
    local ok, err = pcall(C_Club.SendMessage, s.club, s.stream, "BRWZ1 TEST " .. date("%H:%M:%S") .. " (ligne automatique Browz)")
    BF.Print(ok and "Ligne envoyée (si aucun message rouge ADDON_ACTION_BLOCKED : acceptée)." or ("|cffff4444Refusé :|r " .. tostring(err)))
  end)
end
