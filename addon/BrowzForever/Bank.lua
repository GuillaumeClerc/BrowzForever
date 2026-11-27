-- Browz Forever : banque de guilde (scan au coffre, différences à la fermeture, partage)
local _, BF = ...
local Bank = {}
BF.Bank = Bank

local MONEY_TAB = (MAX_GUILDBANK_TABS or 8) + 1
local SLOTS = MAX_GUILDBANK_SLOTS_PER_TAB or 98

local function clean(s) return (tostring(s or ""):gsub("[%^#@;,~|]", " ")) end
local function cleanName(s) return (tostring(s or ""):gsub("[%^#@;=~|]", " ")) end

-- Catalogue des objets (nom français, qualité, catégorie, icône) pour le bot Discord
local waiting = {}
function Bank.Remember(id)
  if not id or not BrowzForeverDB then return end
  local cat = BrowzForeverDB.items
  if cat[id] and cat[id].n then return cat[id] end
  local name, _, quality = C_Item.GetItemInfo(id)
  local _, _, _, _, icon, classID = C_Item.GetItemInfoInstant(id)
  if name then
    cat[id] = { n = name, q = quality, c = classID, i = icon }
    waiting[id] = nil
  else
    waiting[id] = true
    if C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
  end
  return cat[id]
end
local catFrame = CreateFrame("Frame")
catFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
catFrame:SetScript("OnEvent", function(_, _, id) if id and waiting[id] then Bank.Remember(id) end end)

-- Lecture --------------------------------------------------------------------------
local function readBank()
  local snap = { time = GetServerTime(), scanner = BF.MyName(), money = GetGuildBankMoney() or 0, tabs = {} }
  local stacks = 0
  for t = 1, (GetNumGuildBankTabs() or 0) do
    local name, _, isViewable = GetGuildBankTabInfo(t)
    local items, slots = {}, {}
    if isViewable then
      for s = 1, SLOTS do
        local _, count = GetGuildBankItemInfo(t, s)
        local link = count and count > 0 and GetGuildBankItemLink(t, s)
        if link then
          local id = C_Item.GetItemInfoInstant(link)
          if id then
            items[id] = (items[id] or 0) + count; stacks = stacks + 1
            Bank.Remember(id)
            slots[s] = { id = id, n = count }
          end
        end
      end
    end
    snap.tabs[t] = { name = name or ("Onglet " .. t), viewable = isViewable and true or false, items = items, slots = slots }
  end
  snap.stacks = stacks
  return snap
end

local function readLogs()
  local logs = { time = GetServerTime(), reader = BF.MyName(), tabs = {}, money = {} }
  for t = 1, (GetNumGuildBankTabs() or 0) do
    local list = {}
    for i = 1, (GetNumGuildBankTransactions(t) or 0) do
      local typ, who, link, count, t1, t2, y, mo, d, h = GetGuildBankTransaction(t, i)
      local iid = link and C_Item.GetItemInfoInstant(link)
      if iid then Bank.Remember(iid) end
      list[i] = { typ = typ, who = who, id = iid, n = count,
                  t1 = t1, t2 = t2, ago = ((y or 0) * 365 * 24 + (mo or 0) * 30 * 24 + (d or 0) * 24 + (h or 0)) }
    end
    logs.tabs[t] = list
  end
  for i = 1, (GetNumGuildBankMoneyTransactions() or 0) do
    local typ, who, amount, y, mo, d, h = GetGuildBankMoneyTransaction(i)
    logs.money[i] = { typ = typ, who = who, amount = amount,
                      ago = ((y or 0) * 365 * 24 + (mo or 0) * 30 * 24 + (d or 0) * 24 + (h or 0)) }
  end
  return logs
end

local function totals(snap)
  local tot = {}
  for _, tab in pairs(snap.tabs) do
    for id, n in pairs(tab.items) do tot[id] = (tot[id] or 0) + n end
  end
  return tot
end

