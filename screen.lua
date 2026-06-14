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

local ButtonTable     = require("ui/widget/buttontable")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("gettext")
local T               = require("ffi/util").template

local ScreenBase        = lrequire_common("screen_base")
local MenuHelper        = lrequire_common("menu_helper")
local TapaBoard         = lrequire("board")
local TapaBoardWidget   = lrequire("board_widget")

local DeviceScreen = Device.screen

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

Tap a cell to shade it. Tap again to unshade.
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

Appuyez sur une case pour la noircir. Appuyez à nouveau pour la dénoircir.
]]

local TapaScreen = ScreenBase:extend{}

function TapaScreen:init()
    local state = self.plugin:loadState()
    local n     = self.plugin:getSetting("grid_n", TapaBoard.DEFAULT_N)
    local diff  = self.plugin:getSetting("difficulty", TapaBoard.DEFAULT_DIFFICULTY)
    self.board  = TapaBoard:new{ n = n, difficulty = diff }
    if not self.board:load(state) then
        self.board:generate(diff)
    end
    ScreenBase.init(self)
end

function TapaScreen:serializeState()
    return self.board:serialize()
end

function TapaScreen:buildLayout()
    local sw           = DeviceScreen:getWidth()
    local is_landscape = self:isLandscape()

    self.board_widget = TapaBoardWidget:new{
        board        = self.board,
        onCellAction = function(r, c)
            self:onCellAction(r, c)
        end,
    }

    local board_frame = FrameContainer:new{
        padding = Size.padding.large,
        margin  = Size.margin.default,
        self.board_widget,
    }

    local board_frame_size  = self.board_widget.size + (Size.padding.large + Size.margin.default) * 2
    local right_panel_width = sw - board_frame_size - Size.span.horizontal_default
    local button_width = is_landscape
        and math.max(right_panel_width - Size.span.horizontal_default, 100)
        or  math.floor(sw * 0.9)

    local top_buttons = ButtonTable:new{
        shrink_unneeded_width = true,
        width   = button_width,
        buttons = {
            {
                { text = _("New"),   callback = function() self:onNewGame() end },
                { id   = "grid_button", text = self:getGridButtonText(),
                  callback = function() self:openGridMenu() end },
                { id   = "diff_button", text = self:getDiffButtonText(),
                  callback = function() self:openDifficultyMenu() end },
                { id   = "reveal_button", text = self:getRevealButtonText(),
                  callback = function() self:onToggleReveal() end },
                self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR),
            self:makeCloseButtonConfig(),
            },
        },
    }
    self.grid_button   = top_buttons:getButtonById("grid_button")
    self.diff_button   = top_buttons:getButtonById("diff_button")
    self.reveal_button = top_buttons:getButtonById("reveal_button")

    local bottom_buttons = ButtonTable:new{
        shrink_unneeded_width = true,
        width   = button_width,
        buttons = {
            {
                { text = _("Check"), callback = function() self:onCheck() end },
                { text = _("Rules"), callback = function() self:showRulesHint() end },
            },
        },
    }

    if is_landscape then
        local right_panel = VerticalGroup:new{
            align = "center",
            top_buttons,
            VerticalSpan:new{ width = Size.span.vertical_large },
            self.status_text,
            VerticalSpan:new{ width = Size.span.vertical_large },
            bottom_buttons,
        }
        self.layout = HorizontalGroup:new{
            align  = "center",
            board_frame,
            HorizontalSpan:new{ width = Size.span.horizontal_default },
            right_panel,
        }
    else
        self.layout = VerticalGroup:new{
            align = "center",
            VerticalSpan:new{ width = Size.span.vertical_large },
            top_buttons,
            VerticalSpan:new{ width = Size.span.vertical_large },
            board_frame,
            VerticalSpan:new{ width = Size.span.vertical_large },
            self.status_text,
            VerticalSpan:new{ width = Size.span.vertical_large },
            bottom_buttons,
            VerticalSpan:new{ width = Size.span.vertical_large },
        }
    end
    self[1] = self.layout
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
end

function TapaScreen:onNewGame()
    local n    = self.plugin:getSetting("grid_n", TapaBoard.DEFAULT_N)
    local diff = self.plugin:getSetting("difficulty", TapaBoard.DEFAULT_DIFFICULTY)
    self.board = TapaBoard:new{ n = n, difficulty = diff }
    self.board:generate(diff)
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

function TapaScreen:showRulesHint()
    self:showMessage(_(
        "Tapa rules:\n" ..
        "Shade cells to form one connected wall.\n\n" ..
        "Clue cells (white with numbers) are never shaded.\n" ..
        "For each clue, the numbers describe the lengths of\n" ..
        "consecutive shaded groups among its 8 neighbors.\n\n" ..
        "No 2\xC3\x972 block of shaded cells is allowed.\n\n" ..
        "Tap: shade / unshade a cell.\n" ..
        "Check: highlights incorrect cells."
    ), 12)
end

function TapaScreen:openGridMenu()
    local sizes = {}
    for _, sz in ipairs(GRID_SIZES) do
        sizes[#sizes+1] = { id = sz, text = sz .. "\xC3\x97" .. sz }
    end
    MenuHelper.openSizeMenu{
        title     = _("Select grid size"),
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
        status = T(_("%1\xC3\x97%2 \xC2\xB7 %3 \xC2\xB7 Shaded: %4/%5 \xC2\xB7 Clues: %6"),
            self.board.n, self.board.n, label, shaded, sol, clues)
    end
    ScreenBase.updateStatus(self, status)
end

function TapaScreen:getGridButtonText()
    return T(_("Grid: %1"), self.board.n .. "\xC3\x97" .. self.board.n)
end

function TapaScreen:getDiffButtonText()
    local diff  = self.plugin:getSetting("difficulty", TapaBoard.DEFAULT_DIFFICULTY)
    local label = MenuHelper.DIFFICULTY_LABELS[diff] or diff
    return T(_("Diff: %1"), label)
end

function TapaScreen:getRevealButtonText()
    return self.board:isShowingSolution() and _("Hide") or _("Show")
end

return TapaScreen
