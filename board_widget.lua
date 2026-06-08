local Blitbuffer = require("ffi/blitbuffer")
local Geom       = require("ui/geometry")
local RenderText = require("ui/rendertext")
local Size       = require("ui/size")

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

local gwb            = lrequire_common("grid_widget_base")
local GridWidgetBase = gwb.GridWidgetBase
local drawLine       = gwb.drawLine

local C_BG         = Blitbuffer.COLOR_WHITE
local C_SHADED     = Blitbuffer.COLOR_GRAY_4    -- player-shaded cell
local C_SOL_SHADED = Blitbuffer.COLOR_BLACK     -- solution-revealed shaded cell
local C_CLUE_BG    = Blitbuffer.COLOR_WHITE     -- clue cell background (stays white)
local C_WRONG      = Blitbuffer.COLOR_GRAY_A    -- wrong-mark highlight
local C_GRID       = Blitbuffer.COLOR_BLACK
local C_NUM        = Blitbuffer.COLOR_BLACK

-- ---------------------------------------------------------------------------
-- TapaBoardWidget
-- ---------------------------------------------------------------------------

local TapaBoardWidget = GridWidgetBase:extend{
    board = nil,
}

function TapaBoardWidget:init()
    local n   = self.board and self.board.n or 8
    self.cols = n
    self.rows = n
    GridWidgetBase.init(self)
end

function TapaBoardWidget:onCellTap(row, col)
    if self.onCellAction then self.onCellAction(row, col) end
end

function TapaBoardWidget:paintTo(bb, x, y)
    if not self.board then return end
    self.paint_rect = Geom:new{ x=x, y=y, w=self.dimen.w, h=self.dimen.h }

    local n    = self.board.n
    local cell = self.dimen.w / n
    local show = self.board:isShowingSolution()

    -- Background
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, C_BG)

    -- Cell backgrounds
    for r = 1, n do
        for c = 1, n do
            local cx = x + math.floor((c-1) * cell)
            local cy = y + math.floor((r-1) * cell)
            local cw = math.ceil(cell)
            local ch = math.ceil(cell)

            if self.board:isClue(r, c) then
                -- Clue cells stay white
                bb:paintRect(cx, cy, cw, ch, C_CLUE_BG)
            elseif show and self.board.solution[r][c] then
                bb:paintRect(cx, cy, cw, ch, C_SOL_SHADED)
            elseif not show and self.board.wrong[r][c] then
                bb:paintRect(cx, cy, cw, ch, C_WRONG)
            elseif not show and self.board.user[r][c] then
                bb:paintRect(cx, cy, cw, ch, C_SHADED)
            end
        end
    end

    -- Grid lines
    local thin  = Size.line.thin  or 1
    local thick = Size.line.thick or 2
    for i = 0, n do
        local lw = (i == 0 or i == n) and thick or thin
        drawLine(bb, x + math.floor(i * cell), y, lw, self.dimen.h, C_GRID)
        drawLine(bb, x, y + math.floor(i * cell), self.dimen.w, lw, C_GRID)
    end

    -- Draw clue numbers
    local pad   = self.number_padding or 2
    local inner = math.max(1, math.floor(cell - 2*pad))

    for r = 1, n do
        for c = 1, n do
            if self.board:isClue(r, c) then
                local cx     = x + math.floor((c-1) * cell)
                local cy     = y + math.floor((r-1) * cell)
                local groups = self.board.clues[r][c]

                -- Format clue text: numbers separated by spaces
                local parts = {}
                for _, v in ipairs(groups) do parts[#parts+1] = tostring(v) end
                local text = table.concat(parts, " ")

                -- Fit text in cell using note_face for multi-digit clues
                local face = (#text > 2) and self.note_face or self.number_face

                local m      = RenderText:sizeUtf8Text(0, inner, face, text, true, false)
                local base_x = cx + pad + math.floor((inner - m.x) / 2)
                local base_y = cy + pad + math.floor((inner + m.y_top - m.y_bottom) / 2)
                RenderText:renderUtf8Text(bb, base_x, base_y, face, text, true, false, C_NUM)
            end
        end
    end
end

return TapaBoardWidget
