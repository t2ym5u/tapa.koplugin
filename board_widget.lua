local Blitbuffer = require("ffi/blitbuffer")
local Device     = require("device")
local Font       = require("ui/font")
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

local Screen = Device.screen

local C_BG         = Blitbuffer.COLOR_WHITE
local C_SHADED     = Blitbuffer.COLOR_GRAY_4    -- player-shaded cell
local C_SOL_SHADED = Blitbuffer.COLOR_BLACK     -- solution-revealed shaded cell
local C_CLUE_BG    = Blitbuffer.COLOR_WHITE     -- clue cell background (stays white)
local C_WRONG      = Blitbuffer.COLOR_GRAY    -- wrong-mark highlight
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
    self:_initClueFaces()
end

-- Largest cfont face whose rendering of `sample` fits max_w x max_h. Sizes are
-- measured, not derived from pixels, so Font:getFace's DPI scaling is moot.
local function fitFace(sample, max_w, max_h)
    local lo, hi, best = 6, 200, 6
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local m   = RenderText:sizeUtf8Text(0, Screen:getWidth(), Font:getFace("cfont", mid), sample, true, false)
        if m.x <= max_w and (m.y_top + m.y_bottom) <= max_h then
            best, lo = mid, mid + 1
        else
            hi = mid - 1
        end
    end
    return Font:getFace("cfont", best)
end

-- A clue holds one to four numbers. One uses the big cell font; two share a
-- line; three or four go on two lines, so a "1 1 1 1" clue stays readable
-- instead of shrinking to a quarter of the cell width.
function TapaBoardWidget:_initClueFaces()
    local pad   = self.number_padding or 2
    local inner = math.max(1, math.floor(self.cell_w - 2 * pad))
    self.clue_inner    = inner
    self.clue_face_one = self.number_face
    self.clue_face_two = fitFace("8 8", inner, math.floor(inner * 0.6))
    self.clue_face_two_lines = fitFace("8 8", inner, math.floor(inner * 0.42))
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
        -- The closing line sits inside the widget: drawn at i * cell it
        -- would spill lw - 1 pixels past the right and bottom edges.
        local off = (i == n) and (self.dimen.w - lw) or math.floor(i * cell)
        drawLine(bb, x + off, y, lw, self.dimen.h, C_GRID)
        drawLine(bb, x, y + off, self.dimen.w, lw, C_GRID)
    end

    -- Draw clue numbers
    local pad   = self.number_padding or 2
    local inner = self.clue_inner

    local function drawClueText(text, face, cx, cy_mid)
        local m      = RenderText:sizeUtf8Text(0, Screen:getWidth(), face, text, true, false)
        local base_x = cx + pad + math.floor((inner - m.x) / 2)
        local base_y = cy_mid + math.floor((m.y_top - m.y_bottom) / 2)
        RenderText:renderUtf8Text(bb, base_x, base_y, face, text, true, false, C_NUM)
    end

    for r = 1, n do
        for c = 1, n do
            if self.board:isClue(r, c) then
                local cx     = x + math.floor((c-1) * cell)
                local cy     = y + math.floor((r-1) * cell)
                local mid    = cy + pad + math.floor(inner / 2)
                local groups = self.board.clues[r][c]

                local parts = {}
                for _, v in ipairs(groups) do parts[#parts+1] = tostring(v) end

                if #parts <= 1 then
                    drawClueText(parts[1] or "", self.clue_face_one, cx, mid)
                elseif #parts == 2 then
                    drawClueText(table.concat(parts, " "), self.clue_face_two, cx, mid)
                else
                    local face = self.clue_face_two_lines
                    local q    = math.floor(inner / 4)
                    drawClueText(parts[1] .. " " .. parts[2], face, cx, mid - q)
                    drawClueText(table.concat(parts, " ", 3), face, cx, mid + q)
                end
            end
        end
    end
end

return TapaBoardWidget
