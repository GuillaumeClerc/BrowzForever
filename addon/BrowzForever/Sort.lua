-- Browz Forever : bouton « Ranger » du coffre de guilde
-- Clic gauche : range tous les onglets où l'on a le droit de déposer et de retirer.
--   1) objets envoyés vers l'onglet dont le type leur correspond (si des types d'onglet sont choisis)
--   2) piles du même objet fusionnées (le jeu refuse celles venues d'autres royaumes : elles restent séparées)
--   3) tri « intelligent » : patrons, commissions, caisses, composants (étoffes, viandes, herbes… chacun son
--      groupe), consommables, équipement, divers ; rareté décroissante dans chaque groupe ; chaque groupe commence
--      sur une nouvelle colonne du coffre (s'il y a la place), ce qui laisse un espace entre les groupes.
-- Clic droit : choisir le type de l'onglet affiché (Tout, Patrons, Artisanat, Composants, Consommables…).
local _, BF = ...
local Sort = {}
BF.Sort = Sort

local SLOTS = MAX_GUILDBANK_SLOTS_PER_TAB or 98
local ROWS = 7                                   -- le coffre affiche les cases par colonnes de 7
local COLS = math.floor(SLOTS / ROWS)
local STEP = 0.5                                 -- le coffre refuse les actions trop rapprochées

-- Types d'onglet ---------------------------------------------------------------------------------
local FILTERS = {
  { key = "tout", label = "Tout (pas de type)" },
  { key = "patrons", label = "Patrons et recettes" },
  { key = "artisanat", label = "Artisanat (commissions, caisses…)" },
  { key = "composants", label = "Composants (étoffes, viandes, herbes…)" },
  { key = "consommables", label = "Consommables" },
  { key = "equipement", label = "Équipement" },
  { key = "divers", label = "Divers" },
}
local FILTER_LABEL = {}
for _, f in ipairs(FILTERS) do FILTER_LABEL[f.key] = f.label end

local function filters()
  BrowzForeverDB.ui.tabFilters = BrowzForeverDB.ui.tabFilters or {}
  return BrowzForeverDB.ui.tabFilters
end
function Sort.TabFilter(tab) return filters()[tab] or "tout" end

-- Infos sur un objet : groupe, ordre, catégorie --------------------------------------------------
local infoCache = {}
local function info(id, link)
  local c = infoCache[id]
  if c and c.name then return c end
  local name, _, quality, _, _, _, _, maxStack, _, _, _, classID, subID = C_Item.GetItemInfo(link or id)
  if not classID then
    local _, _, _, _, _, cid, sid = C_Item.GetItemInfoInstant(id)
    classID, subID = cid, sid
  end
  if not name and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
  name = name or ""
  local prefix = name:match("^(.-)%s*:%s")       -- « Caisse détournée : minerai… » → « Caisse détournée »
  local order, group, cat
  if classID == 9 then
    order, group, cat = 1, "patrons", "patrons"
  elseif prefix and prefix ~= "" then
    order = prefix:lower():find("commission") and 2 or 3
    group, cat = "p:" .. prefix, "artisanat"
  elseif classID == 7 then
    order, group, cat = 4, "c7:" .. (subID or 0), "composants"          -- étoffes, viandes, herbes… séparées
  elseif classID == 0 then
    order, group, cat = 5, "c0:" .. (subID or 0), "consommables"
  elseif classID == 2 or classID == 4 then
    order, group, cat = 6, "equipement", "equipement"
  else
    order, group, cat = 7, "c" .. (classID or 99), "divers"
  end
  c = { name = name ~= "" and name or nil, sortName = name, quality = quality or 1, maxStack = maxStack,
        order = order, group = group, cat = cat, sub = subID or 0 }
  infoCache[id] = c
  return c
end

-- Lecture d'un onglet -----------------------------------------------------------------------------
local function readTab(tab)
  local slots = {}
  for s = 1, SLOTS do
    local _, count = GetGuildBankItemInfo(tab, s)
    local link = count and count > 0 and GetGuildBankItemLink(tab, s)
    if link then
      local id = C_Item.GetItemInfoInstant(link)
      if id then slots[s] = { id = id, count = count, link = link } end
    end
  end
  return slots
end

-- Disposition voulue : [case] = id (ou nil = vide)
local function desired(slots)
  local list = {}
  for _, it in pairs(slots) do
    local i = info(it.id, it.link)
    list[#list + 1] = { id = it.id, count = it.count, i = i }
  end
  table.sort(list, function(a, b)
    if a.i.order ~= b.i.order then return a.i.order < b.i.order end
    if a.i.group ~= b.i.group then return a.i.group < b.i.group end
    if a.i.sub ~= b.i.sub then return a.i.sub < b.i.sub end
    if a.i.quality ~= b.i.quality then return a.i.quality > b.i.quality end
    if a.i.sortName ~= b.i.sortName then return a.i.sortName < b.i.sortName end
    if a.id ~= b.id then return a.id < b.id end
    return a.count > b.count
  end)
  -- groupes consécutifs
  local groups, last = {}, nil
  for _, e in ipairs(list) do
    if e.i.group ~= last then groups[#groups + 1] = {}; last = e.i.group end
    table.insert(groups[#groups], e.id)
  end
  local cols = 0
  for _, g in ipairs(groups) do cols = cols + math.ceil(#g / ROWS) end
  local gaps = cols <= COLS                       -- assez de place pour démarrer chaque groupe sur une colonne
  local want, pos = {}, 1
  for _, g in ipairs(groups) do
    if gaps and (pos - 1) % ROWS ~= 0 then pos = (math.floor((pos - 1) / ROWS) + 1) * ROWS + 1 end
    for _, id in ipairs(g) do want[pos] = id; pos = pos + 1 end
  end
  return want
end

-- Moteur : une action par pas, relecture du coffre à chaque pas -----------------------------------
local job                                        -- rangement en cours
local button

local function stop(msg)
  if not job then return end
  ClearCursor()
  if job.startTab and SetCurrentGuildBankTab then pcall(SetCurrentGuildBankTab, job.startTab) end
  job = nil
  if msg then BF.Print(msg) end
  if button then button:Update() end
end

local function canSort(tab)
  local _, _, viewable, canDeposit, numWithdrawals, remaining = GetGuildBankTabInfo(tab)
  return viewable and canDeposit and (numWithdrawals or 0) ~= 0, remaining
end

local function show(tab) if SetCurrentGuildBankTab and GetCurrentGuildBankTab() ~= tab then SetCurrentGuildBankTab(tab) end end

local function move(fromTab, fromSlot, toTab, toSlot)
  ClearCursor()
  show(fromTab)
  PickupGuildBankItem(fromTab, fromSlot)
  if toTab ~= fromTab then show(toTab) end
  PickupGuildBankItem(toTab, toSlot)
  job.moves = job.moves + 1
end

-- 1) objets à envoyer dans l'onglet de leur type
local function stepTabs()
  local f = filters()
  local claimed = {}                             -- [catégorie] = onglet
  for _, tab in ipairs(job.tabs) do
    local k = f[tab]
    if k and k ~= "tout" and not claimed[k] then claimed[k] = tab end
  end
  if not next(claimed) then return false end
  for _, tab in ipairs(job.tabs) do
    local here = f[tab] or "tout"
    local slots = readTab(tab)
    for s = 1, SLOTS do
      local it = slots[s]
      if it and not job.skip[tab .. ":" .. s] then
        local cat = info(it.id, it.link).cat
        local dest = claimed[cat]
        if dest and dest ~= tab and here ~= cat then
          local _, remaining = canSort(tab)
          if remaining == 0 then
            BF.Print(("Plus de retraits aujourd'hui sur l'onglet %d : les objets à changer d'onglet y restent."):format(tab))
            return false
          end
          local destSlots, free = readTab(dest), nil
          for u = SLOTS, 1, -1 do if not destSlots[u] then free = u break end end
          if not free then
            job.skip[tab .. ":" .. s] = true
            if not job.full[dest] then
              job.full[dest] = true
              BF.Print(("L'onglet %d (%s) est plein."):format(dest, FILTER_LABEL[cat] or cat))
            end
          else
            job.check = { tab = tab, slot = s, id = it.id, kind = "onglet" }
            move(tab, s, dest, free)
            return true
          end
        end
      end
    end
  end
  return false
end

-- 2) fusion des piles incomplètes du même objet
local function stepMerge(tab)
  local slots = readTab(tab)
  local partial = {}
  for s, it in pairs(slots) do
    local max = info(it.id, it.link).maxStack
    if max and max > 1 and it.count < max then
      partial[it.id] = partial[it.id] or {}
      table.insert(partial[it.id], s)
    end
  end
  for id, list in pairs(partial) do
    if #list >= 2 then
      table.sort(list, function(a, b) return slots[a].count < slots[b].count end)
      for a = 1, #list - 1 do
        for b = #list, a + 1, -1 do
          local src, dst = list[a], list[b]
          local key = tab .. ":" .. math.min(src, dst) .. ":" .. math.max(src, dst)
          if not job.failedMerge[key] and (job.failId[id] or 0) < 2 then
            job.check = { tab = tab, slot = src, id = id, count = slots[src].count, key = key, kind = "fusion" }
            move(tab, src, tab, dst)
            return true
          end
        end
      end
    end
  end
  return false
end

-- 3) mise en ordre
local function stepOrder(tab)
  local slots = readTab(tab)
  local want = desired(slots)
  for t = 1, SLOTS do
    local w, occ = want[t], slots[t]
    if w and not (occ and occ.id == w) and not job.skip[tab .. ":" .. t] then
      for s = 1, SLOTS do
        local it = slots[s]
        if s ~= t and it and it.id == w and want[s] ~= it.id then
          job.check = { tab = tab, slot = t, id = w, kind = "ordre" }
          move(tab, s, tab, t)
          return true
        end
      end
      job.skip[tab .. ":" .. t] = true          -- rien à mettre là (ne devrait pas arriver)
    end
  end
  return false
end

-- Vérifie que l'action précédente a marché (sinon on ne la refait pas)
local function verify()
  local c = job.check
  if not c then return end
  job.check = nil
  local slots = readTab(c.tab)
  local it = slots[c.slot]
  if c.kind == "fusion" then
    if it and it.id == c.id and it.count == c.count then
      -- refusée (piles d'autres royaumes) : après 2 refus pour un objet, on n'insiste plus (une erreur rouge à chaque fois)
      job.failedMerge[c.key] = true; job.refused = job.refused + 1
      job.failId[c.id] = (job.failId[c.id] or 0) + 1
    end
  elseif c.kind == "onglet" then
    if it and it.id == c.id then job.skip[c.tab .. ":" .. c.slot] = true; job.failed = job.failed + 1 end
  elseif c.kind == "ordre" then
    if not (it and it.id == c.id) then
      job.skip[c.tab .. ":" .. c.slot] = true; job.failed = job.failed + 1
    end
  end
end

local function step()
  if not job then return end
  if not BF.Bank.IsReady() then stop("Rangement arrêté : coffre fermé."); return end
  ClearCursor()
  verify()
  if job.moves >= 400 then stop("|cffff5555Rangement arrêté :|r trop de déplacements."); return end
  local acted = false
  if job.phase == "onglets" then
    acted = stepTabs()
    if not acted then job.phase, job.ti = "fusion", 1 end
  end
  while not acted and job.ti <= #job.tabs do
    local tab = job.tabs[job.ti]
    if job.phase == "fusion" then
      acted = stepMerge(tab)
      if not acted then job.phase = "ordre" end
    elseif job.phase == "ordre" then
      acted = stepOrder(tab)
      if not acted then job.phase, job.ti = "fusion", job.ti + 1 end
    end
  end
  if acted then
    C_Timer.After(STEP, step)
  else
    local extra = {}
    if job.refused > 0 then extra[#extra + 1] = ("%d fusion(s) refusée(s) par le jeu (piles d'autres royaumes)"):format(job.refused) end
    if job.failed > 0 then extra[#extra + 1] = ("%d déplacement(s) refusé(s)"):format(job.failed) end
    stop(("|cff33ff33Coffre rangé|r (%d déplacement(s))%s."):format(job.moves,
      #extra > 0 and (" — " .. table.concat(extra, ", ")) or ""))
  end
end

function Sort.Start()
  if job then stop("Rangement annulé."); return end
  if not BF.Bank.IsReady() then BF.Print("Ouvre le coffre de guilde d'abord."); return end
  if InCombatLockdown() then BF.Print("Pas pendant un combat."); return end
  local tabs = {}
  for t = 1, (GetNumGuildBankTabs() or 0) do if canSort(t) then tabs[#tabs + 1] = t end end
  if #tabs == 0 then BF.Print("Tu n'as le droit de ranger aucun onglet (il faut pouvoir déposer et retirer)."); return end
  -- charge les infos des objets avant de trier (noms, types)
  for _, t in ipairs(tabs) do for _, it in pairs(readTab(t)) do info(it.id, it.link) end end
  job = { tabs = tabs, ti = 1, phase = "onglets", moves = 0, refused = 0, failed = 0,
          skip = {}, failedMerge = {}, failId = {}, full = {}, startTab = GetCurrentGuildBankTab and GetCurrentGuildBankTab() }
  wipe(infoCache)                                -- relu proprement maintenant que les infos arrivent
  BF.Print(("Rangement du coffre (%d onglet(s))… clique à nouveau sur le bouton pour arrêter."):format(#tabs))
  if button then button:Update() end
  C_Timer.After(1, step)                         -- laisse arriver les infos des objets
end

BF.Bank.OnClosed(function() if job then stop("Rangement arrêté : coffre fermé.") end end)

-- Bouton sur la fenêtre du coffre ------------------------------------------------------------------
local function filterMenu(owner)
  local tab = GetCurrentGuildBankTab and GetCurrentGuildBankTab() or 1
  if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
  MenuUtil.CreateContextMenu(owner, function(_, root)
    root:CreateTitle(("Type de l'onglet %d"):format(tab))
    for _, f in ipairs(FILTERS) do
      root:CreateRadio(f.label, function() return Sort.TabFilter(tab) == f.key end, function()
        filters()[tab] = f.key ~= "tout" and f.key or nil
        BF.Print(("Onglet %d : %s"):format(tab, f.label))
      end)
    end
  end)
end

local function makeButton()
  local gb = _G.GuildBankFrame
  if button or not gb then return end
  button = CreateFrame("Button", "BrowzForeverSortButton", gb)
  button:SetSize(28, 26)
  local search = gb.SearchBox or _G.GuildItemSearchBox
  if search then button:SetPoint("RIGHT", search, "LEFT", -8, 0)
  else button:SetPoint("TOPRIGHT", gb, "TOPRIGHT", -150, -40) end
  button:SetFrameLevel(gb:GetFrameLevel() + 60)    -- au-dessus du voile de chargement
  local ok = pcall(function()
    button:SetNormalAtlas("bags-button-autosort-up")
    button:SetPushedAtlas("bags-button-autosort-down")
  end)
  if not ok or not button:GetNormalTexture() then
    button:SetNormalTexture("Interface\\Icons\\INV_Misc_Bag_10")
  end
  button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
  button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  button:SetScript("OnClick", function(self, mouse)
    if mouse == "RightButton" then filterMenu(self) else Sort.Start() end
  end)
  function button:Update()
    local t = self:GetNormalTexture()
    if t then t:SetVertexColor(job and 0.4 or 1, 1, job and 0.4 or 1) end   -- vert pendant le rangement
  end
  button:SetScript("OnEnter", function(self)
    local tab = GetCurrentGuildBankTab and GetCurrentGuildBankTab() or 1
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(job and "Rangement en cours…" or "Ranger le coffre")
    GameTooltip:AddLine("Clic gauche : trie les onglets par type et par rareté, et regroupe les piles.", 1, 1, 1, true)
    GameTooltip:AddLine("Clic droit : choisir le type de cet onglet (les objets de ce type y seront envoyés).", 1, 1, 1, true)
    GameTooltip:AddLine(("Onglet %d : %s"):format(tab, FILTER_LABEL[Sort.TabFilter(tab)]), 1, 0.82, 0)
    if job then GameTooltip:AddLine("Clique pour arrêter.", 1, 0.4, 0.4) end
    GameTooltip:Show()
  end)
  button:SetScript("OnLeave", GameTooltip_Hide)
end

BF.Bank.OnLoaded(function() makeButton(); if button then button:Show(); button:Update() end end)
BF.commands["ranger"] = function() Sort.Start() end
