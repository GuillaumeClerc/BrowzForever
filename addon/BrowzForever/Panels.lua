-- Browz Forever : onglets de la fenêtre principale (Banque, Demandes, Craft, Liaison) + bouton de minimap
local _, BF = ...
local f = BF.MainFrame

-- Panneaux ---------------------------------------------------------------------------
local function newPanel()
  local p = CreateFrame("Frame", nil, f)
  p:SetAllPoints(f)
  p:Hide()
  return p
end

local function heading(parent, text, x, y)
  local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  fs:SetPoint("TOPLEFT", x, y)
  fs:SetText(text)
  return fs
end

local function paragraph(parent, text, x, y, width)
  local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  fs:SetPoint("TOPLEFT", x, y)
  fs:SetWidth(width or (f:GetWidth() - 2 * x))
  fs:SetJustifyH("LEFT"); fs:SetJustifyV("TOP")
  fs:SetSpacing(3)
  fs:SetText(text)
  return fs
end

-- Demandes (à venir)
local demandes = newPanel()
heading(demandes, "Demandes de retrait", 20, -36)
paragraph(demandes, "Bientôt ici :\n\n" ..
  "• Passer en |cffffd100mode demande|r depuis la banque, cocher un ou plusieurs objets et envoyer la demande.\n" ..
  "• Les officiers connectés reçoivent une notification en jeu et acceptent ou refusent d'un clic.\n" ..
  "• Si aucun officier n'est en ligne, la demande part sur Discord (salon #officier).\n" ..
  "• La liste de tes demandes et leur statut (en attente, acceptée, refusée).", 20, -66)

-- Craft (à venir)
local craft = newPanel()
heading(craft, "Demandes de craft", 20, -36)
paragraph(craft, "Bientôt ici :\n\n" ..
  "• La liste des artisans de la guilde et de leurs recettes (partagées par l'addon quand chacun ouvre ses métiers).\n" ..
  "• Rechercher qui sait fabriquer un objet.\n" ..
  "• Envoyer une demande de craft, visible aussi sur Discord (salon #commandes-métiers).", 20, -66)

-- Liaison ---------------------------------------------------------------------------------
local liaison = newPanel()
heading(liaison, "Ton personnage", 20, -36)
local who = paragraph(liaison, "", 20, -62, 280)

heading(liaison, "Métiers", 20, -120)
local profRows = {}
for i = 1, 6 do
  local r = CreateFrame("Frame", nil, liaison)
  r:SetSize(280, 22)
  r:SetPoint("TOPLEFT", 20, -146 - (i - 1) * 24)
  r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(20, 20); r.icon:SetPoint("LEFT")
  r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); r.text:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
  r.level = r:CreateFontString(nil, "OVERLAY", "GameFontNormal"); r.level:SetPoint("RIGHT", -4, 0)
  r:Hide()
  profRows[i] = r
end
local noProf = paragraph(liaison, "|cffaaaaaaAucun métier appris.|r", 20, -148, 280)

-- Colonne de droite : Discord + rerolls
local RX = 320
heading(liaison, "Lien avec Discord", RX, -36)
local discordLabel = paragraph(liaison, "Ton pseudo Discord (le même pour tous tes personnages) :", RX, -62, 245)
local discordBox = CreateFrame("EditBox", nil, liaison, "InputBoxTemplate")
discordBox:SetSize(140, 20); discordBox:SetPoint("TOPLEFT", discordLabel, "BOTTOMLEFT", 6, -6)
discordBox:SetAutoFocus(false); discordBox:SetMaxLetters(32)
local save = CreateFrame("Button", nil, liaison, "UIPanelButtonTemplate")
save:SetSize(90, 22); save:SetPoint("LEFT", discordBox, "RIGHT", 8, 0); save:SetText("Enregistrer")
local discordNote = paragraph(liaison, "", RX, -114, 245)
discordNote:ClearAllPoints(); discordNote:SetPoint("TOPLEFT", discordBox, "BOTTOMLEFT", -6, -6)

