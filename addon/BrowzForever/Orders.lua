-- Browz Forever : commandes de craft (onglet Craft → vue « Commandes »)
-- Déroulé (cahier des charges de Bellock, 28/11) :
--   1. le demandeur choisit une recette (vue Recettes) → quantité + explication ; l'addon dit si tous les composants
--      sont en BDG (« ils seront utilisés ») ou ce qui manque (à déposer en BDG, ou l'artisan s'en charge contre
--      une commission) ; la commande est PUBLIQUE (« ouverte ») ;
--   2. tout artisan qui a le métier et la recette la voit et peut la prendre, avec ou sans commission ;
--      avec commission → « proposée » : le demandeur accepte (→ « prise ») ou refuse (→ de nouveau « ouverte ») ;
--   3. composants en BDG : l'artisan les retire s'il a les droits, sinon un bouton crée une demande de retrait ;
--   4. l'artisan valide le craft (« fabriquée ») ; le demandeur paie la commission par courrier (préparé tout seul)
--      → « payée » ; l'artisan reçoit un courrier de livraison préparé → « livrée ».
--      Les deux connectés : un échange avec l'autre se remplit tout seul (objets d'un côté, commission de l'autre).
-- Tout circule entre membres (message « O ») et part vers Discord par les ponts.
local _, BF = ...
local Ord = {}
BF.Orders = Ord
local Craft = BF.Craft

local DAY = 86400
local STATUS = {
  ouverte   = { "Ouverte", "|cffffd100" },
  proposee  = { "Commission proposée", "|cffff9933" },
  validation = { "À valider par un officier", "|cffff9933" },   -- prise sur Discord par un artisan sans l'addon
  prise     = { "Prise en charge", "|cff66ccff" },
  fabriquee = { "Fabriquée", "|cff66ccff" },
  payee     = { "Payée, à livrer", "|cff66ccff" },
  livree    = { "Livrée", "|cff33ff33" },
  annulee   = { "Annulée", "|cff999999" },
}
local FINAL = { livree = true, annulee = true }
Ord.STATUS = STATUS

local function db() BrowzForeverDB.orders = BrowzForeverDB.orders or {}; return BrowzForeverDB.orders end
local function clean(s) return (tostring(s or ""):gsub("[%^;,~|#@]", " "):sub(1, 200)) end
local function short(name) return (tostring(name or "?"):gsub("%-.*$", "")) end
local function me() return BF.MyName() end
local function money(c) return BF.Money(c or 0) end

-- Format : 1^id^demandeur^heure^métier^recette^quantité^explication^statut^artisan^commission^dernière modif^note
function Ord.Serialize(o)
  return table.concat({ "1", clean(o.id), clean(o.who), o.t or 0, o.prof, o.recipe, o.qty or 1, clean(o.why),
    o.status, clean(o.crafter), o.fee or 0, o.upd or 0, clean(o.note) }, "^")
end

function Ord.Parse(s)
  local v, id, who, t, prof, recipe, qty, why, status, crafter, fee, upd, note = strsplit("^", s)
  if v ~= "1" or not STATUS[status or ""] then return end
  local function opt(x) return (x and x ~= "" and x ~= " ") and x or nil end
  return { id = id, who = who, t = tonumber(t) or 0, prof = tonumber(prof), recipe = tonumber(recipe),
    qty = tonumber(qty) or 1, why = opt(why), status = status, crafter = opt(crafter), fee = tonumber(fee) or 0,
    upd = tonumber(upd) or 0, note = opt(note) }
end

