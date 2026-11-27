-- Browz Forever : fenêtre principale (onglets en bas) — ce fichier crée la fenêtre et l'onglet BDG
-- (vue Coffre en grille par onglet ou vue Liste triée par catégorie). Les autres onglets : Panels.lua
local _, BF = ...

local QUESTION_ICON = 134400 -- point d'interrogation des macros
local CATS = {
  { key = 9, label = "Plans et recettes" },
  { key = 7, label = "Composants d'artisanat" },
  { key = 0, label = "Consommables" },
  { key = "other", label = "Autres" },
}

-- Dimensions
local ROW_H = 20
local SLOT, GAP, GROUP_GAP = 34, 3, 8           -- grille : 7 colonnes de 2×7 cases, comme le coffre
local GRID_W = 20 + 14 * (SLOT + GAP) + 6 * GROUP_GAP
local TOP = 108                                  -- hauteur de l'en-tête (titre, or, recherche, onglets)
local GRID_H = TOP + 7 * (SLOT + GAP) + 14
local LIST_W = GRID_W
local ROWS = math.floor((GRID_H - (TOP - 28) - 14) / ROW_H)   -- la liste remplit la même fenêtre

local state = { mode = "grid", tab = 1 }

local f = CreateFrame("Frame", "BrowzForeverBankFrame", UIParent, "BasicFrameTemplateWithInset")
f:SetFrameStrata("HIGH")
f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
f:SetClampedToScreen(true)
f:Hide()
tinsert(UISpecialFrames, "BrowzForeverBankFrame")
f:SetScript("OnDragStart", f.StartMoving)
f:SetScript("OnDragStop", function(self)
  self:StopMovingOrSizing()
  local x, y = self:GetCenter()
  BrowzForeverDB.ui.pos = { x = x, y = y }
end)

f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
f.title:SetPoint("TOP", 0, -5)
f.title:SetText("Browz Forever")
f:SetSize(GRID_W, GRID_H)

-- Panneau de l'onglet BDG (les autres onglets ont le leur, voir Panels.lua)
local bdg = CreateFrame("Frame", nil, f)
bdg:SetAllPoints(f)
BF.MainFrame, BF.BankPanel = f, bdg

f.info = bdg:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
f.info:SetPoint("TOPLEFT", 14, -32); f.info:SetPoint("TOPRIGHT", -110, -32)
f.info:SetJustifyH("LEFT")

f.modeBtn = CreateFrame("Button", nil, bdg, "UIPanelButtonTemplate")
f.modeBtn:SetSize(92, 20)
f.modeBtn:SetPoint("TOPRIGHT", -12, -28)

f.search = CreateFrame("EditBox", nil, bdg, "InputBoxTemplate")
f.search:SetHeight(20)
f.search:SetPoint("TOPLEFT", 20, -52); f.search:SetPoint("TOPRIGHT", -16, -52)
f.search:SetAutoFocus(false)
f.search.hint = f.search:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
f.search.hint:SetPoint("LEFT", 4, 0)
f.search.hint:SetText("Rechercher un objet…")

-- Outils objets -----------------------------------------------------------------
local function itemName(id)
  local name = C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)
  if not name and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
  return name
end
local function itemIcon(id) return C_Item.GetItemIconByID(id) or QUESTION_ICON end
local function qualityColor(id)
  local q = C_Item.GetItemQualityByID and C_Item.GetItemQualityByID(id)
  local c = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
  return c, q
end
local function matches(id)
  local filter = strlower(f.search:GetText() or "")
  if filter == "" then return true end
  local name = itemName(id)
  return name and strlower(name):find(filter, 1, true) and true or false
end
local function showItemTooltip(owner, id, extra)
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  GameTooltip:SetItemByID(id)
  if extra then
    GameTooltip:AddLine(" ")
    for _, l in ipairs(extra) do GameTooltip:AddLine(l[1], l[2], l[3], l[4]) end
  end
  GameTooltip:Show()
end
local function chatLink(id)
  if IsModifiedClick("CHATLINK") then
    local _, link = C_Item.GetItemInfo(id)
    if link then ChatEdit_InsertLink(link) end
  end
end

-- Onglets de la banque (boutons) ---------------------------------------------------------
local tabButtons = {}
local function tabButton(i)
  local b = tabButtons[i]
  if b then return b end
  b = CreateFrame("Button", nil, bdg, "UIPanelButtonTemplate")
  b:SetHeight(20)
  b:SetScript("OnClick", function() state.tab = i; BrowzForeverDB.ui.tab = i; f.Refresh() end)
  tabButtons[i] = b
  return b
end

