-- Browz Forever : demandes de retrait
--  * le membre compose sa demande (objets de la banque + explication) dans l'onglet Demandes ;
--  * les officiers en ligne sont prévenus ; ils acceptent ou refusent (onglet Demandes, ou panneau
--    à côté du coffre) ;
--  * accepter au coffre retire les objets dans les sacs de l'officier ; accepter ailleurs les retirera
--    à sa prochaine ouverture du coffre ;
--  * à la boîte aux lettres, le courrier est pré-rempli (l'officier clique Envoyer) ; un échange avec
--    le demandeur se remplit aussi tout seul ; l'envoi ou l'échange réussi = demande livrée ;
--  * tout circule entre membres (message « R ») et part vers Discord par les ponts.
local _, BF = ...
local Req = {}
BF.Requests = Req

local DAY = 86400
local STATUS = {
  attente  = { "En attente", "|cffffd100" },
  acceptee = { "Acceptée", "|cff66ccff" },
  retiree  = { "Prête à envoyer", "|cff66ccff" },
  livree   = { "Livrée", "|cff33ff33" },
  refusee  = { "Refusée", "|cffff5555" },
  annulee  = { "Annulée", "|cff999999" },
  discord  = { "Faite sur Discord", "|cffb399ff" },   -- seulement dans les messages « D » (pas encore en jeu)
}
local FINAL = { livree = true, refusee = true, annulee = true }

local function db() BrowzForeverDB.requests = BrowzForeverDB.requests or {}; return BrowzForeverDB.requests end
local function clean(s) return (tostring(s or ""):gsub("[%^;,~|#@]", " "):sub(1, 200)) end
local function short(name) return (tostring(name or "?"):gsub("%-.*$", "")) end

local function itemName(id)
  local it = BF.Bank.Remember(id)
  return (it and it.n) or (C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)) or ("Objet #" .. id)
end
local function itemLabel(id, n)
  local q = C_Item.GetItemQualityByID and C_Item.GetItemQualityByID(id)
  local c = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
  local name = itemName(id)
  if c and c.hex then name = c.hex .. name .. "|r" end
  return (n and n > 1) and (n .. " × " .. name) or name