-- ancrés les uns sous les autres : la hauteur des textes au-dessus peut varier
local altsTitle = heading(liaison, "Tes personnages", RX, -160)
altsTitle:ClearAllPoints(); altsTitle:SetPoint("TOPLEFT", discordNote, "BOTTOMLEFT", 0, -16)
local alts = paragraph(liaison, "", RX, -186, 245)
alts:ClearAllPoints(); alts:SetPoint("TOPLEFT", altsTitle, "BOTTOMLEFT", 0, -8)

local function classColored(name, classFile)
  local c = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
  return c and ("|c%s%s|r"):format(c.colorStr, name) or name
end

-- Métiers secondaires (identifiants de compétence) : Secourisme, Pêche, Cuisine, Archéologie
local SECONDARY = { [129] = true, [356] = true, [185] = true, [794] = true }

-- Lecture des métiers (API Retail, sinon ancienne API des compétences)
local function readProfessions()
  local out = {}
  if GetProfessions and GetProfessionInfo then
    local list = { GetProfessions() }
    for i = 1, 5 do
      local idx = list[i]
      if idx then
        local name, icon, rank, maxRank, _, _, skillLine = GetProfessionInfo(idx)
        if name then
          -- GetProfessions renvoie d'abord les 2 métiers principaux, puis les secondaires
          local primary = (i <= 2) and not SECONDARY[skillLine]
          out[#out + 1] = { n = name, i = icon, lvl = rank, max = maxRank, sl = skillLine, main = primary or nil }
        end
      end
    end
  elseif GetNumSkillLines and GetSkillLineInfo then
    for i = 1, GetNumSkillLines() do
      local name, header, _, rank, _, _, maxRank, isAbandonable = GetSkillLineInfo(i)
      if not header and isAbandonable then out[#out + 1] = { n = name, lvl = rank, max = maxRank } end
    end
  end
  return out
end

-- Enregistre ce personnage (métiers, classe, niveau) dans les données du compte
local function rememberMe()
  if not BrowzForeverDB then return end
  BrowzForeverDB.chars = BrowzForeverDB.chars or {}
  local _, classFile = UnitClass("player")
  local gName, rankName = GetGuildInfo("player")
  BrowzForeverDB.chars[BF.MyName()] = {
    class = classFile, level = UnitLevel("player"), rank = rankName, guild = gName,
    profs = readProfessions(), t = GetServerTime(),
  }
end
BF.RememberMe = rememberMe

local function refreshLiaison()
  rememberMe()
  local me = BrowzForeverDB.chars[BF.MyName()]
  who:SetText(("%s  ·  niveau %d\nGrade : %s%s"):format(
    classColored(BF.MyName(), me.class), me.level or 0, me.rank or "?",
    BF.IsOfficer() and "  |cff33ff99(officier)|r" or ""))
  for i, r in ipairs(profRows) do
    local p = me.profs[i]
    if p then
      r.icon:SetTexture(p.i or 134400)
      r.text:SetText(p.n)
      r.level:SetText((p.lvl or 0) .. " / " .. (p.max or 0))
      r:Show()
    else r:Hide() end
  end
  noProf:SetShown(#me.profs == 0)
  discordBox:SetText(BrowzForeverDB.discord or "")
  discordNote:SetText(BrowzForeverDB.discord
    and "|cffaaaaaaEnregistré. Browzer va t'envoyer un message privé sur Discord pour confirmer (dès qu'un pont est connecté).|r"
    or "|cffaaaaaaPas encore renseigné.|r")
  local lines = {}
  local names = {}
  for name in pairs(BrowzForeverDB.chars) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local c = BrowzForeverDB.chars[name]
    local profs = {}
    for _, p in ipairs(c.profs or {}) do
      if p.main then profs[#profs + 1] = p.n end   -- résumé : métiers principaux seulement
    end
    lines[#lines + 1] = ("%s |cffaaaaaa(%d)|r\n  |cffcccccc%s|r"):format(classColored(name, c.class), c.level or 0,
      #profs > 0 and table.concat(profs, ", ") or "aucun métier principal")
  end
  alts:SetText(table.concat(lines, "\n"))
end

save:SetScript("OnClick", function()
  local v = strtrim(discordBox:GetText() or "")
  BrowzForeverDB.discord = (v ~= "") and v or nil
  discordBox:ClearFocus()
  refreshLiaison()
  if BF.Profile then BF.Profile.Publish(true) end   -- le bot enverra la demande de confirmation
end)
discordBox:SetScript("OnEnterPressed", function() save:Click() end)
discordBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
liaison:SetScript("OnShow", refreshLiaison)

local skillEv = CreateFrame("Frame")
skillEv:RegisterEvent("SKILL_LINES_CHANGED")
skillEv:RegisterEvent("PLAYER_LEVEL_UP")
skillEv:SetScript("OnEvent", function()
  if not BF.active then return end
  if liaison:IsShown() then refreshLiaison() else rememberMe() end
end)
BF.OnActive(function() C_Timer.After(3, rememberMe) end)

-- Onglets en bas de la fenêtre ----------------------------------------------------------------
local DEFS = {
  { key = "bdg", label = "Banque", panel = BF.BankPanel },
  { key = "demandes", label = "Demandes", panel = demandes },
  { key = "craft", label = "Craft", panel = craft },
  { key = "liaison", label = "Liaison", panel = liaison },
}
local tabs = {}
local useBlizzTabs = true
for i, d in ipairs(DEFS) do
  local name = f:GetName() .. "Tab" .. i
  local ok, t = pcall(CreateFrame, "Button", name, f, "PanelTabButtonTemplate")
  if not ok then
    useBlizzTabs = false
    t = CreateFrame("Button", name, f, "UIPanelButtonTemplate")
    t:SetSize(96, 24)
  end
  t:SetID(i)
  t:SetText(d.label)
  if i == 1 then t:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 12, 2)
  else t:SetPoint("LEFT", tabs[i - 1], "RIGHT", useBlizzTabs and 3 or 4, 0) end
  if useBlizzTabs and PanelTemplates_TabResize then pcall(PanelTemplates_TabResize, t, 0) end
  t:SetScript("OnClick", function() BF.SelectTab(d.key) end)
  tabs[i] = t
end
if useBlizzTabs and PanelTemplates_SetNumTabs then pcall(PanelTemplates_SetNumTabs, f, #DEFS) end

function BF.SelectTab(key)
  local index = 1
  for i, d in ipairs(DEFS) do
    if d.key == key then index = i end
  end
  for i, d in ipairs(DEFS) do d.panel:SetShown(i == index) end
  if useBlizzTabs and PanelTemplates_SetTab then pcall(PanelTemplates_SetTab, f, index)
  else
    for i, t in ipairs(tabs) do if i == index then t:LockHighlight() else t:UnlockHighlight() end end
  end
  BrowzForeverDB.ui.mainTab = DEFS[index].key
  f.title:SetText("Browz Forever — " .. DEFS[index].label)
end

BF.commands[""] = function() BF.ToggleMain() end
BF.commands["demandes"] = function() BF.OpenMain("demandes") end
BF.commands["craft"] = function() BF.OpenMain("craft") end
BF.commands["liaison"] = function() BF.OpenMain("liaison") end
BF.commands["aide"] = function()
  BF.Print("|cffffd100/browz|r : ouvrir/fermer la fenêtre · |cffffd100/browz bdg|r · |cffffd100/browz liaison|r · " ..
    "|cffffd100/browz lien|r (télécharger / partager l'addon) · |cffffd100/browz pont on|off|r (ce PC envoie à Discord)")
end

-- Lien de téléchargement (à copier avec Ctrl+C) -------------------------------------------------
BF.DOWNLOAD_URL = "https://github.com/GuillaumeClerc/BrowzForever"
StaticPopupDialogs["BROWZFOREVER_LIEN"] = {
  text = "Browz Forever — lien de téléchargement\n(Ctrl+C pour copier, puis colle-le dans ton navigateur ou sur Discord)",
  button1 = CLOSE or "Fermer",
  hasEditBox = true, editBoxWidth = 320,
  OnShow = function(self)
    local eb = self.editBox or self.EditBox or (self.GetEditBox and self:GetEditBox())
    if eb then eb:SetText(BF.DOWNLOAD_URL); eb:SetFocus(); eb:HighlightText() end
  end,
  EditBoxOnTextChanged = function(eb) if eb:GetText() ~= BF.DOWNLOAD_URL then eb:SetText(BF.DOWNLOAD_URL); eb:HighlightText() end end,
  EditBoxOnEscapePressed = function(eb) eb:GetParent():Hide() end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}
function BF.ShowLink() StaticPopup_Show("BROWZFOREVER_LIEN") end
BF.commands["lien"] = BF.ShowLink

local linkBtn = CreateFrame("Button", nil, liaison, "UIPanelButtonTemplate")
linkBtn:SetSize(150, 22); linkBtn:SetPoint("BOTTOMRIGHT", -16, 14)
linkBtn:SetText("Lien de l'addon")
linkBtn:SetScript("OnClick", BF.ShowLink)
linkBtn:SetScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_TOP")
  GameTooltip:SetText("Télécharger / partager Browz Forever")
  GameTooltip:AddLine("Affiche le lien GitHub à copier pour un nouveau membre.", 1, 1, 1, true)
  GameTooltip:Show()
end)
linkBtn:SetScript("OnLeave", GameTooltip_Hide)

-- Bouton de minimap (déplaçable autour de la minimap) ---------------------------------------------
local mb = CreateFrame("Button", "BrowzForeverMinimapButton", Minimap)
mb:SetSize(31, 31)
mb:SetFrameStrata("MEDIUM"); mb:SetFrameLevel(8)
mb:RegisterForClicks("AnyUp"); mb:RegisterForDrag("LeftButton")
mb:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
local bg = mb:CreateTexture(nil, "BACKGROUND")
bg:SetSize(20, 20); bg:SetPoint("TOPLEFT", 7, -5); bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
local icon = mb:CreateTexture(nil, "ARTWORK")
icon:SetSize(20, 20); icon:SetPoint("TOPLEFT", 7, -5); icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_02")
local border = mb:CreateTexture(nil, "OVERLAY")
border:SetSize(53, 53); border:SetPoint("TOPLEFT"); border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
mb:Hide()

local function placeButton()
  local angle = math.rad((BrowzForeverDB and BrowzForeverDB.ui.minimapAngle) or 210)
  local r = (Minimap:GetWidth() / 2) + 10
  mb:ClearAllPoints()
  mb:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * r, math.sin(angle) * r)
end

mb:SetScript("OnDragStart", function(self)
  self:SetScript("OnUpdate", function()
    local mx, my = Minimap:GetCenter()
    local px, py = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    BrowzForeverDB.ui.minimapAngle = math.deg(math.atan2(py / scale - my, px / scale - mx))
    placeButton()
  end)
end)
mb:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
mb:SetScript("OnClick", function() BF.ToggleMain() end)
mb:SetScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_LEFT")
  GameTooltip:AddLine("Browz Forever")
  GameTooltip:AddLine("Clic : ouvrir la fenêtre de guilde", 1, 1, 1)
  GameTooltip:AddLine("Glisser : déplacer le bouton", 0.7, 0.7, 0.7)
  GameTooltip:Show()
end)
mb:SetScript("OnLeave", GameTooltip_Hide)

BF.OnActive(function() placeButton(); mb:Show() end)