-- Vue Coffre -----------------------------------------------------------------------------
local grid = CreateFrame("Frame", nil, bdg)
grid:SetPoint("TOPLEFT", 10, -TOP)
grid:SetSize(GRID_W - 20, 7 * (SLOT + GAP))
local slots = {}
for s = 1, 98 do
  local col = math.floor((s - 1) / 14)          -- colonne du coffre (0 à 6)
  local j = (s - 1) % 14
  local sub, row = math.floor(j / 7), j % 7       -- 2 sous-colonnes de 7 cases
  local x = (col * 2 + sub) * (SLOT + GAP) + col * GROUP_GAP
  local b = CreateFrame("Button", nil, grid)
  b:SetSize(SLOT, SLOT)
  b:SetPoint("TOPLEFT", x, -row * (SLOT + GAP))
  b.bg = b:CreateTexture(nil, "BACKGROUND")
  b.bg:SetAllPoints(); b.bg:SetTexture("Interface\\PaperDoll\\UI-Backpack-EmptySlot")
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetPoint("TOPLEFT", 2, -2); b.icon:SetPoint("BOTTOMRIGHT", -2, 2)
  b.border = b:CreateTexture(nil, "OVERLAY")
  b.border:SetAllPoints(); b.border:SetTexture("Interface\\Common\\WhiteIconFrame")
  b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
  b.count:SetPoint("BOTTOMRIGHT", -3, 3)
  b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
  b:SetScript("OnEnter", function(self)
    if self.item then showItemTooltip(self, self.item.id) end
  end)
  b:SetScript("OnLeave", GameTooltip_Hide)
  b:SetScript("OnClick", function(self) if self.item then chatLink(self.item.id) end end)
  slots[s] = b
end

local function refreshGrid(bank)
  local tab = bank and bank.tabs[state.tab]
  for s = 1, 98 do
    local b, it = slots[s], tab and tab.slots and tab.slots[s]
    b.item = it
    if it then
      b.icon:SetTexture(itemIcon(it.id)); b.icon:Show()
      b.count:SetText(it.n > 1 and it.n or "")
      local c, q = qualityColor(it.id)
      if c and q and q >= 2 then b.border:SetVertexColor(c.r, c.g, c.b); b.border:Show() else b.border:Hide() end
      local hit = matches(it.id)
      b.icon:SetDesaturated(not hit); b.icon:SetAlpha(hit and 1 or 0.3)
    else
      b.icon:Hide(); b.border:Hide(); b.count:SetText("")
    end
  end
  if tab and not tab.viewable then
    f.empty:SetText("Onglet non visible pour le membre qui a fait le scan."); f.empty:Show()
  else f.empty:Hide() end
end

-- Vue Liste ------------------------------------------------------------------------------
local listFrame = CreateFrame("Frame", nil, bdg)
listFrame:SetPoint("TOPLEFT", 10, -TOP + 28)
listFrame:SetSize(LIST_W - 42, ROW_H * ROWS)
local scroll = CreateFrame("ScrollFrame", "BrowzForeverBankScroll", listFrame, "FauxScrollFrameTemplate")
scroll:SetAllPoints()
local list, rows = {}, {}