-- Sérialisation -----------------------------------------------------------------------
function Bank.SerializeSnap(s)
  local parts = { table.concat({ "2", s.time, clean(s.scanner), s.money }, "^") }
  for t, tab in ipairs(s.tabs) do
    local items = {}
    for slot, it in pairs(tab.slots or {}) do items[#items + 1] = slot .. "," .. it.id .. "," .. it.n end
    parts[#parts + 1] = clean(tab.name) .. "@" .. (tab.viewable and "1" or "0") .. "@" .. table.concat(items, ";")
  end
  return table.concat(parts, "#")
end

function Bank.ParseSnap(str)
  local blocks = { strsplit("#", str) }
  local v, time, scanner, money = strsplit("^", blocks[1])
  if v ~= "2" then return end -- les anciennes versions sont ignorées
  local s = { time = tonumber(time), scanner = scanner, money = tonumber(money) or 0, tabs = {} }
  for i = 2, #blocks do
    local name, viewable, items = strsplit("@", blocks[i])
    local tab = { name = name, viewable = viewable == "1", items = {}, slots = {} }
    for trio in (items or ""):gmatch("[^;]+") do
      local slot, id, n = trio:match("^(%d+),(%d+),(%d+)$")
      if slot then
        slot, id, n = tonumber(slot), tonumber(id), tonumber(n)
        tab.slots[slot] = { id = id, n = n }
        tab.items[id] = (tab.items[id] or 0) + n
      end
    end
    s.tabs[i - 1] = tab
  end
  return s
end

function Bank.SerializeEvent(e)
  local items, names = {}, {}
  for id, d in pairs(e.items) do
    items[#items + 1] = id .. "," .. d
    local it = Bank.Remember(id)
    if it and it.n then names[#names + 1] = id .. "=" .. cleanName(it.n) .. "=" .. (it.q or "") .. "=" .. (it.c or "") end
  end
  return table.concat({ "1", clean(e.id), clean(e.who), e.t, e.money or 0, table.concat(items, ";"), e.src or "direct",
    table.concat(names, ";") }, "^")
end

function Bank.ParseEvent(str)
  local v, id, who, t, money, items, src = strsplit("^", str)
  if v ~= "1" then return end
  local e = { id = id, who = who, t = tonumber(t), money = tonumber(money) or 0, items = {}, src = src }
  for pair in (items or ""):gmatch("[^;]+") do
    local iid, d = pair:match("^(%d+),(%-?%d+)$")
    if iid then e.items[tonumber(iid)] = tonumber(d) end
  end
  return e
end

-- Photo connue -----------------------------------------------------------------------------
local uiListeners = {}
function Bank.OnChange(fn) uiListeners[#uiListeners + 1] = fn end
local function changed() for _, fn in ipairs(uiListeners) do pcall(fn) end end

function Bank.Get()
  local b = BrowzForeverDB and BrowzForeverDB.bank
  if b and b.tabs and b.tabs[1] and not b.tabs[1].slots then BrowzForeverDB.bank = nil; return nil end -- format v1
  return b
end

local function setBank(s)
  if not s or not s.time then return false end
  local cur = Bank.Get()
  if cur and cur.time and cur.time >= s.time then return false end
  BrowzForeverDB.bank = s
  changed()
  return true
end

-- Session au coffre --------------------------------------------------------------------------
-- 1) Ouverture : un voile bloque la fenêtre du coffre tant que le serveur n'a pas envoyé le contenu.
-- 2) Contenu chargé : photo de départ de la banque ; ce que fait le joueur = photo de fin - photo de départ
--    (un échange ou un objet détruit pendant la visite ne compte donc pas).
-- 3) Pendant le chargement seulement, on regarde les sacs : un clic droit dans les sacs dépose
--    directement un objet, et le voile ne peut pas l'empêcher.
local open, cur, base, openTime, logTimer, quietTimer, maxTimer = false
local bagsAtOpen, moneyAtOpen, earlyItems, earlyMoney

local function isGuildBank(t)
  return Enum and Enum.PlayerInteractionType and t == Enum.PlayerInteractionType.GuildBanker
end

local function readBags()
  local counts = {}
  local last = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
  for bag = 0, last do
    for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      if info and info.itemID then counts[info.itemID] = (counts[info.itemID] or 0) + (info.stackCount or 1) end
    end
  end
  return counts
end

-- Voile de chargement --------------------------------------------------------------------------
local veil
local function showVeil()
  local gb = _G.GuildBankFrame
  if not gb or not gb:IsShown() then return end
  if not veil then
    veil = CreateFrame("Frame", nil, gb)
    veil:EnableMouse(true)                 -- avale les clics sur les cases du coffre
    veil.bg = veil:CreateTexture(nil, "BACKGROUND")
    veil.bg:SetAllPoints(); veil.bg:SetColorTexture(0, 0, 0, 0.6)
    veil.text = veil:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    veil.text:SetPoint("CENTER")
    veil.text:SetText("Chargement de la banque…")
  end
  veil:SetParent(gb)
  veil:ClearAllPoints(); veil:SetPoint("TOPLEFT", gb, "TOPLEFT", 4, -24); veil:SetPoint("BOTTOMRIGHT", gb, "BOTTOMRIGHT", -4, 4)
  veil:SetFrameLevel(gb:GetFrameLevel() + 50)
  veil:Show()
end
local function hideVeil() if veil then veil:Hide() end end

local function rescan()
  if not open then return end
  local s = readBank()
  if cur and cur.stacks > 0 and s.stacks == 0 then return end -- données vidées : on garde la dernière lecture
  cur = s
end

-- Contenu reçu : on fige la photo de départ et ce qui a quitté/rejoint les sacs pendant le chargement
local function markLoaded()
  if not open or base then return end
  if quietTimer then quietTimer:Cancel(); quietTimer = nil end
  if maxTimer then maxTimer:Cancel(); maxTimer = nil end
  rescan()
  base = cur
  local now, items = readBags(), {}
  for id, n in pairs(bagsAtOpen or {}) do local d = n - (now[id] or 0); if d ~= 0 then items[id] = d end end
  for id, n in pairs(now) do if not (bagsAtOpen or {})[id] then items[id] = -n end end
  earlyItems, earlyMoney = items, (moneyAtOpen or 0) - GetMoney()
  hideVeil()
end

local function onOpen()
  if open or not BF.active then return end
  open, cur, base, openTime = true, nil, nil, GetServerTime()
  bagsAtOpen, moneyAtOpen, earlyItems, earlyMoney = readBags(), GetMoney(), nil, 0
  for t = 1, (GetNumGuildBankTabs() or 0) do QueryGuildBankTab(t); QueryGuildBankLog(t) end
  QueryGuildBankLog(MONEY_TAB)
  C_Timer.After(0, showVeil)                     -- la fenêtre Blizzard s'affiche juste après l'événement
  maxTimer = C_Timer.NewTimer(4, markLoaded)      -- au pire 4 s (serveur lent ou banque vide)
end

-- Chaque arrivée de données relance un court délai : quand le serveur se tait 0,3 s, c'est chargé
local function onData()
  if not open then return end
  rescan()
  if not base then
    if quietTimer then quietTimer:Cancel() end
    quietTimer = C_Timer.NewTimer(0.3, markLoaded)
  end
end

local function onClose()
  if not open then return end
  rescan()
  if not base then markLoaded() end
  open = false
  hideVeil()
  if quietTimer then quietTimer:Cancel(); quietTimer = nil end
  if maxTimer then maxTimer:Cancel(); maxTimer = nil end
  if cur and base then
    -- dépôts/retraits = différence de la banque depuis le chargement + ce qui est parti des sacs avant
    local a, b = totals(base), totals(cur)
    local items, any = {}, false
    for id, n in pairs(b) do local d = n - (a[id] or 0); if d ~= 0 then items[id] = d end end
    for id, n in pairs(a) do if not b[id] then items[id] = -n end end
    for id, d in pairs(earlyItems or {}) do items[id] = (items[id] or 0) + d end
    for id, d in pairs(items) do if d == 0 then items[id] = nil else any = true end end
    local money = (cur.money or 0) - (base.money or 0) + (earlyMoney or 0)
    if any or money ~= 0 then
      local e = { id = BF.MyName() .. "-" .. openTime, who = BF.MyName(), t = openTime, money = money, items = items, src = "direct" }
      BF.Bridge.NewEvent(e, true)
    end
  end
  if cur then
    BrowzForeverDB.logs = readLogs()
    setBank(cur)
    BF.Send("S", Bank.SerializeSnap(cur))
  end
  bagsAtOpen, moneyAtOpen, earlyItems, earlyMoney, base = nil, nil, nil, 0, nil
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
f:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE")
pcall(f.RegisterEvent, f, "GUILDBANKBAGSLOTS_CHANGED")
pcall(f.RegisterEvent, f, "GUILDBANK_UPDATE_MONEY")
pcall(f.RegisterEvent, f, "GUILDBANKLOG_UPDATE")
f:SetScript("OnEvent", function(_, e, a1)
  if e == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
    if isGuildBank(a1) then onOpen() end
  elseif e == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
    if isGuildBank(a1) then onClose() end
  elseif open then
    if e ~= "GUILDBANKLOG_UPDATE" then onData() end
    if e == "GUILDBANKLOG_UPDATE" then
      if logTimer then logTimer:Cancel() end
      logTimer = C_Timer.NewTimer(1, function() if open then BrowzForeverDB.logs = readLogs() end end)
    end
  end
end)

-- Partage entre membres -------------------------------------------------------------------------
local pendingAnswer
BF.OnMessage("S", function(data)
  local s = Bank.ParseSnap(data)
  if s then for _, tab in ipairs(s.tabs) do for id in pairs(tab.items) do Bank.Remember(id) end end end
  local mine = Bank.Get()
  if s and pendingAnswer and mine and s.time >= mine.time then pendingAnswer:Cancel(); pendingAnswer = nil end
  setBank(s)
end)

-- « H » = bonjour, avec l'heure de ma photo : le membre qui a plus récent répond
BF.OnMessage("H", function(data)
  local theirs = tonumber(data) or 0
  local mine = Bank.Get()
  if not mine or not mine.time or mine.time <= theirs then return end
  if pendingAnswer then return end
  pendingAnswer = C_Timer.NewTimer(1 + math.random() * 4, function()
    pendingAnswer = nil
    local m = Bank.Get()
    if m then BF.Send("S", Bank.SerializeSnap(m)) end
  end)
end)

BF.OnActive(function()
  C_Timer.After(8 + math.random() * 4, function()
    local m = Bank.Get()
    BF.Send("H", tostring(m and m.time or 0))
  end)
end)