end
function Req.ItemsText(items, sep)
  local o = {}
  for id, n in pairs(items or {}) do o[#o + 1] = itemLabel(id, n) end
  table.sort(o)
  return table.concat(o, sep or ", ")
end

-- Format : 1^id^demandeur^heure^id,n;…^explication^statut^officier^heure de décision^dernière modif
function Req.Serialize(r)
  local items = {}
  for id, n in pairs(r.items) do items[#items + 1] = id .. "," .. n end
  return table.concat({ "1", clean(r.id), clean(r.who), r.t or 0, table.concat(items, ";"), clean(r.why), r.status,
    clean(r.by), r.at or 0, r.upd or 0 }, "^")
end

function Req.Parse(s)
  local v, id, who, t, items, why, status, by, at, upd = strsplit("^", s)
  if v ~= "1" or not STATUS[status or ""] then return end
  local r = { id = id, who = who, t = tonumber(t) or 0, items = {}, why = (why ~= "" and why ~= " ") and why or nil,
    status = status, by = by ~= "" and by or nil, at = tonumber(at) or 0, upd = tonumber(upd) or 0 }
  for pair in (items or ""):gmatch("[^;]+") do
    local iid, n = pair:match("^(%d+),(%d+)$")
    if iid then r.items[tonumber(iid)] = tonumber(n) end
  end
  return r
end

-- Changements (le plus récent gagne) --------------------------------------------------------------
local listeners = {}
local function changed() for _, fn in ipairs(listeners) do pcall(fn) end end
function Req.OnChange(fn) listeners[#listeners + 1] = fn end

local function store(r)
  local cur = db()[r.id]
  if cur and (cur.upd or 0) >= (r.upd or 0) then return false end
  db()[r.id] = r
  -- ménage : les demandes terminées depuis plus de 30 jours
  for id, x in pairs(db()) do
    if FINAL[x.status] and GetServerTime() - (x.upd or 0) > 30 * DAY then db()[id] = nil end
  end
  return true
end

local function publish(r)
  local data = Req.Serialize(r)
  BF.Send("R", data)
  if BF.Bridge.IsOn() then BF.Bridge.Emit("R", data) end
end

local function update(r, status, extra)
  r.status, r.upd = status, math.max(GetServerTime(), (r.upd or 0) + 1)   -- toujours plus récent que la version d'avant
  for k, v in pairs(extra or {}) do r[k] = v end
  db()[r.id] = r
  publish(r)
  changed()
end

function Req.Create(items, why)
  local any = false
  for _ in pairs(items) do any = true end
  if not any then return end
  local me, now = BF.MyName(), GetServerTime()
  local r = { id = me .. "-" .. now, who = me, t = now, items = items, why = why, status = "attente", upd = now }
  db()[r.id] = r
  publish(r)
  changed()
  BF.Print("Demande envoyée aux officiers : " .. Req.ItemsText(items))
  return r
end

function Req.Accept(r)
  update(r, "acceptee", { by = BF.MyName(), at = GetServerTime() })
  BF.Print(("Demande de %s acceptée."):format(short(r.who)))
  if BF.Bank.IsReady() then Req.Withdraw() else
    BF.Print("Les objets seront retirés à ta prochaine ouverture du coffre de guilde.")
  end
end
function Req.Refuse(r) update(r, "refusee", { by = BF.MyName(), at = GetServerTime() }) end
function Req.Cancel(r) update(r, "annulee") end
function Req.Delivered(r, how)
  update(r, "livree", { by = r.by or BF.MyName() })
  BF.Print(("Demande de %s livrée (%s)."):format(short(r.who), how))
end

-- Listes ---------------------------------------------------------------------------------------
function Req.List(filter)
  local out = {}
  for _, r in pairs(db()) do if not filter or filter(r) then out[#out + 1] = r end end
  table.sort(out, function(a, b) return (a.t or 0) > (b.t or 0) end)
  return out
end
local function mineToDeliver(r)
  return (r.status == "acceptee" or r.status == "retiree") and r.by == BF.MyName()
end

-- Réception ----------------------------------------------------------------------------------------
BF.OnMessage("R", function(data)
  local r = Req.Parse(data)
  if not r then return end
  local old = db()[r.id]
  if not store(r) then return end
  if BF.Bridge.IsOn() then BF.Bridge.Emit("R", data) end
  changed()
  -- officier en ligne : une nouvelle demande arrive
  if r.status == "attente" and not old and BF.IsOfficer() and r.who ~= BF.MyName() then
    BF.Print(("|cffffd100Nouvelle demande de retrait|r de %s : %s. |cffffd100/browz demandes|r pour répondre.")
      :format(short(r.who), Req.ItemsText(r.items)))
    if PlaySound and SOUNDKIT and SOUNDKIT.TELL_MESSAGE then PlaySound(SOUNDKIT.TELL_MESSAGE) end
    if RaidNotice_AddMessage and RaidWarningFrame then
      RaidNotice_AddMessage(RaidWarningFrame, "Browz : nouvelle demande de " .. short(r.who), ChatTypeInfo["GUILD"])
    end
  end
  -- demandeur : réponse d'un officier
  if old and r.who == BF.MyName() and old.status ~= r.status then
    local st = STATUS[r.status]
    BF.Print(("Ta demande (%s) : %s%s|r%s"):format(Req.ItemsText(r.items), st[2], st[1],
      r.by and (" par " .. short(r.by)) or ""))
  end
end)

-- À la connexion et quand un pont arrive : chacun renvoie ses demandes ouvertes (et les officiers
-- celles dont ils s'occupent), pour que tout le monde soit à jour.
local function resendOpen()
  local me = BF.MyName()
  for _, r in pairs(db()) do
    if not FINAL[r.status] and (r.who == me or r.by == me or BF.IsOfficer()) then BF.Send("R", Req.Serialize(r)) end
  end
end
BF.OnActive(function() C_Timer.After(6 + math.random() * 6, resendOpen) end)
BF.OnMessage("P", function() C_Timer.After(3 + math.random() * 8, resendOpen) end)

-- Retrait au coffre ---------------------------------------------------------------------------------
local function freeBagSlots()
  local free = {}
  for bag = 0, (NUM_BAG_SLOTS or 4) do
    for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
      if not C_Container.GetContainerItemInfo(bag, slot) then free[#free + 1] = { bag, slot } end
    end
  end
  return free
end

local function bagCount(id)
  return (C_Item.GetItemCount and C_Item.GetItemCount(id, false)) or GetItemCount(id) or 0
end

-- Une file d'actions espacées (le serveur refuse les clics trop rapides)
local queue, running = {}, false
local function pump()
  local job = table.remove(queue, 1)
  if not job then running = false; return end
  local ok, err = pcall(job)
  if not ok then BF.Print("|cffff5555Retrait interrompu :|r " .. tostring(err)) end
  C_Timer.After(0.4, pump)
end
local function push(job) queue[#queue + 1] = job; if not running then running = true; C_Timer.After(0, pump) end end

local withdrawLog = {}
function Req.WithdrawLog() return withdrawLog end

-- Retire du coffre ce qui manque dans les sacs pour les demandes que j'ai acceptées
function Req.Withdraw()
  if not BF.Bank.IsReady() then return end
  local needs = {}   -- [id] = quantité à retirer
  local list = Req.List(function(r) return r.status == "acceptee" and r.by == BF.MyName() end)
  if #list == 0 then return end
  for _, r in ipairs(list) do for id, n in pairs(r.items) do needs[id] = (needs[id] or 0) + n end end
  for id, n in pairs(needs) do needs[id] = math.max(0, n - bagCount(id)) end
  local free = freeBagSlots()
  for id, n in pairs(needs) do
    local left = n
    for tab = 1, (GetNumGuildBankTabs() or 0) do
      for slot = 1, (MAX_GUILDBANK_SLOTS_PER_TAB or 98) do
        if left <= 0 then break end
        local link = GetGuildBankItemLink(tab, slot)
        local _, count = GetGuildBankItemInfo(tab, slot)
        if link and count and count > 0 and C_Item.GetItemInfoInstant(link) == id then
          local take = math.min(left, count)
          left = left - take
          push(function()
            if SetCurrentGuildBankTab then SetCurrentGuildBankTab(tab) end
            if take >= count then
              AutoStoreGuildBankItem(tab, slot)
            else
              local spot = table.remove(free, 1)
              if not spot then error("plus de place dans les sacs") end
              SplitGuildBankItem(tab, slot, take)
              C_Container.PickupContainerItem(spot[1], spot[2])
            end
            withdrawLog[#withdrawLog + 1] = ("Retiré %s"):format(itemLabel(id, take))
            changed()
          end)
        end
      end
    end
    if left > 0 then BF.Print(("|cffff5555Il manque %d × %s dans la banque.|r"):format(left, itemName(id))) end
  end
  push(function()
    for _, r in ipairs(list) do
      local all = true
      for id, n in pairs(r.items) do if bagCount(id) < n then all = false end end
      if all then update(r, "retiree") end
    end
    BF.Print("|cff33ff33Va à la boîte aux lettres : le courrier sera pré-rempli, tu n'auras plus qu'à cliquer sur Envoyer !|r")
    changed()
  end)
end

BF.Bank.OnLoaded(function()
  withdrawLog = {}
  if BF.IsOfficer() then
    Req.ShowSide()
    C_Timer.After(0.5, Req.Withdraw)
  end
end)
BF.Bank.OnClosed(function() if Req.side then Req.side:Hide() end end)

-- Mettre des objets précis (quantités exactes) dans des cases d'envoi : courrier ou échange
local function findStack(id, want, used)
  local best
  for bag = 0, (NUM_BAG_SLOTS or 4) do
    for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      if info and info.itemID == id and not info.isLocked and not used[bag * 100 + slot] then
        if info.stackCount == want then return bag, slot, info.stackCount end
        if not best or info.stackCount > best[3] then best = { bag, slot, info.stackCount } end
      end
    end
  end
  if best then return best[1], best[2], best[3] end
end

local function fill(items, maxSlots, put)   -- put(index) dépose ce qui est sur le curseur
  local index, used = 0, {}
  for id, n in pairs(items) do
    local left = n
    while left > 0 and index < maxSlots do
      local bag, slot, count = findStack(id, left, used)
      if not bag then break end
      used[bag * 100 + slot] = true
      index = index + 1
      local take = math.min(left, count)
      local i = index
      push(function()
        ClearCursor()
        if take < count then C_Container.SplitContainerItem(bag, slot, take)
        else C_Container.PickupContainerItem(bag, slot) end
        put(i)
      end)
      left = left - take
    end
  end
end

-- Courrier ---------------------------------------------------------------------------------------
local prepared   -- demande dont le courrier est préparé
local mf = CreateFrame("Frame")
mf:RegisterEvent("MAIL_SHOW")
mf:RegisterEvent("MAIL_SEND_SUCCESS")
mf:RegisterEvent("MAIL_CLOSED")
mf:SetScript("OnEvent", function(_, e)
  if not BF.active then return end
  if e == "MAIL_SHOW" then
    local r = Req.List(function(x) return mineToDeliver(x) end)[1]
    if not r then return end
    for id, n in pairs(r.items) do
      if bagCount(id) < n then
        BF.Print(("Demande de %s : il te manque %s dans les sacs."):format(short(r.who), itemLabel(id, n - bagCount(id))))
        return
      end
    end
    C_Timer.After(0.3, function()
      if MailFrameTab_OnClick then pcall(MailFrameTab_OnClick, nil, 2) end
      if SendMailNameEditBox then SendMailNameEditBox:SetText(short(r.who)) end
      if SendMailSubjectEditBox then SendMailSubjectEditBox:SetText("Browz Forever : ta demande") end
      local body = "Demande : " .. Req.ItemsText(r.items):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
      if r.why then body = body .. "\nExplication : " .. r.why end
      if SendMailBodyEditBox then SendMailBodyEditBox:SetText(body .. "\n\nBonne journée de la part de Browz Forever !") end
      fill(r.items, ATTACHMENTS_MAX_SEND or 12, function(i) ClickSendMailItemButton(i) end)
      prepared = r
      BF.Print(("Courrier pour %s pré-rempli : vérifie puis clique sur |cffffd100Envoyer|r."):format(short(r.who)))
    end)
  elseif e == "MAIL_SEND_SUCCESS" then
    if prepared then
      local r = prepared
      prepared = nil
      Req.Delivered(r, "par courrier")
    end
  elseif e == "MAIL_CLOSED" then
    prepared = nil
  end
end)

-- Échange ---------------------------------------------------------------------------------------
local trading, tradeDone
local tf = CreateFrame("Frame")
tf:RegisterEvent("TRADE_SHOW")
tf:RegisterEvent("TRADE_CLOSED")
tf:RegisterEvent("UI_INFO_MESSAGE")
tf:SetScript("OnEvent", function(_, e, a1, a2)
  if not BF.active then return end
  if e == "TRADE_SHOW" then
    local partner = UnitName("NPC")
    local r = partner and Req.List(function(x) return mineToDeliver(x) and short(x.who) == partner end)[1]
    trading, tradeDone = nil, false
    if not r then return end
    for id, n in pairs(r.items) do if bagCount(id) < n then return end end
    trading = r
    C_Timer.After(0.3, function()
      fill(r.items, MAX_TRADABLE_ITEMS or 6, function(i) ClickTradeButton(i) end)
      BF.Print(("Échange avec %s pré-rempli avec sa demande : vérifie puis clique sur |cffffd100Échanger|r."):format(partner))
    end)
  elseif e == "UI_INFO_MESSAGE" then
    if trading and (a2 == ERR_TRADE_COMPLETE or a1 == ERR_TRADE_COMPLETE) then tradeDone = true end
  elseif e == "TRADE_CLOSED" then
    local r = trading
    C_Timer.After(0.5, function()
      if r and tradeDone then Req.Delivered(r, "par échange") end
    end)
    trading = nil
  end
end)

-- Interface : onglet Demandes ------------------------------------------------------------------------
local panel = BF.DemandesPanel
local W = BF.MainFrame:GetWidth()
local ROW = 22

local function button(parent, text, w, onClick)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(w, 22); b:SetText(text); b:SetScript("OnClick", onClick)
  return b
end
local function label(parent, template)
  local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlight")
  fs:SetJustifyH("LEFT"); fs:SetWordWrap(false)
  return fs
end

-- sous-onglets
local view = "new"
local views = {}
local switch = {}
local function setView(v) view = v; for k, fr in pairs(views) do fr:SetShown(k == v) end
  for k, b in pairs(switch) do if k == v then b:LockHighlight() else b:UnlockHighlight() end end
  Req.Refresh()
end
local defs = { { "new", "Nouvelle demande" }, { "mine", "Mes demandes" }, { "guild", "Demandes de la guilde" } }
for i, d in ipairs(defs) do
  local b = button(panel, d[2], 170, function() setView(d[1]) end)
  b:SetPoint("TOPLEFT", 16 + (i - 1) * 178, -32)
  switch[d[1]] = b
  local fr = CreateFrame("Frame", nil, panel)
  fr:SetPoint("TOPLEFT", 0, -60); fr:SetPoint("BOTTOMRIGHT")
  views[d[1]] = fr
end

-- Nouvelle demande : à gauche les objets de la banque, à droite le panier ----------------------------
local nv = views.new
local cart, whyText = {}, ""
local search = CreateFrame("EditBox", nil, nv, "InputBoxTemplate")
search:SetSize(240, 20); search:SetPoint("TOPLEFT", 24, -6); search:SetAutoFocus(false)
search.hint = label(search, "GameFontDisable"); search.hint:SetPoint("LEFT", 4, 0); search.hint:SetText("Rechercher dans la banque…")
search:SetScript("OnTextChanged", function(self) self.hint:SetShown(self:GetText() == ""); Req.Refresh() end)
search:SetScript("OnEscapePressed", search.ClearFocus)

local stockRows, stockList, stockOffset = {}, {}, 0
local STOCK_ROWS = 10
local function bankTotals()
  local tot, bank = {}, BF.Bank.Get()
  for _, tab in pairs((bank and bank.tabs) or {}) do
    for _, it in pairs(tab.slots or {}) do tot[it.id] = (tot[it.id] or 0) + it.n end
  end
  return tot
end
for i = 1, STOCK_ROWS do
  local r = CreateFrame("Button", nil, nv)
  r:SetSize(256, ROW); r:SetPoint("TOPLEFT", 18, -30 - (i - 1) * ROW)
  r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(18, 18); r.icon:SetPoint("LEFT", 4, 0)
  r.text = label(r); r.text:SetPoint("LEFT", r.icon, "RIGHT", 6, 0); r.text:SetPoint("RIGHT", -40, 0)
  r.count = label(r, "GameFontNormal"); r.count:SetPoint("RIGHT", -4, 0)
  r:SetScript("OnClick", function(self)
    local id, stock = self.id, self.stock
    if not id then return end
    local n = IsShiftKeyDown() and stock or 1
    cart[id] = math.min(stock, (cart[id] or 0) + n)
    Req.Refresh()
  end)
  r:SetScript("OnEnter", function(self)
    if not self.id then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetItemByID(self.id)
    GameTooltip:AddLine(" "); GameTooltip:AddLine("Clic : +1 dans la demande · Maj+clic : tout", 0.6, 0.8, 1)
    GameTooltip:Show()
  end)
  r:SetScript("OnLeave", GameTooltip_Hide)
  stockRows[i] = r
end
nv:EnableMouseWheel(true)
nv:SetScript("OnMouseWheel", function(_, delta)
  stockOffset = math.max(0, math.min(math.max(0, #stockList - STOCK_ROWS), stockOffset - delta * 3))
  Req.Refresh()
end)
local stockInfo = label(nv, "GameFontDisableSmall"); stockInfo:SetPoint("TOPLEFT", 24, -30 - STOCK_ROWS * ROW - 4)

local cartTitle = label(nv, "GameFontNormal"); cartTitle:SetPoint("TOPLEFT", 300, -8); cartTitle:SetText("Ta demande")
local cartRows = {}
for i = 1, 6 do
  local r = CreateFrame("Frame", nil, nv)
  r:SetSize(W - 320, ROW); r:SetPoint("TOPLEFT", 296, -28 - (i - 1) * ROW)
  r.text = label(r); r.text:SetPoint("LEFT", 4, 0); r.text:SetPoint("RIGHT", -70, 0)
  r.minus = button(r, "-", 22, function() local id = r.id; if id then cart[id] = (cart[id] or 0) - 1
    if cart[id] <= 0 then cart[id] = nil end; Req.Refresh() end end)
  r.minus:SetPoint("RIGHT", -46, 0)
  r.plus = button(r, "+", 22, function() local id = r.id; if id then
    cart[id] = math.min(bankTotals()[id] or 0, (cart[id] or 0) + 1); Req.Refresh() end end)
  r.plus:SetPoint("RIGHT", -24, 0)
  r.del = button(r, "x", 22, function() if r.id then cart[r.id] = nil; Req.Refresh() end end)
  r.del:SetPoint("RIGHT", 0, 0)
  cartRows[i] = r
end
local whyLabel = label(nv, "GameFontNormal"); whyLabel:SetPoint("TOPLEFT", 300, -28 - 6 * ROW - 6)
whyLabel:SetText("Explication (ex. « pour monter mon métier »)")
local why = CreateFrame("EditBox", nil, nv, "InputBoxTemplate")
why:SetSize(W - 330, 20); why:SetPoint("TOPLEFT", whyLabel, "BOTTOMLEFT", 6, -4); why:SetAutoFocus(false)
why:SetMaxLetters(150)
why:SetScript("OnTextChanged", function(self) whyText = self:GetText() or "" end)
why:SetScript("OnEscapePressed", why.ClearFocus)
local send = button(nv, "Envoyer la demande", 170, function()
  local items, any = {}, false
  for id, n in pairs(cart) do if n > 0 then items[id] = n; any = true end end
  if not any then BF.Print("Ajoute d'abord des objets (clic sur un objet de la banque)."); return end
  if strtrim(whyText) == "" then BF.Print("Écris une petite explication pour les officiers."); return end
  Req.Create(items, strtrim(whyText))
  wipe(cart); why:SetText(""); why:ClearFocus()
  setView("mine")
end)
send:SetPoint("TOPLEFT", why, "BOTTOMLEFT", -6, -10)

-- Listes « Mes demandes » et « Demandes de la guilde » ------------------------------------------------
local function makeList(parent, n, withButtons)
  local rows = {}
  for i = 1, n do
    local r = CreateFrame("Frame", nil, parent)
    r:SetSize(W - 40, 2 * ROW); r:SetPoint("TOPLEFT", 20, -4 - (i - 1) * (2 * ROW + 2))
    r.bg = r:CreateTexture(nil, "BACKGROUND"); r.bg:SetAllPoints(); r.bg:SetColorTexture(1, 1, 1, i % 2 == 0 and 0.03 or 0.06)
    r.top = label(r); r.top:SetPoint("TOPLEFT", 6, -4); r.top:SetPoint("RIGHT", -190, 0)
    r.bottom = label(r, "GameFontHighlightSmall"); r.bottom:SetPoint("BOTTOMLEFT", 6, 5); r.bottom:SetPoint("RIGHT", -190, 0)
    r.b1 = button(r, "", 88, function() if r.act1 then r.act1() end end); r.b1:SetPoint("RIGHT", -96, 0)
    r.b2 = button(r, "", 88, function() if r.act2 then r.act2() end end); r.b2:SetPoint("RIGHT", -4, 0)
    rows[i] = r
  end
  return rows
end
local mineRows = makeList(views.mine, 6)
local guildRows = makeList(views.guild, 6)
local guildNote = label(views.guild, "GameFontDisable"); guildNote:SetPoint("BOTTOMLEFT", 22, 16)

local function statusText(r)
  local st = STATUS[r.status]
  local who = r.by and (" par " .. short(r.by)) or ""
  return st[2] .. st[1] .. "|r" .. ((r.status ~= "attente" and r.status ~= "annulee") and who or "")
end

local function fillRow(row, r, mode)
  row:Show(); row.r = r
  local when = BF.Ago(r.t)
  if mode == "mine" then
    row.top:SetText(Req.ItemsText(r.items))
    row.bottom:SetText(statusText(r) .. "  ·  " .. when .. (r.why and ("  ·  « " .. r.why .. " »") or ""))
  else
    row.top:SetText("|cffffffff" .. short(r.who) .. "|r : " .. Req.ItemsText(r.items))
    row.bottom:SetText(statusText(r) .. "  ·  " .. when .. (r.why and ("  ·  « " .. r.why .. " »") or ""))
  end
  row.b1:Hide(); row.b2:Hide(); row.act1, row.act2 = nil, nil
  if mode == "mine" and r.status == "attente" then
    row.b2:SetText("Annuler"); row.b2:Show(); row.act2 = function() Req.Cancel(r) end
  elseif mode == "guild" and BF.IsOfficer() then
    if r.status == "attente" then
      row.b1:SetText("Accepter"); row.b1:Show(); row.act1 = function() Req.Accept(r) end
      row.b2:SetText("Refuser"); row.b2:Show(); row.act2 = function() Req.Refuse(r) end
    elseif mineToDeliver(r) then
      row.b2:SetText("Livrée"); row.b2:Show(); row.act2 = function() Req.Delivered(r, "marquée à la main") end
    end
  end
end

function Req.Refresh()
  if not panel:IsShown() and not (Req.side and Req.side:IsShown()) then return end
  -- banque
  local tot = bankTotals()
  local filter = strlower(search:GetText() or "")
  wipe(stockList)
  for id, n in pairs(tot) do
    local name = itemName(id)
    if filter == "" or strlower(name):find(filter, 1, true) then stockList[#stockList + 1] = { id = id, n = n, name = name } end
  end
  table.sort(stockList, function(a, b) return a.name < b.name end)
  stockOffset = math.min(stockOffset, math.max(0, #stockList - STOCK_ROWS))
  for i, row in ipairs(stockRows) do
    local e = stockList[i + stockOffset]
    row.id, row.stock = e and e.id, e and e.n
    if e then
      local left = e.n - (cart[e.id] or 0)
      row.icon:SetTexture(C_Item.GetItemIconByID(e.id)); row.text:SetText(itemLabel(e.id)); row.count:SetText(left)
      row:Show()
    else row:Hide() end
  end
  stockInfo:SetText(#stockList > STOCK_ROWS and ("Molette : %d-%d sur %d"):format(stockOffset + 1,
    math.min(#stockList, stockOffset + STOCK_ROWS), #stockList) or (#stockList == 0 and "Banque inconnue : ouvre le coffre une fois." or ""))
  -- panier
  local ids = {}
  for id in pairs(cart) do ids[#ids + 1] = id end
  table.sort(ids)
  for i, row in ipairs(cartRows) do
    local id = ids[i]
    row.id = id
    if id then row.text:SetText(itemLabel(id, cart[id])); row:Show() else row:Hide() end
  end
  -- listes
  local mine = Req.List(function(r) return r.who == BF.MyName() end)
  for i, row in ipairs(mineRows) do if mine[i] then fillRow(row, mine[i], "mine") else row:Hide() end end
  local open = Req.List(function(r) return not FINAL[r.status] end)
  for i, row in ipairs(guildRows) do if open[i] then fillRow(row, open[i], "guild") else row:Hide() end end
  guildNote:SetText(#open == 0 and "Aucune demande en cours." or (BF.IsOfficer() and "" or "Seuls les officiers peuvent accepter ou refuser."))
  switch.guild:SetText(("Demandes de la guilde (%d)"):format(#open))
  if Req.side and Req.side:IsShown() then Req.RefreshSide() end
end
panel:SetScript("OnShow", function() setView(view) end)
Req.OnChange(Req.Refresh)
BF.Bank.OnChange(Req.Refresh)

-- Panneau à côté du coffre (officiers) ---------------------------------------------------------------
local sideRows = {}
function Req.ShowSide()
  local gb = _G.GuildBankFrame
  if not gb then return end
  local open = Req.List(function(r) return r.status == "attente" or mineToDeliver(r) end)
  if #open == 0 then return end
  if not Req.side then
    local s = CreateFrame("Frame", "BrowzForeverRequestsSide", gb, "BasicFrameTemplateWithInset")
    s:SetSize(330, 400)
    s.title = s:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    s.title:SetPoint("TOP", 0, -5); s.title:SetText("Browz Forever — Demandes")
    for i = 1, 5 do
      local r = CreateFrame("Frame", nil, s)
      r:SetSize(306, 52); r:SetPoint("TOPLEFT", 12, -30 - (i - 1) * 54)
      r.bg = r:CreateTexture(nil, "BACKGROUND"); r.bg:SetAllPoints(); r.bg:SetColorTexture(1, 1, 1, 0.05)
      r.top = label(r); r.top:SetPoint("TOPLEFT", 6, -4); r.top:SetPoint("RIGHT", -6, 0)
      r.mid = label(r, "GameFontHighlightSmall"); r.mid:SetPoint("TOPLEFT", 6, -20); r.mid:SetPoint("RIGHT", -6, 0)
      r.b1 = button(r, "Accepter", 80, function() if r.r then Req.Accept(r.r) end end); r.b1:SetPoint("BOTTOMRIGHT", -88, 4)
      r.b2 = button(r, "Refuser", 80, function() if r.r then Req.Refuse(r.r) end end); r.b2:SetPoint("BOTTOMRIGHT", -4, 4)
      r.st = label(r, "GameFontHighlightSmall"); r.st:SetPoint("BOTTOMLEFT", 6, 8)
      sideRows[i] = r
    end
    s.log = label(s, "GameFontHighlightSmall"); s.log:SetPoint("TOPLEFT", 16, -306); s.log:SetPoint("RIGHT", -16, 0)
    s.log:SetWordWrap(true); s.log:SetJustifyV("TOP"); s.log:SetHeight(60)
    s.hint = label(s, "GameFontNormalSmall"); s.hint:SetPoint("BOTTOMLEFT", 16, 12); s.hint:SetPoint("RIGHT", -16, 0)
    s.hint:SetWordWrap(true)
    Req.side = s
  end
  Req.side:ClearAllPoints()
  Req.side:SetPoint("TOPLEFT", gb, "TOPRIGHT", 4, 0)
  Req.side:Show()
  Req.RefreshSide()
end

function Req.RefreshSide()
  local s = Req.side
  local open = Req.List(function(r) return r.status == "attente" or mineToDeliver(r) end)
  for i, row in ipairs(sideRows) do
    local r = open[i]
    row.r = r
    if r then
      row.top:SetText("|cffffffff" .. short(r.who) .. "|r : " .. Req.ItemsText(r.items))
      row.mid:SetText(r.why and ("« " .. r.why .. " »") or "")
      local pending = r.status == "attente"
      row.b1:SetShown(pending); row.b2:SetShown(pending)
      row.st:SetText(pending and "" or statusText(r))
      row:Show()
    else row:Hide() end
  end
  s.log:SetText(#withdrawLog > 0 and table.concat(withdrawLog, "\n") or "")
  local ready = #Req.List(function(r) return r.status == "retiree" and r.by == BF.MyName() end) > 0
  s.hint:SetText(ready and "|cff33ff33Va à la boîte aux lettres : tout sera pré-rempli, tu n'auras plus qu'à envoyer !|r"
    or "Accepter retire les objets dans tes sacs.")
end

BF.commands["demandes"] = function() BF.OpenMain("demandes") end

-- Demandes faites sur Discord ------------------------------------------------------------------------
-- Le PC d'un pont reçoit Inbox.lua (écrit par son client). Les ponts les annoncent à la guilde (« D ») ;
-- le joueur concerné (un de ses personnages) se voit proposer de les ajouter en jeu.
local discordPending = {}   -- [id] = demande (statut « discord »), connue par Inbox.lua ou par un message « D »
local asked = {}            -- demandes déjà proposées pendant cette session

local function loadInbox()
  local inbox = _G.BrowzForeverInbox
  for _, x in ipairs((inbox and inbox.requests) or {}) do
    if x.id and not db()[x.id] then
      local items = {}
      for id, n in pairs(x.items or {}) do items[tonumber(id)] = tonumber(n) end
      discordPending[x.id] = { id = x.id, who = x.who, t = x.t or 0, items = items, why = x.why ~= "" and x.why or nil,
        status = "discord", upd = x.upd or x.t or 0 }
    end
  end
end

local function announce()
  for id, r in pairs(discordPending) do
    if not db()[id] then BF.Send("D", Req.Serialize(r)) end
  end
end

local function isMine(who)
  for name in pairs(BrowzForeverDB.chars or {}) do
    if short(name) == short(who) then return true end
  end
  return short(who) == short(BF.MyName())
end

local popupQueue = {}
local function nextPopup()
  if StaticPopup_Visible and StaticPopup_Visible("BROWZFOREVER_DISCORD_REQ") then return end
  local r = table.remove(popupQueue, 1)
  if not r then return end
  if db()[r.id] then return nextPopup() end
  local text = ("Demande faite sur Discord pour |cffffffff%s|r :\n\n%s%s\n\nL'ajouter en jeu pour que les officiers puissent l'accepter ?")
    :format(short(r.who), Req.ItemsText(r.items, "\n"), r.why and ("\n« " .. r.why .. " »") or "")
  StaticPopup_Show("BROWZFOREVER_DISCORD_REQ", text, nil, r)
end

StaticPopupDialogs["BROWZFOREVER_DISCORD_REQ"] = {
  text = "%s",
  button1 = "Ajouter", button2 = "Supprimer", button3 = "Plus tard",
  OnAccept = function(_, r)
    r.status, r.upd = "attente", math.max(GetServerTime(), (r.upd or 0) + 1)
    db()[r.id] = r
    publish(r); changed()
    BF.Print("Demande Discord ajoutée en jeu : " .. Req.ItemsText(r.items))
    C_Timer.After(0.5, nextPopup)
  end,
  OnCancel = function(_, r, reason)
    if reason == "clicked" then
      r.status, r.upd = "annulee", math.max(GetServerTime(), (r.upd or 0) + 1)
      db()[r.id] = r
      publish(r); changed()
      BF.Print("Demande Discord supprimée.")
    end
    C_Timer.After(0.5, nextPopup)
  end,
  OnAlt = function() C_Timer.After(0.5, nextPopup) end,
  timeout = 0, whileDead = true, hideOnEscape = false, preferredIndex = 3,   -- Échap ne doit pas supprimer
}

local function offer(r)
  if asked[r.id] or db()[r.id] or not isMine(r.who) then return end
  asked[r.id] = true
  popupQueue[#popupQueue + 1] = r
  nextPopup()
end

BF.OnMessage("D", function(data)
  local r = Req.Parse(data)
  if not r or r.status ~= "discord" then return end
  if not discordPending[r.id] then discordPending[r.id] = r end
  offer(r)
end)
BF.OnMessage("Q", function() C_Timer.After(1 + math.random() * 3, announce) end)

BF.OnActive(function()
  loadInbox()
  C_Timer.After(4, function()
    for _, r in pairs(discordPending) do offer(r) end   -- mes propres demandes Discord (ce PC est un pont)
    announce()
    BF.Send("Q", "1")   -- « avez-vous des demandes Discord pour moi ? »
  end)
end)