local function buildList(bank)
  wipe(list)
  if not bank then return end
  local tot, where = {}, {}
  for _, tab in ipairs(bank.tabs) do
    for id, n in pairs(tab.items) do
      tot[id] = (tot[id] or 0) + n
      where[id] = where[id] or {}
      where[id][#where[id] + 1] = tab.name .. " ×" .. n
    end
  end
  local groups = {}
  for id, n in pairs(tot) do
    if matches(id) then
      local classID = select(6, C_Item.GetItemInfoInstant(id))
      local key = (classID == 9 or classID == 7 or classID == 0) and classID or "other"
      groups[key] = groups[key] or {}
      table.insert(groups[key], { id = id, n = n, name = itemName(id) or ("Objet #" .. id), where = where[id] })
    end
  end
  for _, c in ipairs(CATS) do
    local g = groups[c.key]
    if g then
      table.sort(g, function(a, b) return a.name < b.name end)
      list[#list + 1] = { header = c.label .. " (" .. #g .. ")" }
      for _, it in ipairs(g) do list[#list + 1] = it end
    end
  end
end

local function refreshList()
  FauxScrollFrame_Update(scroll, #list, ROWS, ROW_H)
  local offset = FauxScrollFrame_GetOffset(scroll)
  for i = 1, ROWS do
    local r, e = rows[i], list[i + offset]
    r.entry = e
    if not e then r:Hide()
    elseif e.header then
      r.icon:Hide(); r.count:SetText("")
      r.text:SetText("|cffffd100" .. e.header .. "|r"); r:Show()
    else
      r.icon:SetTexture(itemIcon(e.id)); r.icon:Show()
      local c = qualityColor(e.id)
      r.text:SetText((c and c.hex or "|cffffffff") .. e.name .. "|r")
      r.count:SetText(e.n); r:Show()
    end
  end
end

for i = 1, ROWS do
  local r = CreateFrame("Button", nil, listFrame)
  r:SetSize(LIST_W - 42, ROW_H)
  r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
  r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  r.icon = r:CreateTexture(nil, "ARTWORK")
  r.icon:SetSize(16, 16); r.icon:SetPoint("LEFT", 4, 0)
  r.count = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  r.count:SetPoint("RIGHT", -6, 0)
  r.text = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  r.text:SetPoint("LEFT", r.icon, "RIGHT", 6, 0); r.text:SetPoint("RIGHT", r.count, "LEFT", -6, 0)
  r.text:SetJustifyH("LEFT")
  r:SetScript("OnEnter", function(self)
    local e = self.entry
    if not e or e.header then return end
    local extra = { { "En banque : " .. e.n, 1, 0.82, 0 } }
    for _, w in ipairs(e.where or {}) do extra[#extra + 1] = { "  " .. w, 0.8, 0.8, 0.8 } end
    showItemTooltip(self, e.id, extra)
  end)
  r:SetScript("OnLeave", GameTooltip_Hide)
  r:SetScript("OnClick", function(self) local e = self.entry; if e and not e.header then chatLink(e.id) end end)
  rows[i] = r
end
scroll:SetScript("OnVerticalScroll", function(self, offset)
  FauxScrollFrame_OnVerticalScroll(self, offset, ROW_H, refreshList)
end)

f.empty = bdg:CreateFontString(nil, "OVERLAY", "GameFontDisable")
f.empty:SetPoint("CENTER", 0, -30)

-- Rafraîchissement général ---------------------------------------------------------------
function f.Refresh()
  if not f:IsShown() or not bdg:IsShown() then return end
  local bank = BF.Bank.Get()
  local gridMode = state.mode == "grid"
  f.modeBtn:SetText(gridMode and "Vue liste" or "Vue coffre")
  if bank then
    f.info:SetText(("Or : %s   |cffaaaaaa· scan de %s, %s|r"):format(BF.Money(bank.money), bank.scanner or "?", BF.Ago(bank.time)))
  else
    f.info:SetText("|cffaaaaaaAucune photo de la banque : il faut qu'un membre avec l'addon ouvre le coffre.|r")
  end
  -- boutons d'onglets (vue coffre seulement)
  local nTabs = bank and #bank.tabs or 0
  if state.tab > nTabs then state.tab = 1 end
  for _, b in ipairs(tabButtons) do b:Hide() end
  if gridMode then
    local x = 16
    for i = 1, nTabs do
      local b = tabButton(i)
      b:SetText(bank.tabs[i].name or ("Onglet " .. i))
      b:SetWidth(math.max(70, b:GetFontString():GetStringWidth() + 24))
      b:ClearAllPoints(); b:SetPoint("TOPLEFT", x, -80)
      x = x + b:GetWidth() + 4
      if i == state.tab then b:LockHighlight() else b:UnlockHighlight() end
      b:Show()
    end
  end
  grid:SetShown(gridMode); listFrame:SetShown(not gridMode)
  if gridMode then refreshGrid(bank) else buildList(bank); refreshList(); f.empty:Hide() end
end

f.modeBtn:SetScript("OnClick", function()
  state.mode = state.mode == "grid" and "list" or "grid"
  BrowzForeverDB.ui.mode = state.mode
  f.Refresh()
end)
f.search:SetScript("OnTextChanged", function(self)
  self.hint:SetShown(self:GetText() == "")
  f.Refresh()
end)
f.search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

-- Noms et icônes pas encore en cache : on rafraîchit quand ils arrivent
local pending
local ev = CreateFrame("Frame")
ev:RegisterEvent("GET_ITEM_INFO_RECEIVED")
ev:SetScript("OnEvent", function()
  if not f:IsShown() or pending then return end
  pending = C_Timer.NewTimer(0.3, function() pending = nil; f.Refresh() end)
end)

BF.Bank.OnChange(function() f.Refresh() end)
bdg:SetScript("OnShow", function() f.Refresh() end)

local function place()
  f:ClearAllPoints()
  local pos = BrowzForeverDB.ui.pos
  if pos then f:SetPoint("CENTER", UIParent, "BOTTOMLEFT", pos.x, pos.y)
  elseif _G.OffhandMainhandFrame then f:SetPoint("CENTER", _G.OffhandMainhandFrame, "CENTER")
  else f:SetPoint("CENTER") end
end

-- Ouvre la fenêtre principale sur un onglet (« bdg », « demandes », « craft », « liaison »)
function BF.OpenMain(tabKey)
  state.mode = BrowzForeverDB.ui.mode or "grid"
  state.tab = BrowzForeverDB.ui.tab or 1
  if not f:IsShown() then place(); f:Show() end
  if BF.SelectTab then BF.SelectTab(tabKey or BrowzForeverDB.ui.mainTab or "bdg") end
end

function BF.ToggleMain()
  if f:IsShown() then f:Hide() else BF.OpenMain() end
end

BF.commands["bdg"] = function() BF.OpenMain("bdg") end
