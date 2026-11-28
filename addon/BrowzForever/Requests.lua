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
-- Annuler : le demandeur (tant que ce n'est pas livré) ou un officier (même après acceptation, en cas d'erreur)
function Req.CanCancel(r)
  if FINAL[r.status] then return false end
  return r.who == BF.MyName() or BF.IsOfficer()
end
function Req.Cancel(r)
  local withdrawn = r.status == "retiree"
  update(r, "annulee", r.who ~= BF.MyName() and { by = BF.MyName() } or nil)
  BF.Print(("Demande de %s annulée."):format(short(r.who))
    .. (withdrawn and " |cffffd100Les objets sont déjà dans les sacs de l'officier : pense à les remettre au coffre.|r" or ""))
end
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

-- Retire du coffre ce qui manque dans les sacs pour les demandes que j'ai acceptées.
-- Sur Forever, le coffre refuse de COUPER une pile venue d'un autre royaume (erreur rouge) et le clic droit
-- (rangement auto) refuse de les combiner. Donc : on ne prend que des PILES ENTIÈRES, posées chacune dans une case
-- vide des sacs, en choisissant les piles qui font le total le plus proche au-dessus de ce qu'il faut. S'il y a du
-- surplus, il est coupé dans les sacs (là, le jeu l'accepte) et reposé dans la case du coffre libérée.
local function pickStacks(stacks, need)
  -- somme atteignable la plus petite >= need (sac à dos) ; best[s] = liste d'indices
  local maxc = 0
  for _, st in ipairs(stacks) do maxc = math.max(maxc, st.count) end
  local limit = need + maxc
  local best = { [0] = {} }
  for i, st in ipairs(stacks) do
    for sum = limit, st.count, -1 do
      local prev = best[sum - st.count]
      if prev and not best[sum] then
        local l = { unpack(prev) }; l[#l + 1] = i; best[sum] = l
      end
    end
  end
  for sum = need, limit do if best[sum] then return best[sum], sum - need end end
  -- pas assez dans le coffre : tout ce qu'il y a
  local all = {}
  for i in ipairs(stacks) do all[#all + 1] = i end
  return all, 0
end

function Req.Withdraw()
  if not BF.Bank.IsReady() or running then return end
  local needs = {}   -- [id] = quantité à retirer
  local list = Req.List(function(r) return r.status == "acceptee" and r.by == BF.MyName() end)
  if #list == 0 then return end
  for _, r in ipairs(list) do for id, n in pairs(r.items) do needs[id] = (needs[id] or 0) + n end end
  local before = {}
  for id, n in pairs(needs) do before[id] = bagCount(id); needs[id] = math.max(0, n - before[id]) end
  local free = freeBagSlots()
  -- 1er passage : on prépare tout et on vérifie la place dans les sacs et les retraits restants du coffre
  local plans, slotsNeeded, perTab = {}, 0, {}
  for id, n in pairs(needs) do
    if n > 0 then
      local stacks, total = {}, 0
      for tab = 1, (GetNumGuildBankTabs() or 0) do
        for slot = 1, (MAX_GUILDBANK_SLOTS_PER_TAB or 98) do
          local link = GetGuildBankItemLink(tab, slot)
          local _, count = GetGuildBankItemInfo(tab, slot)
          if link and count and count > 0 and C_Item.GetItemInfoInstant(link) == id then
            stacks[#stacks + 1] = { tab = tab, slot = slot, count = count }; total = total + count
          end
        end
      end
      local picked, extra = pickStacks(stacks, n)
      slotsNeeded = slotsNeeded + #picked + (extra > 0 and 1 or 0)
      for _, i in ipairs(picked) do perTab[stacks[i].tab] = (perTab[stacks[i].tab] or 0) + 1 end
      plans[id] = { stacks = stacks, total = total, picked = picked, extra = extra }
    end
  end
  local problems = {}
  if slotsNeeded > #free then
    problems[#problems + 1] = ("Il faut |cffffffff%d|r case(s) libre(s) dans tes sacs, tu en as |cffffffff%d|r : fais de la place."):format(slotsNeeded, #free)
  end
  for tab, k in pairs(perTab) do
    local name, _, _, _, _, remaining = GetGuildBankTabInfo(tab)
    if remaining and remaining >= 0 and remaining < k then
      problems[#problems + 1] = ("Il te reste |cffffffff%d|r retrait(s) aujourd'hui sur l'onglet %s, il en faut |cffffffff%d|r."):format(remaining, name or tab, k)
    end
  end
  if #problems > 0 then
    Req.withdrawWarning = "|cffff5555Retrait impossible :|r\n" .. table.concat(problems, "\n")
    BF.Print(Req.withdrawWarning:gsub("\n", " "))
    changed()
    return
  end
  Req.withdrawWarning = nil
  for id, n in pairs(needs) do
    local plan = plans[id]
    if plan then
      local stacks, total = plan.stacks, plan.total
      if total < n then BF.Print(("|cffff5555Il manque %d × %s dans la banque.|r"):format(n - total, itemName(id))) end
      local picked, extra = plan.picked, plan.extra
      -- le surplus est recoupé dans la plus grosse pile prise
      local cut
      if extra > 0 then
        for _, i in ipairs(picked) do if not cut or stacks[i].count > stacks[cut].count then cut = i end end
      end
      for _, i in ipairs(picked) do
        local st, spot = stacks[i], nil
        push(function()
          spot = table.remove(free, 1)
          if not spot then error("plus de place dans les sacs") end
          if SetCurrentGuildBankTab then SetCurrentGuildBankTab(st.tab) end
          ClearCursor()
          PickupGuildBankItem(st.tab, st.slot)
          C_Container.PickupContainerItem(spot[1], spot[2])
          BF.Print(("Pris au coffre : pile de %d × %s"):format(st.count, itemName(id)))
        end)
        push(function() end)   -- le coffre refuse les actions trop rapprochées : une pause entre deux piles
        if i == cut then
          -- 1) la pile doit être arrivée dans le sac ; 2) on coupe le surplus dans une autre case vide du sac
          --    (une coupe reste « en attente » tant que le serveur ne l'a pas posée : la déposer directement au
          --    coffre ne marche pas) ; 3) on dépose cette petite pile entière dans la case libérée du coffre.
          local spare
          push(function() end)
          push(function()
            if not spot then return end
            spare = table.remove(free, 1)
            if not spare then error("plus de place dans les sacs pour recouper le surplus") end
            ClearCursor()
            C_Container.SplitContainerItem(spot[1], spot[2], extra)
            C_Container.PickupContainerItem(spare[1], spare[2])
          end)
          push(function() end)
          push(function()
            if not spare then return end
            if SetCurrentGuildBankTab then SetCurrentGuildBankTab(st.tab) end
            ClearCursor()
            C_Container.PickupContainerItem(spare[1], spare[2])
            if CursorHasItem() then PickupGuildBankItem(st.tab, st.slot) end
            ClearCursor()
          end)
          push(function() end); push(function() end)   -- le coffre met un moment à se rafraîchir
          push(function()
            local _, count = GetGuildBankItemInfo(st.tab, st.slot)
            if count and count > 0 then
              BF.Print(("Remis au coffre : %d × %s (surplus)"):format(count, itemName(id)))
            else
              BF.Print(("|cffff5555Le surplus n'a pas pu être remis :|r %d × %s dans tes sacs, glisse-les au coffre."):format(extra, itemName(id)))
            end
          end)
        end
      end
    end
  end
  push(function() end)   -- laisse au serveur le temps de répondre
  push(function()
    ClearCursor()
    local missing = false
    for id, n in pairs(needs) do
      local got = bagCount(id) - (before[id] or 0)
      if got > 0 then withdrawLog[#withdrawLog + 1] = ("Retiré %s"):format(itemLabel(id, got)) end
      if got < n then missing = true end
    end
    for _, r in ipairs(list) do
      local all = true
      for id, n in pairs(r.items) do if bagCount(id) < n then all = false end end
      if all then update(r, "retiree") end
    end
    if missing then
      BF.Print("|cffff5555Le jeu n'a pas laissé l'addon tout retirer :|r glisse les objets manquants du coffre vers tes sacs.")
    else
      BF.Print("|cff33ff33Va à la boîte aux lettres : le courrier sera pré-rempli, tu n'auras plus qu'à cliquer sur Envoyer !|r")
    end
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

-- Retrait bloqué (sacs pleins) : on réessaie tout seul dès que des cases se libèrent, tant que le coffre est ouvert
local retry = CreateFrame("Frame")
retry:RegisterEvent("BAG_UPDATE_DELAYED")
retry:SetScript("OnEvent", function()
  if Req.withdrawWarning and BF.IsOfficer() and BF.Bank.IsReady() then Req.Withdraw() end
end)

-- Mettre des objets précis (quantités exactes) dans des cases d'envoi : courrier ou échange.
-- 1) les piles trop grosses sont d'abord coupées dans une case vide des sacs ; 2) on pose les piles exactes.
local function stacksOf(id)
  local out = {}
  for bag = 0, (NUM_BAG_SLOTS or 4) do
    for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      if info and info.itemID == id and not info.isLocked then out[#out + 1] = { bag, slot, info.stackCount } end
    end
  end
  table.sort(out, function(a, b) return a[3] > b[3] end)
  return out
end

local function fill(items, maxSlots, put, done)   -- put(index) dépose ce qui est sur le curseur
  local targets, free = {}, freeBagSlots()
  for id, n in pairs(items) do
    local left = n
    for _, st in ipairs(stacksOf(id)) do
      if left <= 0 or #targets >= maxSlots then break end
      if st[3] <= left then
        targets[#targets + 1] = { st[1], st[2] }
        left = left - st[3]
      else
        local spot = table.remove(free, 1)
        if not spot then BF.Print("|cffff5555Plus de place dans les sacs pour couper une pile.|r"); break end
        local take = left
        push(function() ClearCursor(); C_Container.SplitContainerItem(st[1], st[2], take)
          C_Container.PickupContainerItem(spot[1], spot[2]) end)
        targets[#targets + 1] = { spot[1], spot[2] }
        left = 0
      end
    end
  end
  if #targets == 0 then return end
  push(function() end)   -- le temps que les piles coupées arrivent
  for i, t in ipairs(targets) do
    push(function() ClearCursor(); C_Container.PickupContainerItem(t[1], t[2]); put(i) end)
  end
  if done then push(done) end
end

Req.Fill = fill                                   -- réutilisé par les commandes de craft (Orders.lua)
function Req.HasDelivery() return Req.List(function(x) return mineToDeliver(x) end)[1] ~= nil end
function Req.HasDeliveryFor(name)
  return Req.List(function(x) return mineToDeliver(x) and short(x.who) == name end)[1] ~= nil
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
      fill(r.items, ATTACHMENTS_MAX_SEND or 12, function(i) ClickSendMailItemButton(i) end, function()
        local got = {}
        for i = 1, (ATTACHMENTS_MAX_SEND or 12) do
          local _, itemID, _, count = GetSendMailItem(i)
          if itemID then got[itemID] = (got[itemID] or 0) + (count or 1) end
        end
        for id, n in pairs(r.items) do
          if (got[id] or 0) ~= n then
            BF.Print(("|cffff5555Vérifie le courrier :|r %s attendu, %d joint."):format(itemLabel(id, n), got[id] or 0))
          end
        end
      end)
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

-- sous-onglets : mes demandes / demandes de la guilde (les demandes se font depuis l'onglet Banque)
local view = "mine"
local views = {}
local switch = {}
local function setView(v) view = v; for k, fr in pairs(views) do fr:SetShown(k == v) end
  for k, b in pairs(switch) do if k == v then b:LockHighlight() else b:UnlockHighlight() end end
  Req.Refresh()
end
local defs = { { "mine", "Mes demandes" }, { "guild", "Demandes de la guilde" } }
for i, d in ipairs(defs) do
  local b = button(panel, d[2], 200, function() setView(d[1]) end)
  b:SetPoint("TOPLEFT", 16 + (i - 1) * 208, -32)
  switch[d[1]] = b
  local fr = CreateFrame("Frame", nil, panel)
  fr:SetPoint("TOPLEFT", 0, -60); fr:SetPoint("BOTTOMRIGHT")
  views[d[1]] = fr
end
-- Discord → jeu : le jeu ne lit les décisions Discord qu'au chargement de l'interface. Bouton pour recharger,
-- avec l'heure de la dernière lecture.
local loadedAt = GetServerTime and GetServerTime() or 0
function BF.DiscordSyncText()
  return "Nouveautés Discord lues " .. BF.Ago(loadedAt)
end
function BF.MakeReloadButton(parent)
  local b = button(parent, "Récupérer Discord", 130, function() ReloadUI() end)
  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText("Récupérer les nouveautés Discord")
    GameTooltip:AddLine("Les demandes et les décisions faites sur Discord n'arrivent dans le jeu qu'au chargement de "
      .. "l'interface. Ce bouton recharge l'interface (comme /reload) pour les récupérer.", 1, 1, 1, true)
    GameTooltip:AddLine(BF.DiscordSyncText() .. ".", 0.6, 0.8, 1, true)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", GameTooltip_Hide)
  return b
end
local syncBtn = BF.MakeReloadButton(panel)
syncBtn:SetPoint("TOPRIGHT", -14, -32)
-- le même bouton dans l'onglet Banque, à gauche de « Vue liste »
if BF.BankPanel and BF.MainFrame.modeBtn then
  local b = BF.MakeReloadButton(BF.BankPanel)
  b:SetPoint("RIGHT", BF.MainFrame.modeBtn, "LEFT", -6, 0)
end
local syncInfo = label(panel, "GameFontDisableSmall")
syncInfo:SetPoint("TOPRIGHT", syncBtn, "BOTTOMRIGHT", 0, -2)

local howTo = label(panel, "GameFontDisableSmall")
howTo:SetPoint("BOTTOMLEFT", 22, 14)
howTo:SetText("Pour demander un objet : onglet |cffffd100Banque|r, clic droit sur l'objet, puis « Faire une demande ».")

local function bankTotals()
  local tot, bank = {}, BF.Bank.Get()
  for _, tab in pairs((bank and bank.tabs) or {}) do
    for _, it in pairs(tab.slots or {}) do tot[it.id] = (tot[it.id] or 0) + it.n end
  end
  return tot
end

-- Fenêtre « Nouvelle demande », à droite de la fenêtre principale ------------------------------------
local cart, cartOrder = {}, {}
local CART_ROWS = 8
local cw = CreateFrame("Frame", "BrowzForeverRequestCart", BF.MainFrame, "BasicFrameTemplateWithInset")
cw:SetSize(380, 400)
cw:SetPoint("TOPLEFT", BF.MainFrame, "TOPRIGHT", 4, 0)
cw:Hide()
cw.title = cw:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
cw.title:SetPoint("TOP", 0, -5); cw.title:SetText("Nouvelle demande")
local cwHint = label(cw, "GameFontDisableSmall")
cwHint:SetPoint("TOPLEFT", 14, -30); cwHint:SetPoint("RIGHT", -14, 0); cwHint:SetWordWrap(true)
cwHint:SetText("Clic gauche sur un objet de la banque : +1. Change la quantité ici.")
local cartRows = {}
local function cartChanged() Req.RefreshCart() end
for i = 1, CART_ROWS do
  local r = CreateFrame("Frame", nil, cw)
  r:SetSize(352, 26); r:SetPoint("TOPLEFT", 14, -52 - (i - 1) * 28)
  r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(22, 22); r.icon:SetPoint("LEFT")
  r.text = label(r); r.text:SetPoint("LEFT", r.icon, "RIGHT", 6, 0); r.text:SetPoint("RIGHT", -150, 0)
  r.qty = CreateFrame("EditBox", nil, r, "InputBoxTemplate")
  r.qty:SetSize(34, 20); r.qty:SetPoint("RIGHT", -88, 0); r.qty:SetAutoFocus(false); r.qty:SetNumeric(true)
  r.qty:SetMaxLetters(4); r.qty:SetJustifyH("CENTER")
  r.qty:SetScript("OnEnterPressed", r.qty.ClearFocus)
  r.qty:SetScript("OnEscapePressed", r.qty.ClearFocus)
  r.qty:SetScript("OnEditFocusLost", function(self)
    if not r.id then return end
    local stock = bankTotals()[r.id] or 0
    local n = math.max(1, math.min(stock, tonumber(self:GetText()) or 1))
    cart[r.id] = n
    cartChanged()
  end)
  -- petits boutons − / + autour de la quantité (jamais moins de 1 ni plus que le stock)
  local function bump(d)
    if not r.id then return end
    local stock = bankTotals()[r.id] or 0
    cart[r.id] = math.max(1, math.min(stock, (cart[r.id] or 1) + d))
    r.qty:ClearFocus()
    cartChanged()
  end
  r.minus = button(r, "-", 20, function() bump(-1) end); r.minus:SetPoint("RIGHT", r.qty, "LEFT", -6, 0)
  r.plus = button(r, "+", 20, function() bump(1) end); r.plus:SetPoint("LEFT", r.qty, "RIGHT", 2, 0)
  r.max = label(r, "GameFontDisableSmall"); r.max:SetPoint("LEFT", r.plus, "RIGHT", 4, 0); r.max:SetWidth(30)
  r.one = label(r, "GameFontHighlight"); r.one:SetPoint("CENTER", r.qty, "CENTER")
  r.del = button(r, "x", 22, function()
    if not r.id then return end
    cart[r.id] = nil
    for k, id in ipairs(cartOrder) do if id == r.id then table.remove(cartOrder, k) break end end
    cartChanged()
  end)
  r.del:SetPoint("RIGHT", 0, 0)
  r:EnableMouse(true)
  r:SetScript("OnEnter", function(self)
    if self.id then
      GameTooltip:SetOwner(self, "ANCHOR_LEFT"); GameTooltip:SetItemByID(self.id)
      GameTooltip:AddLine(" ")
      GameTooltip:AddLine(("En banque : %d (toutes piles confondues)"):format(bankTotals()[self.id] or 0), 1, 0.82, 0)
      GameTooltip:Show()
    end
  end)
  r:SetScript("OnLeave", GameTooltip_Hide)
  cartRows[i] = r
end
local more = label(cw, "GameFontDisableSmall"); more:SetPoint("TOPLEFT", 16, -52 - CART_ROWS * 28)
local whyLabel = label(cw, "GameFontNormal"); whyLabel:SetPoint("TOPLEFT", 16, -52 - CART_ROWS * 28 - 16)
whyLabel:SetText("Explication (ex. « pour monter mon métier »)")
local why = CreateFrame("EditBox", nil, cw, "InputBoxTemplate")
why:SetSize(342, 20); why:SetPoint("TOPLEFT", whyLabel, "BOTTOMLEFT", 6, -4); why:SetAutoFocus(false)
why:SetMaxLetters(150)
why:SetScript("OnEscapePressed", why.ClearFocus)
why:SetScript("OnEnterPressed", why.ClearFocus)
local send = button(cw, "Envoyer la demande", 150, function()
  local items, any = {}, false
  for id, n in pairs(cart) do if n > 0 then items[id] = n; any = true end end
  if not any then BF.Print("Ajoute d'abord des objets (clic gauche sur un objet de la banque)."); return end
  local text = strtrim(why:GetText() or "")
  if text == "" then BF.Print("Écris une petite explication pour les officiers."); return end
  Req.Create(items, text)
  wipe(cart); wipe(cartOrder); why:SetText(""); why:ClearFocus()
  cw:Hide()
end)
send:SetPoint("BOTTOMRIGHT", -12, 12)
local cancel = button(cw, "Annuler", 90, function() wipe(cart); wipe(cartOrder); why:SetText(""); cw:Hide() end)
cancel:SetPoint("RIGHT", send, "LEFT", -6, 0)

function Req.CartAdd(id, n)
  local stock = bankTotals()[id] or 0
  if stock <= 0 then BF.Print(itemName(id) .. " n'est plus dans la banque (d'après le dernier scan)."); return end
  if not cart[id] then cartOrder[#cartOrder + 1] = id end
  local before = cart[id] or 0
  cart[id] = math.min(stock, before + (n or 1))
  if cart[id] == before then BF.Print(("Il n'y a que %d × %s dans la banque."):format(stock, itemName(id))) end
  cw:Show()
  cartChanged()
end

function Req.RefreshCart()
  if not cw:IsShown() then return end
  local tot = bankTotals()
  for i, row in ipairs(cartRows) do
    local id = cartOrder[i]
    row.id = id
    if id then
      local stock = tot[id] or 0
      row.icon:SetTexture(C_Item.GetItemIconByID(id)); row.text:SetText(itemLabel(id))
      local stackable = stock > 1
      row.qty:SetShown(stackable); row.max:SetShown(stackable); row.one:SetShown(not stackable)
      row.minus:SetShown(stackable); row.plus:SetShown(stackable)
      if not row.qty:HasFocus() then row.qty:SetText(tostring(cart[id] or 1)) end
      row.max:SetText("/ " .. stock); row.one:SetText("1")
      row:Show()
    else row:Hide() end
  end
  more:SetText(#cartOrder > CART_ROWS and ("+ %d autre(s) objet(s)"):format(#cartOrder - CART_ROWS) or "")
end
cw:SetScript("OnShow", Req.RefreshCart)

-- Met un lien dans la zone de saisie du chat, en l'ouvrant si besoin (les fonctions ont changé de nom
-- selon les versions du jeu : on essaie les unes après les autres)
function BF.InsertChatLink(link)
  local CFU = _G.ChatFrameUtil
  -- zone de saisie déjà ouverte : on ajoute le lien à la suite du texte
  local insert = (CFU and CFU.InsertLink) or _G.ChatEdit_InsertLink
  if insert then
    local ok, done = pcall(insert, link)
    if ok and done then return end
  end
  -- sinon on ouvre le chat (comme Entrée : dernier canal utilisé) avec le lien déjà écrit dedans
  local open = (CFU and CFU.OpenChat) or _G.ChatFrame_OpenChat
  if open and pcall(open, link) then return end
  BF.Print("Impossible d'ouvrir le chat : appuie sur Entrée puis Maj+clic sur l'objet.")
end

-- Clics sur les objets de l'onglet Banque (UI.lua) : clic droit = menu, clic gauche = +1 si une demande est ouverte
function BF.OnBankItemClick(owner, mouse, id)
  if not id then return false end
  if mouse == "RightButton" then
    if MenuUtil and MenuUtil.CreateContextMenu then
      MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(itemName(id))
        root:CreateButton("Faire une demande", function() Req.CartAdd(id, 1) end)
        root:CreateButton("Lien dans le chat", function()
          -- ouvre la zone de saisie du chat (Guilde si on y écrivait déjà…) avec le lien de l'objet
          local _, link = C_Item.GetItemInfo(id)
          if not link then
            if C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
            BF.Print("Objet pas encore chargé par le jeu : réessaie dans une seconde.")
            return
          end
          C_Timer.After(0.1, function() BF.InsertChatLink(link) end)   -- après la fermeture du menu
        end)
      end)
    else
      Req.CartAdd(id, 1)
    end
    return true
  end
  if mouse == "LeftButton" and cw:IsShown() and not IsModifiedClick() then
    Req.CartAdd(id, 1)
    return true
  end
  return false
end


-- Listes « Mes demandes » et « Demandes de la guilde » ------------------------------------------------
-- Fenêtre de détail d'une demande (clic sur une demande) -----------------------------------------------
local detail
local function statusLine(r)
  local st = STATUS[r.status] or { r.status, "" }
  return st[2] .. st[1] .. "|r" .. ((r.by and r.status ~= "attente" and r.status ~= "annulee") and (" par " .. short(r.by)) or "")
end
function Req.ShowDetail(r)
  if not detail then
    detail = CreateFrame("Frame", "BrowzForeverRequestDetail", UIParent, "BasicFrameTemplateWithInset")
    detail:SetSize(360, 420); detail:SetPoint("CENTER", 0, 40); detail:SetFrameStrata("DIALOG")
    detail:SetMovable(true); detail:EnableMouse(true); detail:RegisterForDrag("LeftButton")
    detail:SetScript("OnDragStart", detail.StartMoving); detail:SetScript("OnDragStop", detail.StopMovingOrSizing)
    detail.title = detail:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); detail.title:SetPoint("TOP", 0, -5)
    detail.head = label(detail); detail.head:SetPoint("TOPLEFT", 16, -32); detail.head:SetPoint("RIGHT", -16, 0)
    detail.head:SetWordWrap(true); detail.head:SetJustifyV("TOP")
    detail.rows = {}
    for i = 1, 8 do
      local row = CreateFrame("Frame", nil, detail)
      row:SetSize(328, 28); row:SetPoint("TOPLEFT", 16, -96 - (i - 1) * 30); row:EnableMouse(true)
      row.icon = row:CreateTexture(nil, "ARTWORK"); row.icon:SetSize(26, 26); row.icon:SetPoint("LEFT")
      row.count = row:CreateFontString(nil, "OVERLAY", "NumberFontNormal"); row.count:SetPoint("BOTTOMRIGHT", row.icon, 2, -2)
      row.text = label(row); row.text:SetPoint("LEFT", row.icon, "RIGHT", 8, 0); row.text:SetPoint("RIGHT")
      row:SetScript("OnEnter", function(self) if self.id then GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetItemByID(self.id); GameTooltip:Show() end end)
      row:SetScript("OnLeave", GameTooltip_Hide)
      detail.rows[i] = row
    end
    detail.why = label(detail); detail.why:SetPoint("TOPLEFT", 16, -342); detail.why:SetPoint("RIGHT", -16, 0)
    detail.why:SetWordWrap(true)
    detail.b1 = button(detail, "Accepter", 100, function() if detail.r then Req.Accept(detail.r) end end)
    detail.b2 = button(detail, "Refuser", 100, function() if detail.r then Req.Refuse(detail.r) end end)
    detail.b2:SetPoint("BOTTOMRIGHT", -12, 12); detail.b1:SetPoint("RIGHT", detail.b2, "LEFT", -6, 0)
    Req.OnChange(function() if detail:IsShown() and detail.r then Req.ShowDetail(db()[detail.r.id] or detail.r) end end)
  end
  detail.r = r
  detail.title:SetText("Demande de " .. short(r.who))
  local when = date("%d/%m à %H:%M", r.t or 0)
  local lines = { "Demandée le " .. when, "Statut : " .. statusLine(r) }
  if r.at and r.at > 0 and r.status ~= "attente" then lines[#lines + 1] = "Décision le " .. date("%d/%m à %H:%M", r.at) end
  detail.head:SetText(table.concat(lines, "\n"))
  local ids = {}
  for id in pairs(r.items) do ids[#ids + 1] = id end
  table.sort(ids, function(a, b) return itemName(a) < itemName(b) end)
  for i, row in ipairs(detail.rows) do
    local id = ids[i]
    row.id = id
    if id then
      row.icon:SetTexture(C_Item.GetItemIconByID(id)); row.count:SetText(r.items[id] > 1 and r.items[id] or "")
      row.text:SetText(itemLabel(id, r.items[id])); row:Show()
    else row:Hide() end
  end
  detail.why:SetText("|cffffd100Explication :|r " .. (r.why or "—"))
  local canDecide = BF.IsOfficer() and r.status == "attente"
  detail.b1:SetShown(canDecide); detail.b2:SetShown(canDecide)
  if not detail.cancel then
    detail.cancel = button(detail, "Annuler la demande", 150, function() if detail.r then Req.Cancel(detail.r) end end)
    detail.cancel:SetPoint("BOTTOMLEFT", 12, 12)
  end
  detail.cancel:SetShown(Req.CanCancel(r) and not canDecide)
  detail:Show()
end

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
    r:EnableMouse(true)
    r:SetScript("OnMouseUp", function(self) if self.r then Req.ShowDetail(self.r) end end)
    r:SetScript("OnEnter", function(self) self.bg:SetColorTexture(1, 1, 1, 0.12) end)
    r:SetScript("OnLeave", function(self) self.bg:SetColorTexture(1, 1, 1, i % 2 == 0 and 0.03 or 0.06) end)
    rows[i] = r
  end
  return rows
end
local mineRows = makeList(views.mine, 6)
local guildRows = makeList(views.guild, 6)
local guildNote = label(views.guild, "GameFontDisable"); guildNote:SetPoint("TOPLEFT", 24, -10)

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
  if mode == "mine" and Req.CanCancel(r) then
    row.b2:SetText("Annuler"); row.b2:Show(); row.act2 = function() Req.Cancel(r) end
  elseif mode == "guild" and BF.IsOfficer() then
    if r.status == "attente" then
      row.b1:SetText("Accepter"); row.b1:Show(); row.act1 = function() Req.Accept(r) end
      row.b2:SetText("Refuser"); row.b2:Show(); row.act2 = function() Req.Refuse(r) end
    elseif Req.CanCancel(r) then
      if mineToDeliver(r) then
        row.b1:SetText("Livrée"); row.b1:Show(); row.act1 = function() Req.Delivered(r, "marquée à la main") end
      end
      row.b2:SetText("Annuler"); row.b2:Show(); row.act2 = function() Req.Cancel(r) end
    end
  end
end

function Req.Refresh()
  if not panel:IsShown() then
    if Req.side and Req.side:IsShown() then Req.RefreshSide() end
    Req.RefreshCart()
    return
  end
  -- listes
  local mine = Req.List(function(r) return r.who == BF.MyName() end)
  for i, row in ipairs(mineRows) do if mine[i] then fillRow(row, mine[i], "mine") else row:Hide() end end
  local open = Req.List(function(r) return not FINAL[r.status] end)
  for i, row in ipairs(guildRows) do if open[i] then fillRow(row, open[i], "guild") else row:Hide() end end
  guildNote:SetText(#open == 0 and "Aucune demande en cours." or (BF.IsOfficer() and "" or "Seuls les officiers peuvent accepter ou refuser."))
  switch.guild:SetText(("Demandes de la guilde (%d)"):format(#open))
  if Req.side and Req.side:IsShown() then Req.RefreshSide() end
  Req.RefreshCart()
end
panel:SetScript("OnShow", function() syncInfo:SetText(BF.DiscordSyncText()); setView(view) end)
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
    s:SetSize(330, 430)
    s.title = s:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    s.title:SetPoint("TOP", 0, -5); s.title:SetText("Browz Forever — Demandes")
    for i = 1, 5 do
      local r = CreateFrame("Frame", nil, s)
      r:SetSize(306, 52); r:SetPoint("TOPLEFT", 12, -30 - (i - 1) * 54)
      r.bg = r:CreateTexture(nil, "BACKGROUND"); r.bg:SetAllPoints(); r.bg:SetColorTexture(1, 1, 1, 0.05)
      r.top = label(r); r.top:SetPoint("TOPLEFT", 6, -4); r.top:SetPoint("RIGHT", -6, 0)
      r.mid = label(r, "GameFontHighlightSmall"); r.mid:SetPoint("TOPLEFT", 6, -20); r.mid:SetPoint("RIGHT", -6, 0)
      r.b1 = button(r, "Accepter", 80, function() if r.r then Req.Accept(r.r) end end); r.b1:SetPoint("BOTTOMRIGHT", -88, 4)
      r.b2 = button(r, "Refuser", 80, function()
        if not r.r then return end
        if r.r.status == "attente" then Req.Refuse(r.r) else Req.Cancel(r.r) end
      end); r.b2:SetPoint("BOTTOMRIGHT", -4, 4)
      r.st = label(r, "GameFontHighlightSmall"); r.st:SetPoint("BOTTOMLEFT", 6, 8)
      r:EnableMouse(true)
      r:SetScript("OnMouseUp", function(self) if self.r then Req.ShowDetail(self.r) end end)
      sideRows[i] = r
    end
    s.log = label(s, "GameFontHighlightSmall"); s.log:SetPoint("TOPLEFT", 16, -306); s.log:SetPoint("RIGHT", -16, 0)
    s.log:SetWordWrap(true); s.log:SetJustifyV("TOP"); s.log:SetHeight(85)
    s.hint = label(s, "GameFontNormalSmall"); s.hint:SetPoint("BOTTOMLEFT", 16, 12); s.hint:SetPoint("RIGHT", -16, 0)
    s.hint:SetWordWrap(true)
    Req.side = s
  end
  Req.side:ClearAllPoints()
  Req.side:SetPoint("TOPLEFT", gb, "TOPRIGHT", 48, 0)   -- à droite des icônes d'onglets du coffre
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
      if not pending then          -- acceptée : on peut encore l'annuler en cas d'erreur
        row.b2:SetText("Annuler"); row.b2:Show()
      else row.b2:SetText("Refuser") end
      row.st:SetText(pending and "" or statusText(r))
      row:Show()
    else row:Hide() end
  end
  local logText = #withdrawLog > 0 and table.concat(withdrawLog, "\n") or ""
  if Req.withdrawWarning then logText = Req.withdrawWarning .. (logText ~= "" and ("\n\n" .. logText) or "") end
  s.log:SetText(logText)
  local ready = #Req.List(function(r) return r.status == "retiree" and r.by == BF.MyName() end) > 0
  s.hint:SetText(ready and "|cff33ff33Va à la boîte aux lettres : tout sera pré-rempli, tu n'auras plus qu'à envoyer !|r"
    or "Accepter retire les objets dans tes sacs.")
end

BF.commands["demandes"] = function() BF.OpenMain("demandes") end

-- Demandes faites sur Discord ------------------------------------------------------------------------
-- Le PC d'un pont reçoit Inbox.lua (écrit par son client) :
--  * requests : demandes faites sur Discord pas encore en jeu. Déjà acceptées par un officier sur Discord →
--    le pont les ajoute directement (acceptées) ; sinon il les annonce (« D ») et le joueur concerné les voit
--    toutes dans une seule fenêtre (Tout ajouter / Tout supprimer / Plus tard).
--  * decisions : Accepter / Refuser cliqués sur Discord pour des demandes déjà en jeu → appliqués par le pont.
local discordPending = {}   -- [id] = demande (statut « discord »)
local asked = {}

local function loadInbox()
  local inbox = _G.BrowzForeverInbox or {}
  for _, x in ipairs(inbox.requests or {}) do
    if x.id and not db()[x.id] then
      local items = {}
      for id, n in pairs(x.items or {}) do items[tonumber(id)] = tonumber(n) end
      local r = { id = x.id, who = x.who, t = x.t or 0, items = items, why = x.why ~= "" and x.why or nil,
        status = "discord", upd = x.upd or x.t or 0 }
      if x.decision == "acceptee" and x.by and x.by ~= "" then
        r.status, r.by, r.at, r.upd = "acceptee", x.by, x.at or GetServerTime(), math.max(GetServerTime(), (r.upd or 0) + 1)
        db()[r.id] = r
        publish(r)
        changed()
      elseif x.decision ~= "refusee" then
        discordPending[x.id] = r
      end
    end
  end
  for _, d in ipairs(inbox.decisions or {}) do
    local r = d.id and db()[d.id]
    if r and r.status == "attente" and (d.status == "acceptee" or d.status == "refusee") then
      update(r, d.status, { by = d.by, at = d.at or GetServerTime() })
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

local waitingMine = {}

-- Fenêtre « Demandes faites sur Discord » : une ligne par demande (Ajouter / Supprimer), et en bas
-- « Tout ajouter » ou « Plus tard » (elles seront reproposées à la prochaine connexion).
local dw, dwRows
local function decideOne(r, status)
  for k, x in ipairs(waitingMine) do if x.id == r.id then table.remove(waitingMine, k) break end end
  if not db()[r.id] then
    r.status, r.upd = status, math.max(GetServerTime(), (r.upd or 0) + 1)
    db()[r.id] = r
    publish(r)
    changed()
  end
  BF.Print(("Demande Discord %s : %s"):format(status == "attente" and "ajoutée" or "supprimée", Req.ItemsText(r.items)))
end

local function showPopup()
  if #waitingMine == 0 then if dw then dw:Hide() end return end
  if not dw then
    dw = CreateFrame("Frame", "BrowzForeverDiscordRequests", UIParent, "BasicFrameTemplateWithInset")
    dw:SetSize(460, 330); dw:SetPoint("CENTER", 0, 80); dw:SetFrameStrata("DIALOG")
    dw:SetMovable(true); dw:EnableMouse(true); dw:RegisterForDrag("LeftButton")
    dw:SetScript("OnDragStart", dw.StartMoving); dw:SetScript("OnDragStop", dw.StopMovingOrSizing)
    dw.title = dw:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); dw.title:SetPoint("TOP", 0, -5)
    dw.title:SetText("Browz Forever — demandes faites sur Discord")
    dw.intro = label(dw); dw.intro:SetPoint("TOPLEFT", 16, -32); dw.intro:SetPoint("RIGHT", -16, 0); dw.intro:SetWordWrap(true)
    dwRows = {}
    for i = 1, 5 do
      local r = CreateFrame("Frame", nil, dw)
      r:SetSize(428, 42); r:SetPoint("TOPLEFT", 16, -58 - (i - 1) * 44)
      r.bg = r:CreateTexture(nil, "BACKGROUND"); r.bg:SetAllPoints(); r.bg:SetColorTexture(1, 1, 1, 0.05)
      r.top = label(r); r.top:SetPoint("TOPLEFT", 6, -5); r.top:SetPoint("RIGHT", -176, 0)
      r.bottom = label(r, "GameFontHighlightSmall"); r.bottom:SetPoint("BOTTOMLEFT", 6, 6); r.bottom:SetPoint("RIGHT", -176, 0)
      r.add = button(r, "Ajouter", 80, function() if r.r then decideOne(r.r, "attente"); showPopup() end end)
      r.add:SetPoint("RIGHT", -88, 0)
      r.del = button(r, "Supprimer", 80, function() if r.r then decideOne(r.r, "annulee"); showPopup() end end)
      r.del:SetPoint("RIGHT", -4, 0)
      r:EnableMouse(true)
      r:SetScript("OnMouseUp", function(self) if self.r then Req.ShowDetail(self.r) end end)
      dwRows[i] = r
    end
    dw.more = label(dw, "GameFontDisableSmall"); dw.more:SetPoint("BOTTOMLEFT", 18, 44)
    dw.all = button(dw, "Tout ajouter", 120, function()
      for _, r in ipairs({ unpack(waitingMine) }) do decideOne(r, "attente") end
      dw:Hide()
    end)
    dw.all:SetPoint("BOTTOMRIGHT", -12, 12)
    dw.later = button(dw, "Plus tard", 100, function() wipe(waitingMine); dw:Hide() end)
    dw.later:SetPoint("RIGHT", dw.all, "LEFT", -6, 0)
  end
  dw.intro:SetText(("Tu as %d demande(s) faite(s) sur Discord. Ajoute-les en jeu pour que les officiers puissent les accepter :")
    :format(#waitingMine))
  for i, row in ipairs(dwRows) do
    local r = waitingMine[i]
    row.r = r
    if r then
      row.top:SetText(("|cffffffff%s|r : %s"):format(short(r.who), Req.ItemsText(r.items)))
      row.bottom:SetText(r.why and ("« " .. r.why .. " »") or "")
      row:Show()
    else row:Hide() end
  end
  dw.more:SetText(#waitingMine > #dwRows and ("+ %d autre(s) (ajoute ou supprime les premières pour les voir)")
    :format(#waitingMine - #dwRows) or "")
  dw:Show()
end

local popupTimer
local function offer(r)
  if asked[r.id] or db()[r.id] or not isMine(r.who) then return end
  asked[r.id] = true
  waitingMine[#waitingMine + 1] = r
  if popupTimer then popupTimer:Cancel() end
  popupTimer = C_Timer.NewTimer(2, function() popupTimer = nil; showPopup() end)   -- on attend un peu : une seule fenêtre pour toutes les demandes
end

BF.OnMessage("D", function(data)
  local r = Req.Parse(data)
  if not r or r.status ~= "discord" then return end
  if not discordPending[r.id] then discordPending[r.id] = r end
  offer(r)
end)
BF.OnMessage("Q", function() C_Timer.After(1 + math.random() * 3, announce) end)

BF.OnActive(function()
  C_Timer.After(4, function()
    loadInbox()
    for _, r in pairs(discordPending) do offer(r) end   -- mes propres demandes Discord (ce PC est un pont)
    announce()
    BF.Send("Q", "1")   -- « avez-vous des demandes Discord pour moi ? »
  end)
end)
