local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end
local function lrequire_common(name)
    local key = _dir .. "common/" .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. "common/" .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("i18n")
local T               = require("ffi/util").template

local ScreenBase        = lrequire_common("screen_base")
local MenuHelper        = lrequire_common("menu_helper")
local GenProgress       = lrequire_common("gen_progress")
local TapaBoard         = lrequire("board")
local TapaBoardWidget   = lrequire("board_widget")

local GRID_SIZES = TapaBoard.SIZES

local GAME_RULES_EN = _([[
Tapa — Rules

Shade some cells black to form a single connected group.

Rules:
• Numbered clue cells (which are never shaded) describe the consecutive shaded runs in their 8 surrounding cells.
  - A single number means one run of that length.
  - Multiple numbers mean multiple separate runs, arranged clockwise around the cell (starting point is flexible).
• All shaded cells must form one orthogonally connected group.
• No 2×2 area may be entirely shaded.

Tap a cell to shade it. Tap again to unshade. Check highlights incorrect cells.
]])

local GAME_RULES_FR = [[
Tapa — Règles

Noircissez certaines cases pour former un seul groupe connecté.

Règles :
• Les cases indices numérotées (jamais noircies) décrivent les séquences consécutives de cases noires dans leurs 8 cases entourant.
  - Un seul nombre signifie une séquence de cette longueur.
  - Plusieurs nombres signifient plusieurs séquences séparées, disposées dans le sens des aiguilles d'une montre autour de la case (le point de départ est libre).
• Toutes les cases noircies doivent former un seul groupe orthogonalement connecté.
• Aucun carré 2×2 ne peut être entièrement noirci.

Appuyez sur une case pour la noircir. Appuyez à nouveau pour la dénoircir. Vérifier met en évidence les cases incorrectes.
]]

local TapaScreen = ScreenBase:extend{}

function TapaScreen:init()
    local state = self.plugin:loadState()
    local n     = self.plugin:getSetting("grid_n", TapaBoard.DEFAULT_N)
    local diff  = self.plugin:getSetting("difficulty", TapaBoard.DEFAULT_DIFFICULTY)
    self.board  = TapaBoard:new{ n = n, difficulty = diff }
    if not self.board:load(state) then
        GenProgress.run(function(on_progress) self.board:generate(diff, on_progress) end)
    end
    ScreenBase.init(self)
end

function TapaScreen:serializeState()
    return self.board:serialize()
end

function TapaScreen:buildLayout()
    local is_landscape = self:isLandscape()

    local title_bar = self:buildTitleBar(_("Tapa"), function()
        return {
            { text = _("New game"),            callback = function() self:onNewGame() end },
            self:makeDailyButtonConfig(),
            { text = self:getGridButtonText(), callback = function() self:openGridMenu() end },
            { text = self:getDiffButtonText(), callback = function() self:openDifficultyMenu() end },
            { text = self:getRevealButtonText(), callback = function() self:onToggleReveal() end },
            self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR),
        }
    end)

    -- Controls first: the board is sized from whatever room they leave.
    self.status_text:setMaxWidth(self:getControlsWidth())
    local action_bar = self:buildActionBar({
        { text = _("Check"), callback = function() self:onCheck() end },
        { text = _("Hint"), callback = function() self:onHint() end },
    })
    local controls = VerticalGroup:new{
        align = "center",
        self.status_text,
        VerticalSpan:new{ width = Size.span.vertical_large },
        action_bar,
    }

    -- The widget draws its own thick outer border, so the frame only pads.
    local frame_pad   = Size.padding.large
    local frame_extra = 2 * frame_pad
    local budget_w, budget_h = self:getBoardBudget(title_bar, controls)
    self.board_widget = TapaBoardWidget:new{
        board        = self.board,
        max_size     = math.min(budget_w, budget_h) - frame_extra,
        onCellAction = function(r, c)
            self:onCellAction(r, c)
        end,
    }
    local board_frame = FrameContainer:new{
        padding    = frame_pad,
        margin     = 0,
        bordersize = 0,
        self.board_widget,
    }

    if is_landscape then
        local content = HorizontalGroup:new{
            align = "center",
            board_frame,
            HorizontalSpan:new{ width = self:getGutter() },
            controls,
        }
        self:buildLandscapeLayout(title_bar, content)
    else
        self:buildPortraitLayout(title_bar, board_frame,
            VerticalGroup:new{ align = "center", controls, VerticalSpan:new{ width = self:getGutter() } })
    end
    self:updateStatus()