local listeners = {}
local function changed() for _, fn in ipairs(listeners) do pcall(fn) end end
function Ord.OnChange(fn) listeners[#listeners + 1] = fn end

local function store(o)
  local cur = db()[o.id]
  if cur and (cur.upd or 0) >= (o.upd or 0) then return false end
  db()[o.id] = o
  for id, x in pairs(db()) do
    if FINAL[x.status] and GetServerTime() - (x.upd or 0) > 30 * DAY then db()[id] = nil end
  end
  return true
end

local function publish(o)
  local data = Ord.Serialize(o)
  BF.Send("O", data)
  if BF.Bridge.IsOn() then BF.Bridge.Emit("O", data) end
end

local function update(o, status, extra)
  o.status, o.upd = status, math.max(GetServerTime(), (o.upd or 0) + 1)
  for k, v in pairs(extra or {}) do
    if v == false then o[k] = nil else o[k] = v end
  end
  db()[o.id] = o
  publish(o)
  changed()
end

function Ord.List(filter)
  local out = {}
  for _, o in pairs(db()) do if not filter or filter(o) then out[#out + 1] = o end end
  table.sort(out, function(a, b) return (a.t or 0) > (b.t or 0) end)
  return out
end

function Ord.Name(o)
  local n = Craft.RecipeName(o.prof, o.recipe)
  return (o.qty or 1) > 1 and (o.qty .. " × " .. n) or n
end

function Ord.StatusText(o)
  local st = STATUS[o.status] or { o.status, "" }
  return st[2] .. st[1] .. "|r"
end

-- Composants pour toute la commande, avec le stock de la BDG
function Ord.Components(o)
  local list, all = {}, true
  for _, g in ipairs(Craft.Reagents(o.prof, o.recipe)) do
    local need = g.n * (o.qty or 1)
    list[#list + 1] = { id = g.id, n = need, bank = g.bank }
    if g.bank < need then all = false end
  end
  return list, all
end

-- Messages entrants ------------------------------------------------------------------------------
local function notify(o, old)
  if not old or old.status == o.status then return end
  local name = Ord.Name(o)
  if o.who == me() then
    if o.status == "proposee" then
      BF.Print(("%s propose de faire « %s » pour %s : onglet Craft → Commandes pour accepter ou refuser.")
        :format(short(o.crafter), name, money(o.fee)))
    elseif o.status == "prise" then BF.Print(("%s s'occupe de ta commande « %s »."):format(short(o.crafter), name))
    elseif o.status == "fabriquee" then
      BF.Print(("« %s » est fabriqué(e) par %s.%s"):format(name, short(o.crafter),
        (o.fee or 0) > 0 and (" Paie la commission (" .. money(o.fee) .. ") à la boîte aux lettres ou par un échange.") or ""))
    elseif o.status == "livree" then BF.Print(("« %s » t'a été livré(e) par %s."):format(name, short(o.crafter)))
    end
  elseif o.crafter == me() then
    if o.status == "prise" and old.status == "proposee" then
      BF.Print(("%s a accepté ta commission pour « %s »."):format(short(o.who), name))
    elseif o.status == "ouverte" and old.status == "proposee" then
      BF.Print(("%s a refusé ta commission pour « %s » : la commande est de nouveau ouverte."):format(short(o.who), name))
    elseif o.status == "payee" then
      BF.Print(("%s a payé « %s » : va à la boîte aux lettres, le courrier de livraison sera prêt."):format(short(o.who), name))
    elseif o.status == "annulee" then BF.Print(("%s a annulé sa commande « %s »."):format(short(o.who), name))
    end
  end
end

-- Qui peut envoyer cette version d'une commande (messages directs ; les copies du « réveil » ne sont pas vérifiées) :
--   officier ou pont : tout ; demandeur : la créer, refuser/accepter la commission, annuler, payer, livrée (échange) ;
--   artisan : la prendre (lui-même), abandonner, fabriquée, payée sans commission, livrée.
local BY_REQUESTER = { ouverte = true, prise = true, annulee = true, payee = true, livree = true }
local BY_CRAFTER = { proposee = true, prise = true, ouverte = true, fabriquee = true, payee = true, livree = true }
local function allowed(o, sender, cur)
  if not sender then return true end
  if BF.IsOfficerName(sender) or BF.IsBridge(sender) then return true end
  local st = o.status
  if BF.SameName(sender, o.who) and not BF.SameName(sender, o.crafter) then
    if not BY_REQUESTER[st] then return false end
    if st == "prise" then return cur ~= nil and cur.status == "proposee" and BF.SameName(cur.crafter, o.crafter) end
    return true
  end
  local crafterNow, crafterBefore = BF.SameName(sender, o.crafter), cur ~= nil and BF.SameName(sender, cur.crafter)
  if crafterNow or crafterBefore then
    if not BY_CRAFTER[st] then return false end
    if st == "prise" and cur and cur.status == "proposee" then return false end      -- c'est au demandeur d'accepter
    if st == "payee" and (o.fee or 0) > 0 and not (cur and cur.status == "payee") then return false end
    if st == "ouverte" and o.crafter then return false end                            -- abandon = artisan retiré
    return true
  end
  return false
end

function Ord.Receive(data, sender, relayed)
  local o = Ord.Parse(data)
  if not o then return end
  local cur = db()[o.id]
  if not relayed and not allowed(o, sender, cur) then
    BF.Debug(("Commande ignorée : %s ne peut pas la passer à « %s »."):format(tostring(sender), o.status))
    return
  end
  local old = cur and { status = cur.status } or nil
  if store(o) then
    if BF.Bridge.IsOn() then BF.Bridge.Emit("O", data) end
    if not old and o.status == "ouverte" and Craft.CanCraft(me(), o.prof, o.recipe) then
      BF.Print(("Nouvelle commande de craft : %s demande « %s » (onglet Craft → Commandes)."):format(short(o.who), Ord.Name(o)))
    end
    notify(o, old)
    changed()
  end
end
BF.OnMessage("O", function(data, sender) Ord.Receive(data, sender, false) end)

-- Renvoi des commandes en cours (connexion, arrivée d'un pont)
local function resendOpen()
  for _, o in pairs(db()) do
    -- simple renvoi (pas une action) : passe comme une copie relayée (« ZO »)
    if not FINAL[o.status] and (o.who == me() or o.crafter == me()) then BF.Send("ZO", Ord.Serialize(o)) end
  end
end
BF.OnMessage("P", function() C_Timer.After(4 + math.random() * 8, resendOpen) end)
-- Commandes faites ou modifiées sur Discord (boîte de réception écrite par le client du pont, lue au chargement)
local function loadInbox()
  local n = 0
  for _, data in ipairs((_G.BrowzForeverInbox or {}).orders or {}) do
    local o = type(data) == "string" and Ord.Parse(data)
    if o then
      local old = db()[o.id]
      old = old and { status = old.status } or nil
      if store(o) then
        BF.Send("ZO", data)                -- les autres membres la reçoivent aussi (copie relayée)
        notify(o, old)
        n = n + 1
      end
    end
  end
  if n > 0 then BF.Print(("%d commande(s) de craft reprise(s) de Discord."):format(n)); changed() end
end

local lf = CreateFrame("Frame")
lf:RegisterEvent("PLAYER_LOGIN")
lf:SetScript("OnEvent", function()
  C_Timer.After(12, function() if BF.active then loadInbox() end end)
  C_Timer.After(35, function() if BF.active then resendOpen() end end)
end)

-- Actions ----------------------------------------------------------------------------------------
function Ord.Create(prof, recipe, qty, why)
  local now = GetServerTime()
  local o = { id = me() .. "-c" .. now, who = me(), t = now, prof = prof, recipe = recipe, qty = math.max(1, qty or 1),
    why = why, status = "ouverte", fee = 0, upd = now }
  db()[o.id] = o
  publish(o)
  changed()
  BF.Print(("Commande publiée : « %s ». Les artisans de la guilde la voient dans l'onglet Craft."):format(Ord.Name(o)))
  return o
end

function Ord.Take(o, fee)
  fee = math.max(0, math.floor(fee or 0))
  local _, kind = Craft.CanCraft(me(), o.prof, o.recipe)
  local note = (kind == "patron" and "L'artisan doit d'abord obtenir le patron (à farmer ensemble, à acheter à l'HV, ou payé par la commission)")
    or (kind == "apprendre" and "L'artisan doit d'abord apprendre la recette chez un maître") or false
  if fee > 0 then
    update(o, "proposee", { crafter = me(), fee = fee, note = note })
    BF.Print(("Offre envoyée à %s : « %s » contre %s. |cffffd100En attente de sa réponse|r (en jeu ou sur Discord) : "
      .. "tu seras prévenu quand il accepte."):format(short(o.who), Ord.Name(o), money(fee)))
  else
    update(o, "prise", { crafter = me(), fee = 0, note = note })
    BF.Print(("Tu prends « %s » pour %s, sans commission. Clique « Craft fait » une fois l'objet fabriqué.")
      :format(Ord.Name(o), short(o.who)))
  end
end
function Ord.AcceptFee(o) update(o, "prise") end
function Ord.RefuseFee(o) update(o, "ouverte", { crafter = false, fee = 0, note = false }) end
function Ord.GiveUp(o) update(o, "ouverte", { crafter = false, fee = 0, note = false }) end
function Ord.Crafted(o)
  update(o, (o.fee or 0) > 0 and "fabriquee" or "payee")   -- sans commission : directement à livrer
end
function Ord.Paid(o) update(o, "payee") end
function Ord.Delivered(o, how)
  update(o, "livree")
  BF.Print(("Commande « %s » livrée à %s %s."):format(Ord.Name(o), short(o.who), how or ""))
end
function Ord.Cancel(o) update(o, "annulee") end

-- Demande de retrait des composants (artisan sans droits de retrait)
function Ord.RequestComponents(o)
  local items, any = {}, false
  for _, c in ipairs(Ord.Components(o)) do
    local n = math.min(c.n, c.bank)
    if n > 0 then items[c.id] = n; any = true end
  end
  if not any then BF.Print("Aucun composant de cette commande n'est en BDG."); return end
  BF.Requests.Create(items, ("Craft « %s » pour %s"):format(Ord.Name(o), short(o.who)))
end

-- Fenêtre « Nouvelle commande » : s'ouvre à côté de la fenêtre Browz Forever -------------------------
-- Grande icône de l'objet (infobulle du jeu), quantité, composants en icônes (infobulles, stock en BDG),
-- artisans, et une vraie zone de texte pour l'explication.
local NW_W = 340
local nw = CreateFrame("Frame", "BrowzForeverOrderNew", UIParent, "BasicFrameTemplateWithInset")
nw:SetSize(NW_W, 480); nw:SetPoint("CENTER"); nw:SetFrameStrata("DIALOG"); nw:Hide()
nw:SetMovable(true); nw:EnableMouse(true); nw:RegisterForDrag("LeftButton"); nw:SetClampedToScreen(true)
nw:SetScript("OnDragStart", nw.StartMoving); nw:SetScript("OnDragStop", nw.StopMovingOrSizing)
tinsert(UISpecialFrames, "BrowzForeverOrderNew")
nw.title = nw:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); nw.title:SetPoint("TOP", 0, -5)
nw.title:SetText("Demande de craft")

nw.icon = Craft.ItemButton(nw, 44); nw.icon:SetPoint("TOPLEFT", 16, -34)
nw.name = nw:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
nw.name:SetPoint("TOPLEFT", nw.icon, "TOPRIGHT", 10, -2); nw.name:SetPoint("RIGHT", -14, 0); nw.name:SetJustifyH("LEFT")
nw.sub = nw:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
nw.sub:SetPoint("TOPLEFT", nw.name, "BOTTOMLEFT", 0, -4); nw.sub:SetPoint("RIGHT", -14, 0); nw.sub:SetJustifyH("LEFT")
nw.hint = nw:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
nw.hint:SetPoint("TOPLEFT", nw.sub, "BOTTOMLEFT", 0, -2); nw.hint:SetText("Survole l'icône pour voir l'objet")

local qLabel = nw:CreateFontString(nil, "OVERLAY", "GameFontNormal"); qLabel:SetPoint("TOPLEFT", 18, -94)
qLabel:SetText("Quantité")
local minus = CreateFrame("Button", nil, nw, "UIPanelButtonTemplate"); minus:SetSize(22, 20)
minus:SetPoint("LEFT", qLabel, "RIGHT", 14, 0); minus:SetText("-")
nw.qty = CreateFrame("EditBox", nil, nw, "InputBoxTemplate")
nw.qty:SetSize(32, 20); nw.qty:SetPoint("LEFT", minus, "RIGHT", 8, 0); nw.qty:SetAutoFocus(false); nw.qty:SetNumeric(true)
nw.qty:SetJustifyH("CENTER")
local plus = CreateFrame("Button", nil, nw, "UIPanelButtonTemplate"); plus:SetSize(22, 20)
plus:SetPoint("LEFT", nw.qty, "RIGHT", 4, 0); plus:SetText("+")

local cLabel = nw:CreateFontString(nil, "OVERLAY", "GameFontNormal"); cLabel:SetPoint("TOPLEFT", 18, -124)
cLabel:SetText("Composants")
local cHint = nw:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"); cHint:SetPoint("LEFT", cLabel, "RIGHT", 8, 0)
cHint:SetText("(il en faut · en BDG)")
nw.comps = {}
for i = 1, 8 do
  local col, line = (i - 1) % 2, math.floor((i - 1) / 2)
  local b = Craft.ItemButton(nw, 28)
  b:SetPoint("TOPLEFT", 18 + col * 156, -142 - line * 34)
  b.label = nw:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.label:SetPoint("TOPLEFT", b, "TOPRIGHT", 6, -1); b.label:SetWidth(118); b.label:SetJustifyH("LEFT"); b.label:SetWordWrap(false)
  b.stock = nw:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.stock:SetPoint("BOTTOMLEFT", b, "BOTTOMRIGHT", 6, 1)
  b:Hide()
  nw.comps[i] = b
end
nw.compState = nw:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
nw.compState:SetPoint("TOPLEFT", 18, -282); nw.compState:SetPoint("RIGHT", -14, 0)
nw.compState:SetJustifyH("LEFT"); nw.compState:SetJustifyV("TOP"); nw.compState:SetSpacing(2)

nw.who = nw:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
nw.who:SetPoint("TOPLEFT", nw.compState, "BOTTOMLEFT", 0, -6); nw.who:SetPoint("RIGHT", -14, 0)
nw.who:SetJustifyH("LEFT"); nw.who:SetWordWrap(true)

-- zone de texte (plusieurs lignes à l'écran, envoyée sur une seule)
local wLabel = nw:CreateFontString(nil, "OVERLAY", "GameFontNormal")
wLabel:SetPoint("BOTTOMLEFT", 18, 104); wLabel:SetText("Explication")
local wHint = nw:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"); wHint:SetPoint("LEFT", wLabel, "RIGHT", 8, 0)
wHint:SetText("(pour qui, pourquoi, délai…)")
local box = CreateFrame("Frame", nil, nw, "BackdropTemplate")
box:SetPoint("BOTTOMLEFT", 16, 42); box:SetPoint("BOTTOMRIGHT", -16, 42); box:SetHeight(58)
box:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                  tile = true, tileSize = 16, edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
box:SetBackdropColor(0, 0, 0, 0.6); box:SetBackdropBorderColor(0.6, 0.6, 0.6)
nw.why = CreateFrame("EditBox", nil, box)
nw.why:SetMultiLine(true); nw.why:SetAutoFocus(false); nw.why:SetMaxLetters(150)
nw.why:SetFontObject(ChatFontNormal); nw.why:SetPoint("TOPLEFT", 8, -6); nw.why:SetPoint("BOTTOMRIGHT", -8, 6)
nw.why:SetWidth(NW_W - 48)
nw.why.count = box:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"); nw.why.count:SetPoint("BOTTOMRIGHT", -6, 4)
box:EnableMouse(true); box:SetScript("OnMouseDown", function() nw.why:SetFocus() end)

local send = CreateFrame("Button", nil, nw, "UIPanelButtonTemplate"); send:SetSize(130, 24)
send:SetPoint("BOTTOMRIGHT", -14, 12); send:SetText("Publier la demande")
local cancel = CreateFrame("Button", nil, nw, "UIPanelButtonTemplate"); cancel:SetSize(90, 24)
cancel:SetPoint("RIGHT", send, "LEFT", -8, 0); cancel:SetText(CANCEL or "Annuler")
cancel:SetScript("OnClick", function() nw:Hide() end)

local function itemName(id)
  local n = C_Item.GetItemInfo(id)
  if not n and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
  return n or ("objet " .. id)
end

local function refreshNew()
  if not nw.prof then return end
  local q = math.max(1, tonumber(nw.qty:GetText()) or 1)
  local o = { prof = nw.prof, recipe = nw.recipe, qty = q }
  local list, all = Ord.Components(o)
  for i, b in ipairs(nw.comps) do
    local c = list[i]
    if c then
      b:SetItem(c.id, c.n)
      b.label:SetText(itemName(c.id))
      local ok = c.bank >= c.n
      b.stock:SetText(("%s%d|r |cff999999/ %d en BDG|r"):format(ok and "|cff33ff33" or "|cffff5555", c.n, c.bank))
      b:Show(); b.label:Show(); b.stock:Show()
    else
      b:Hide(); b.label:Hide(); b.stock:Hide()
    end
  end
  if #list == 0 then
    nw.compState:SetText("|cff999999Composants inconnus pour cette recette.|r")
  elseif all then
    nw.compState:SetText("|cff33ff33Tout est en BDG : ces composants serviront pour ta commande.|r")
  else
    nw.compState:SetText("|cffff9933Il manque des composants en BDG.|r Dépose-les (la commande se met à jour toute " ..
      "seule), ou l'artisan s'en chargera, éventuellement contre une commission.")
  end
  local names = {}
  for i, w in ipairs(Craft.CraftersFor(nw.prof, nw.recipe)) do
    if i > 4 then names[#names + 1] = "…"; break end
    names[#names + 1] = Craft.Short(w.name) .. (Craft.KIND_TAG[w.kind] or "")
  end
  nw.who:SetText("|cffffd100Artisans :|r " .. (#names > 0 and table.concat(names, ", ") or "aucun connu"))
end
nw.qty:SetScript("OnTextChanged", refreshNew)
minus:SetScript("OnClick", function() nw.qty:SetText(math.max(1, (tonumber(nw.qty:GetText()) or 1) - 1)) end)
plus:SetScript("OnClick", function() nw.qty:SetText(math.min(99, (tonumber(nw.qty:GetText()) or 1) + 1)) end)
nw.why:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
nw.why:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)   -- pas de retour à la ligne : une seule ligne envoyée
nw.why:SetScript("OnTextChanged", function(self) self.count:SetText(#(self:GetText() or "") .. "/150") end)
nw.qty:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
send:SetScript("OnClick", function()
  local why = strtrim(((nw.why:GetText() or ""):gsub("[\r\n]+", " ")))
  if why == "" then BF.Print("Ajoute une petite explication à ta commande."); nw.why:SetFocus(); return end
  Ord.Create(nw.prof, nw.recipe, tonumber(nw.qty:GetText()) or 1, why)
  nw:Hide()
  if Ord.ShowOrders then Ord.ShowOrders() end
end)

function Ord.OpenNew(prof, recipe)
  nw.prof, nw.recipe = prof, recipe
  nw.icon:SetRecipe(prof, recipe)
  nw.name:SetText(Craft.RecipeName(prof, recipe))
  local L = Craft.Lib()
  nw.sub:SetText(("%s · niveau %s · %s"):format(Craft.PROF_NAMES[prof] or prof, (L and L:GetRequiredSkill(prof, recipe)) or "?",
    Craft.CategoryOf(prof, recipe)))
  nw.qty:SetText("1"); nw.why:SetText("")
  -- collée à droite de la fenêtre Browz Forever si elle est ouverte
  nw:ClearAllPoints()
  local main = BF.MainFrame
  if main and main:IsShown() then
    nw:SetPoint("TOPLEFT", main, "TOPRIGHT", 4, 0); nw:SetHeight(480)
  else
    nw:SetPoint("CENTER"); nw:SetHeight(480)
  end
  refreshNew()
  nw:Show()
  nw.why:SetFocus()
end
local nwItems = CreateFrame("Frame")
nwItems:RegisterEvent("GET_ITEM_INFO_RECEIVED")
nwItems:SetScript("OnEvent", function() if nw:IsShown() then refreshNew() end end)

-- Commission : petite fenêtre de saisie (en pièces d'or)
StaticPopupDialogs["BROWZFOREVER_COMMISSION"] = {
  text = "Commission pour « %s » ?\n(en pièces d'or, 0 = gratuit)",
  button1 = "Prendre la commande", button2 = CANCEL or "Annuler",
  hasEditBox = true, editBoxWidth = 80,
  OnShow = function(self)
    local eb = self.editBox or self.EditBox or (self.GetEditBox and self:GetEditBox())
    if eb then eb:SetText("0"); eb:SetFocus(); eb:HighlightText() end
  end,
  OnAccept = function(self, o)
    o = o or self.data
    local eb = self.editBox or self.EditBox or (self.GetEditBox and self:GetEditBox())
    -- (gsub renvoie 2 valeurs : sans les parenthèses, tonumber prenait la 2e comme base et plantait)
    local txt = (((eb and eb:GetText()) or "0"):gsub(",", "."))
    local po = tonumber(txt) or 0
    if not o then BF.Print("Commande introuvable : rouvre l'onglet Craft et réessaie."); return end
    local ok, err = pcall(Ord.Take, o, math.floor(math.max(0, po) * 10000 + 0.5))
    if not ok then BF.Print("Impossible de prendre la commande : " .. tostring(err)) end
  end,
  EditBoxOnEnterPressed = function(eb)
    -- la fenêtre de dialogue : le parent direct, ou plus haut selon les versions du jeu
    local p = eb:GetParent()
    while p and not p.which and p.GetParent do p = p:GetParent() end
    p = p or eb:GetParent()
    StaticPopupDialogs["BROWZFOREVER_COMMISSION"].OnAccept(p, p.data); p:Hide()
  end,
  EditBoxOnEscapePressed = function(eb)
    local p = eb:GetParent()
    while p and not p.which and p.GetParent do p = p:GetParent() end
    if p then p:Hide() end
  end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- Vue « Commandes » dans l'onglet Craft ------------------------------------------------------------
local panel = BF.CraftPanel
if not panel or not Craft.RecipesView then return end
local recipesView = Craft.RecipesView
local view = CreateFrame("Frame", nil, panel)
view:SetAllPoints(panel); view:Hide()

-- bascule Recettes / Commandes (en haut à droite)
local modeBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
modeBtn:SetSize(120, 20); modeBtn:SetPoint("TOPRIGHT", -14, -30)
local function setMode(orders)
  BrowzForeverDB.ui.craftMode = orders and "commandes" or "recettes"
  recipesView:SetShown(not orders); view:SetShown(orders)
  modeBtn:SetText(orders and "Voir les recettes" or "Voir les commandes")
end
modeBtn:SetScript("OnClick", function() setMode(not view:IsShown()) end)
panel:HookScript("OnShow", function() setMode(BrowzForeverDB.ui.craftMode == "commandes") end)
function Ord.ShowOrders() if BF.OpenMain then BF.OpenMain("craft") end; setMode(true) end

local LIST_W, ROW_H, ROWS = 300, 30, 9
local title = view:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 20, -32); title:SetText("Commandes de craft")
local hint = view:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
hint:SetPoint("TOPLEFT", 20, -56); hint:SetWidth(LIST_W); hint:SetJustifyH("LEFT")
hint:SetText("Ouvertes, en cours, et tes commandes terminées récentes")

local rows, list, selected = {}, {}, nil
for i = 1, ROWS do
  local r = CreateFrame("Button", nil, view)
  r:SetSize(LIST_W, ROW_H - 2); r:SetPoint("TOPLEFT", 20, -74 - (i - 1) * ROW_H)
  r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  r.sel = r:CreateTexture(nil, "BACKGROUND"); r.sel:SetAllPoints(); r.sel:SetColorTexture(1, 0.82, 0, 0.15); r.sel:Hide()
  r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(22, 22); r.icon:SetPoint("LEFT", 2, 0)
  r.top = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  r.top:SetPoint("TOPLEFT", r.icon, "TOPRIGHT", 6, 1); r.top:SetPoint("RIGHT", -4, 0); r.top:SetJustifyH("LEFT")
  r.top:SetWordWrap(false); r.top:SetMaxLines(1)
  r.bot = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  r.bot:SetPoint("BOTTOMLEFT", r.icon, "BOTTOMRIGHT", 6, -1); r.bot:SetPoint("RIGHT", -4, 0); r.bot:SetJustifyH("LEFT")
  r.bot:SetWordWrap(false); r.bot:SetMaxLines(1)
  r:Hide()
  rows[i] = r
end
local scroll = CreateFrame("Slider", nil, view, "UIPanelScrollBarTemplate")
scroll:SetPoint("TOPLEFT", rows[1], "TOPRIGHT", 4, -16)
scroll:SetPoint("BOTTOMLEFT", rows[ROWS], "BOTTOMRIGHT", 4, 16)
scroll:SetMinMaxValues(0, 0); scroll:SetValueStep(1); scroll:SetObeyStepOnDrag(true); scroll:SetValue(0)

local DX = LIST_W + 48
local dTitle = view:CreateFontString(nil, "OVERLAY", "GameFontNormal")
dTitle:SetPoint("TOPLEFT", DX, -58); dTitle:SetPoint("RIGHT", -16, 0); dTitle:SetJustifyH("LEFT")
local dText = view:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
dText:SetPoint("TOPLEFT", dTitle, "BOTTOMLEFT", 0, -8); dText:SetPoint("RIGHT", -16, 0)
dText:SetJustifyH("LEFT"); dText:SetJustifyV("TOP"); dText:SetSpacing(2)
local b1 = CreateFrame("Button", nil, view, "UIPanelButtonTemplate"); b1:SetSize(110, 22); b1:SetPoint("BOTTOMRIGHT", -14, 14)
local b2 = CreateFrame("Button", nil, view, "UIPanelButtonTemplate"); b2:SetSize(110, 22); b2:SetPoint("RIGHT", b1, "LEFT", -6, 0)
local b3 = CreateFrame("Button", nil, view, "UIPanelButtonTemplate"); b3:SetSize(190, 22); b3:SetPoint("BOTTOMRIGHT", b1, "TOPRIGHT", 0, 4)

local function visible(o)
  if FINAL[o.status] then
    return (o.who == me() or o.crafter == me()) and GetServerTime() - (o.upd or 0) < 7 * DAY
  end
  if o.status == "ouverte" then return o.who == me() or Craft.CanCraft(me(), o.prof, o.recipe) or BF.IsOfficer() end
  return true
end

local function setButton(b, text, fn)
  if text then b:SetText(text); b:SetScript("OnClick", fn); b:Show() else b:Hide() end
end

local function showDetail()
  local o = selected and db()[selected]
  setButton(b1); setButton(b2); setButton(b3)
  if not o then
    dTitle:SetText("")
    dText:SetText("|cffaaaaaaChoisis une commande.\n\nPour en passer une : « Voir les recettes », choisis une recette, puis " ..
      "« Demander ce craft ».|r")
    return
  end
  dTitle:SetText(Ord.Name(o))
  local lines = {
    ("Demandée par %s le %s"):format(short(o.who), date("%d/%m à %H:%M", o.t)),
    "Statut : " .. Ord.StatusText(o),
  }
  if o.crafter then lines[#lines + 1] = "Artisan : " .. short(o.crafter) end
  if (o.fee or 0) > 0 then lines[#lines + 1] = "Commission : " .. money(o.fee) end
  if o.why then lines[#lines + 1] = "|cffffd100Explication :|r " .. o.why end
  if o.note then lines[#lines + 1] = "|cffff9933" .. o.note .. "|r" end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "|cffffd100Composants|r (il en faut · en BDG)"
  local comps, all = Ord.Components(o)
  for _, c in ipairs(comps) do
    lines[#lines + 1] = ("%s%d × %s|r  (%d)"):format(c.bank >= c.n and "|cff33ff33" or "|cffff5555", c.n, itemName(c.id), c.bank)
  end
  local mine, crafting = o.who == me(), o.crafter == me()
  if not all and (o.status == "ouverte" or o.status == "proposee" or (crafting and o.status == "prise")) then
    lines[#lines + 1] = ""
    if crafting or (o.status == "ouverte" and not mine) then
      lines[#lines + 1] = "|cffff9933Il manque des composants en BDG :|r fournis-les toi-même, vois avec " .. short(o.who) ..
        " pour qu'il/elle les dépose en BDG, ou demande une commission pour te rembourser."
    else
      lines[#lines + 1] = "|cffff9933Il manque des composants en BDG :|r dépose-les en BDG, ou l'artisan s'en chargera " ..
        "(éventuellement contre une commission)."
    end
  end
  dText:SetText(table.concat(lines, "\n"))

  -- boutons selon le rôle et l'étape
  local s = o.status
  if mine then
    if s == "proposee" then
      setButton(b1, "Accepter", function() Ord.AcceptFee(o) end)
      setButton(b2, "Refuser", function() Ord.RefuseFee(o) end)
    elseif s ~= "livree" and s ~= "annulee" and s ~= "payee" then
      setButton(b1, "Annuler", function() Ord.Cancel(o) end)
    end
    if s == "fabriquee" and (o.fee or 0) > 0 then
      setButton(b3, "Payer (boîte aux lettres)", function()
        BF.Print(("Va à la boîte aux lettres : le courrier de %s pour %s sera prêt."):format(money(o.fee), short(o.crafter)))
      end)
    end
  elseif crafting then
    if s == "prise" then
      setButton(b1, "Craft fait", function() Ord.Crafted(o) end)
      setButton(b2, "Abandonner", function() Ord.GiveUp(o) end)
      setButton(b3, "Demander les composants", function() Ord.RequestComponents(o) end)
    elseif s == "proposee" then
      setButton(b2, "Retirer l'offre", function() Ord.GiveUp(o) end)
    elseif s == "payee" then
      setButton(b3, "Livrer (boîte aux lettres)", function()
        BF.Print(("Va à la boîte aux lettres : le courrier pour %s sera prêt."):format(short(o.who)))
      end)
    end
  elseif s == "ouverte" and Craft.CanCraft(me(), o.prof, o.recipe) then
    setButton(b1, "Je m'en charge", function() StaticPopup_Show("BROWZFOREVER_COMMISSION", Ord.Name(o), nil, o) end)
  end
  if BF.IsOfficer() and s == "validation" then
    setButton(b1, "Valider", function() update(o, (o.fee or 0) > 0 and "proposee" or "prise") end)
    setButton(b2, "Refuser", function() update(o, "ouverte", { crafter = false, fee = 0, note = false }) end)
  elseif BF.IsOfficer() and not mine and not crafting and not FINAL[s] then
    setButton(b2, "Annuler (officier)", function() Ord.Cancel(o) end)
  end
end

local function refresh()
  if not view:IsVisible() then return end
  list = Ord.List(visible)
  scroll:SetMinMaxValues(0, math.max(0, #list - ROWS))
  local off = math.floor(scroll:GetValue() + 0.5)
  for i, row in ipairs(rows) do
    local o = list[i + off]
    row.id = o and o.id
    if o then
      local item = Craft.CraftedItem(o.prof, o.recipe)
      row.icon:SetTexture((item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(item)) or 134400)
      row.top:SetText(Ord.Name(o))
      row.bot:SetText(("%s · %s%s"):format(Ord.StatusText(o), short(o.who), o.crafter and (" → " .. short(o.crafter)) or ""))
      row.sel:SetShown(selected == o.id)
      row:Show()
    else row:Hide() end
  end
  if #list == 0 then hint:SetText("Aucune commande pour l'instant.") else hint:SetText("Ouvertes, en cours, et tes commandes terminées récentes") end
  showDetail()
end
Ord.Refresh = refresh

for _, row in ipairs(rows) do
  row:SetScript("OnClick", function(self) selected = self.id; refresh() end)
end
scroll:SetScript("OnValueChanged", refresh)
view:EnableMouseWheel(true)
view:SetScript("OnMouseWheel", function(_, d) scroll:SetValue(scroll:GetValue() - d * 2) end)
view:SetScript("OnShow", refresh)
Ord.OnChange(refresh)
if BF.Bank and BF.Bank.OnChange then BF.Bank.OnChange(refresh) end
local itemFrame = CreateFrame("Frame")
itemFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
local itemPending
itemFrame:SetScript("OnEvent", function()
  if itemPending or not view:IsVisible() then return end
  itemPending = true
  C_Timer.After(0.3, function() itemPending = false; refresh() end)
end)
BF.commands["commandes"] = function() Ord.ShowOrders() end

-- Courrier : paiement de la commission (demandeur) et livraison (artisan) ---------------------------
local function bagCount(id) return (C_Item.GetItemCount and C_Item.GetItemCount(id, false)) or 0 end
local prepared   -- { o = commande, kind = "pay" | "deliver" }

local function prepareMail()
  if BF.Requests.HasDelivery and BF.Requests.HasDelivery() then return end   -- une demande de retrait passe d'abord
  local o = Ord.List(function(x) return x.who == me() and x.status == "fabriquee" and (x.fee or 0) > 0 end)[1]
  local kind = "pay"
  if not o then
    o = Ord.List(function(x) return x.crafter == me() and x.status == "payee" end)[1]
    kind = "deliver"
  end
  if not o then return end
  if kind == "pay" and GetMoney() < o.fee then
    BF.Print(("Commande « %s » : il te manque de l'or pour payer la commission (%s)."):format(Ord.Name(o), money(o.fee)))
    return
  end
  local item = Craft.CraftedItem(o.prof, o.recipe)
  if kind == "deliver" and not (item and bagCount(item) > 0) then
    BF.Print(("Commande « %s » : l'objet fabriqué n'est pas dans tes sacs."):format(Ord.Name(o)))
    return
  end
  C_Timer.After(0.4, function()
    if MailFrameTab_OnClick then pcall(MailFrameTab_OnClick, nil, 2) end
    local to = kind == "pay" and short(o.crafter) or short(o.who)
    if SendMailNameEditBox then SendMailNameEditBox:SetText(to) end
    if SendMailSubjectEditBox then
      SendMailSubjectEditBox:SetText(kind == "pay" and "Browz Forever : commission" or "Browz Forever : ta commande")
    end
    if SendMailBodyEditBox then
      SendMailBodyEditBox:SetText(("Commande : %s\n\nBonne journée de la part de Browz Forever !"):format(Ord.Name(o)))
    end
    if kind == "pay" then
      if SetSendMailMoney then pcall(SetSendMailMoney, o.fee) end
      BF.Print(("Courrier de commission (%s) pour %s pré-rempli : vérifie puis clique sur |cffffd100Envoyer|r.")
        :format(money(o.fee), to))
    else
      local n = math.min(o.qty or 1, bagCount(item))
      BF.Requests.Fill({ [item] = n }, ATTACHMENTS_MAX_SEND or 12, function(i) ClickSendMailItemButton(i) end)
      BF.Print(("Courrier de livraison pour %s pré-rempli : vérifie puis clique sur |cffffd100Envoyer|r."):format(to))
    end
    prepared = { o = o, kind = kind }
  end)
end

local mf = CreateFrame("Frame")
mf:RegisterEvent("MAIL_SHOW")
mf:RegisterEvent("MAIL_SEND_SUCCESS")
mf:RegisterEvent("MAIL_CLOSED")
mf:SetScript("OnEvent", function(_, e)
  if not BF.active then return end
  if e == "MAIL_SHOW" then
    C_Timer.After(0.2, prepareMail)
  elseif e == "MAIL_SEND_SUCCESS" then
    local p = prepared
    prepared = nil
    if p then
      if p.kind == "pay" then
        Ord.Paid(p.o)
        BF.Print(("Commission envoyée à %s."):format(short(p.o.crafter)))
      else
        Ord.Delivered(p.o, "par courrier")
      end
    end
  elseif e == "MAIL_CLOSED" then
    prepared = nil
  end
end)

-- Échange : les deux connectés -------------------------------------------------------------------
local trading, tradeDone
local tf = CreateFrame("Frame")
tf:RegisterEvent("TRADE_SHOW")
tf:RegisterEvent("TRADE_CLOSED")
tf:RegisterEvent("UI_INFO_MESSAGE")
tf:SetScript("OnEvent", function(_, e, a1, a2)
  if not BF.active then return end
  if e == "TRADE_SHOW" then
    trading, tradeDone = nil, false
    local partner = UnitName("NPC")
    if not partner or (BF.Requests.HasDeliveryFor and BF.Requests.HasDeliveryFor(partner)) then return end
    -- artisan : je donne l'objet fabriqué
    local o = Ord.List(function(x)
      return x.crafter == me() and short(x.who) == partner and (x.status == "prise" or x.status == "fabriquee" or x.status == "payee")
    end)[1]
    if o then
      local item = Craft.CraftedItem(o.prof, o.recipe)
      if item and bagCount(item) > 0 then
        trading = o
        C_Timer.After(0.3, function()
          BF.Requests.Fill({ [item] = math.min(o.qty or 1, bagCount(item)) }, MAX_TRADABLE_ITEMS or 6, function(i) ClickTradeButton(i) end)
          BF.Print(("Échange avec %s pré-rempli avec sa commande « %s »%s : vérifie puis clique sur |cffffd100Échanger|r.")
            :format(partner, Ord.Name(o), (o.fee or 0) > 0 and o.status ~= "payee" and (" (commission attendue : " .. money(o.fee) .. ")") or ""))
        end)
      end
      return
    end
    -- demandeur : je paie la commission
    o = Ord.List(function(x)
      return x.who == me() and short(x.crafter or "") == partner and (x.fee or 0) > 0
        and (x.status == "prise" or x.status == "fabriquee")
    end)[1]
    if o then
      trading = o
      C_Timer.After(0.3, function()
        if SetTradeMoney and GetMoney() >= o.fee then pcall(SetTradeMoney, o.fee) end
        BF.Print(("Échange avec %s : commission de %s pour « %s » ajoutée. Vérifie puis clique sur |cffffd100Échanger|r.")
          :format(partner, money(o.fee), Ord.Name(o)))
      end)
    end
  elseif e == "UI_INFO_MESSAGE" then
    if trading and (a2 == ERR_TRADE_COMPLETE or a1 == ERR_TRADE_COMPLETE) then tradeDone = true end
  elseif e == "TRADE_CLOSED" then
    local o = trading
    trading = nil
    C_Timer.After(0.5, function()
      if o and tradeDone then
        -- échange complet = objet remis et commission payée
        if o.crafter == me() then Ord.Delivered(o, "par échange") else update(o, "livree") end
      end
    end)
  end
end)