end

function TapaScreen:onCellAction(r, c)
    if self.board:isShowingSolution() then return end
    self.board:tapCell(r, c)
    self.plugin:saveState(self.board:serialize())
    self.board_widget:refresh()
    if self.board.solved then
        self:updateStatus(_("Congratulations! Puzzle solved!"))
    else
        self:updateStatus()
    end
    self:refreshActionBar()
end

function TapaScreen:isRoundOver()
    return self.board.solved
end

-- A hint can place the last cell, so the round may end here.
function TapaScreen:onHint()
    ScreenBase.onHint(self)
    self:refreshActionBar()
end

function TapaScreen:onNewGame()
    local n    = self.plugin:getSetting("grid_n", TapaBoard.DEFAULT_N)
    local diff = self.plugin:getSetting("difficulty", TapaBoard.DEFAULT_DIFFICULTY)
    self.board = TapaBoard:new{ n = n, difficulty = diff }
    GenProgress.run(function(on_progress) self.board:generate(diff, on_progress) end)
    self.plugin:saveState(self.board:serialize())
    self:buildLayout()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function TapaScreen:onCheck()
    local ok, errors = self.board:checkProgress()
    self.board_widget:refresh()
    if self.board.solved then
        self:updateStatus(_("Congratulations! Puzzle solved!"))
    elseif ok then
        self:updateStatus(_("No errors found so far."))
    else
        self:updateStatus(T(_("Check: %1 incorrect cell(s)."), errors))
    end
end

function TapaScreen:onToggleReveal()
    self.board:toggleReveal()
    self.board_widget:refresh()
    if self.reveal_button then
        self.reveal_button:setText(self:getRevealButtonText(), self.reveal_button.width)
    end
    self:updateStatus()
end

function TapaScreen:openGridMenu()
    local sizes = {}
    for _, sz in ipairs(GRID_SIZES) do
        sizes[#sizes+1] = { id = sz, text = sz .. "\xC3\x97" .. sz }
    end
    MenuHelper.openSizeMenu{
        title     = _("Select size"),
        sizes     = sizes,
        current   = self.plugin:getSetting("grid_n", TapaBoard.DEFAULT_N),
        parent    = self,
        on_select = function(sz)
            if sz ~= self.board.n then
                self.plugin:saveSetting("grid_n", sz)
                self:onNewGame()
            end
        end,
    }
end

function TapaScreen:openDifficultyMenu()
    MenuHelper.openDifficultyMenu{
        current   = self.plugin:getSetting("difficulty", TapaBoard.DEFAULT_DIFFICULTY),
        parent    = self,
        on_select = function(id)
            self.plugin:saveSetting("difficulty", id)
            if self.diff_button then
                self.diff_button:setText(self:getDiffButtonText(), self.diff_button.width)
            end
            self:onNewGame()
        end,
    }
end

function TapaScreen:updateStatus(msg)
    local status
    if msg then
        status = msg
    elseif self.board:isShowingSolution() then
        status = _("Solution shown.")
    elseif self.board.solved then
        status = _("Congratulations! Puzzle solved!")
    else
        local shaded  = self.board:countShaded()
        local sol     = self.board:countSolutionShaded()
        local clues   = self.board:countClues()
        local diff    = self.plugin:getSetting("difficulty", TapaBoard.DEFAULT_DIFFICULTY)
        local label   = MenuHelper.DIFFICULTY_LABELS[diff] or diff
        status = self:joinStatus(
            T("%1×%1", self.board.n), label,
            T(_("Shaded: %1/%2"), shaded, sol), T(_("Clues: %1"), clues))
    end
    ScreenBase.updateStatus(self, status)
end

function TapaScreen:getGridButtonText()
    return T(_("Size: %1"), self.board.n .. "\xC3\x97" .. self.board.n)
end

function TapaScreen:getDiffButtonText()
    local diff  = self.plugin:getSetting("difficulty", TapaBoard.DEFAULT_DIFFICULTY)
    local label = MenuHelper.DIFFICULTY_LABELS[diff] or diff
    return T(_("Difficulty: %1"), label)
end

function TapaScreen:getRevealButtonText()
    return self.board:isShowingSolution() and _("Hide solution") or _("Show solution")
end

return TapaScreen
