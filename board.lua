local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire_common(name)
    local key = _dir .. "common/" .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. "common/" .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local grid_utils    = lrequire_common("grid_utils")
local emptyGrid     = grid_utils.emptyGrid
local emptyBoolGrid = grid_utils.emptyBoolGrid
local copyGrid      = grid_utils.copyGrid
local shuffle       = grid_utils.shuffle

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local DEFAULT_N          = 8
local SIZES              = { 6, 8, 10 }
local DEFAULT_DIFFICULTY = "medium"

-- Orthogonal directions
local DIRS4 = { {-1,0}, {1,0}, {0,-1}, {0,1} }
-- 8 neighbors (clockwise from top)
local DIRS8 = { {-1,0},{-1,1},{0,1},{1,1},{1,0},{1,-1},{0,-1},{-1,-1} }

-- Difficulty: controls clue density (fraction of cells that become clue cells)
local DIFF_CONFIG = {
    easy   = 0.30,  -- 30% of border cells become clues
    medium = 0.20,
    hard   = 0.12,
}

-- ---------------------------------------------------------------------------
-- Validation helpers
-- ---------------------------------------------------------------------------

local function isConnected(shaded, n)
    -- Find first shaded cell
    local sr, sc
    for r = 1, n do
        for c = 1, n do
            if shaded[r][c] then sr, sc = r, c; goto found end
        end
    end
    ::found::
    if not sr then return true end  -- no shaded cells = trivially connected

    local visited = emptyBoolGrid(n)
    local stack   = {{sr, sc}}
    visited[sr][sc] = true
    local count = 1
    while #stack > 0 do
        local cell = table.remove(stack)
        for _, d in ipairs(DIRS4) do
            local nr, nc = cell[1]+d[1], cell[2]+d[2]
            if nr >= 1 and nr <= n and nc >= 1 and nc <= n
                and shaded[nr][nc] and not visited[nr][nc] then
                visited[nr][nc] = true
                count = count + 1
                stack[#stack+1] = {nr, nc}
            end
        end
    end
    local total = 0
    for r = 1, n do
        for c = 1, n do if shaded[r][c] then total = total + 1 end end
    end
    return count == total
end

local function has2x2(shaded, n)
    for r = 1, n-1 do
        for c = 1, n-1 do
            if shaded[r][c] and shaded[r+1][c] and shaded[r][c+1] and shaded[r+1][c+1] then
                return true
            end
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Clue computation
-- ---------------------------------------------------------------------------

-- Get the groups of consecutive shaded cells among the 8 neighbors
-- of cell (r,c), in clockwise order. Returns a sorted (desc) list of lengths.
local function computeClue(shaded, n, r, c)
    local ring = {}  -- 8 neighbors in clockwise order
    for _, d in ipairs(DIRS8) do
        local nr, nc = r+d[1], c+d[2]
        if nr >= 1 and nr <= n and nc >= 1 and nc <= n then
            ring[#ring+1] = shaded[nr][nc] and 1 or 0
        else
            ring[#ring+1] = 0  -- out-of-bounds = unshaded
        end
    end

    -- Find runs of 1s in the circular sequence
    local groups = {}
    local n_ring = #ring
    -- Find a starting position that is 0 (break point for circular runs)
    local start = 1
    for i = 1, n_ring do
        if ring[i] == 0 then start = i; break end
    end
    local in_run = false
    local run_len = 0
    for i = 0, n_ring - 1 do
        local idx = (start + i - 1) % n_ring + 1
        if ring[idx] == 1 then
            in_run   = true
            run_len  = run_len + 1
        else
            if in_run then
                groups[#groups+1] = run_len
                run_len = 0
            end
            in_run = false
        end
    end
    if in_run then groups[#groups+1] = run_len end

    -- Handle fully-shaded ring (no 0 found)
    if #groups == 0 then
        -- Count total shaded neighbors
        local total = 0
        for _, v in ipairs(ring) do total = total + v end
        if total > 0 then groups[#groups+1] = total end
    end

    -- Sort descending
    table.sort(groups, function(a, b) return a > b end)
    return groups
end

-- ---------------------------------------------------------------------------
-- Generator
-- ---------------------------------------------------------------------------

-- Generate a valid shaded region (connected, no 2×2) and pick clue cells.
local function tryGenerate(n, difficulty)
    local density = 0.40  -- target fraction of shaded cells
    local shaded  = emptyBoolGrid(n)

    -- Random seed shading
    local cells = {}
    for r = 1, n do for c = 1, n do cells[#cells+1] = {r,c} end end
    shuffle(cells)

    local target = math.floor(n * n * density)
    local count  = 0

    for _, cell in ipairs(cells) do
        local r, c = cell[1], cell[2]
        shaded[r][c] = true
        -- Check: adding this cell would create 2×2?
        local creates_2x2 = false
        for dr = -1, 0 do
            for dc = -1, 0 do
                local r1, r2 = r+dr, r+dr+1
                local c1, c2 = c+dc, c+dc+1
                if r1 >= 1 and r2 <= n and c1 >= 1 and c2 <= n then
                    if shaded[r1][c1] and shaded[r1][c2] and shaded[r2][c1] and shaded[r2][c2] then
                        creates_2x2 = true
                    end
                end
            end
        end
        if creates_2x2 then
            shaded[r][c] = false
        else
            count = count + 1
            if count >= target then break end
        end
    end

    if count == 0 then return nil end
    if not isConnected(shaded, n) then
        -- Try to connect: add bridge cells
        local function addBridge()
            local components = {}
            local comp_id = emptyGrid(n, n, 0)
            local n_comp = 0
            for r = 1, n do
                for c = 1, n do
                    if shaded[r][c] and comp_id[r][c] == 0 then
                        n_comp = n_comp + 1
                        local stk = {{r,c}}
                        comp_id[r][c] = n_comp
                        components[n_comp] = {{r,c}}
                        while #stk > 0 do
                            local cell2 = table.remove(stk)
                            for _, d in ipairs(DIRS4) do
                                local nr, nc = cell2[1]+d[1], cell2[2]+d[2]
                                if nr >= 1 and nr <= n and nc >= 1 and nc <= n
                                    and shaded[nr][nc] and comp_id[nr][nc] == 0 then
                                    comp_id[nr][nc] = n_comp
                                    components[n_comp][#components[n_comp]+1] = {nr,nc}
                                    stk[#stk+1] = {nr,nc}
                                end
                            end
                        end
                    end
                end
            end
            if n_comp <= 1 then return true end
            -- Find nearest pair of cells from comp 1 and comp 2
            local best_dist = math.huge
            local best_path = nil
            for _, c1 in ipairs(components[1]) do
                for _, c2 in ipairs(components[2]) do
                    local d = math.abs(c1[1]-c2[1]) + math.abs(c1[2]-c2[2])
                    if d < best_dist then best_dist = d; best_path = {c1, c2} end
                end
            end
            if not best_path then return false end
            -- Add cells along the Manhattan path
            local r1, c1_c = best_path[1][1], best_path[1][2]
            local r2, c2_c = best_path[2][1], best_path[2][2]
            local function step(a, b)
                if a < b then return a+1
                elseif a > b then return a-1
                else return a end
            end
            local tries = 0
            while (r1 ~= r2 or c1_c ~= c2_c) and tries < 20 do
                tries = tries + 1
                if r1 ~= r2 then
                    r1 = step(r1, r2)
                else
                    c1_c = step(c1_c, c2_c)
                end
                if not shaded[r1][c1_c] then
                    shaded[r1][c1_c] = true
                    -- Check 2x2 constraint
                    for dr = -1, 0 do
                        for dc = -1, 0 do
                            local ra, rb = r1+dr, r1+dr+1
                            local ca, cb = c1_c+dc, c1_c+dc+1
                            if ra >= 1 and rb <= n and ca >= 1 and cb <= n then
                                if shaded[ra][ca] and shaded[ra][cb] and shaded[rb][ca] and shaded[rb][cb] then
                                    shaded[r1][c1_c] = false
                                    break
                                end
                            end
                        end
                    end
                end
            end
            return isConnected(shaded, n)
        end
        for _ = 1, 5 do
            if addBridge() then break end
        end
    end

    if not isConnected(shaded, n) then return nil end
    if has2x2(shaded, n) then return nil end

    -- Pick clue cells: non-shaded cells adjacent to at least one shaded neighbor
    local diff_ratio = DIFF_CONFIG[difficulty] or DIFF_CONFIG.medium
    local cand_cells = {}
    for r = 1, n do
        for c = 1, n do
            if not shaded[r][c] then
                local has_shaded_nb = false
                for _, d in ipairs(DIRS8) do
                    local nr, nc = r+d[1], c+d[2]
                    if nr >= 1 and nr <= n and nc >= 1 and nc <= n and shaded[nr][nc] then
                        has_shaded_nb = true; break
                    end
                end
                if has_shaded_nb then
                    cand_cells[#cand_cells+1] = {r, c}
                end
            end
        end
    end

    shuffle(cand_cells)
    local n_clues = math.max(2, math.floor(#cand_cells * diff_ratio))
    -- Also ensure at minimum ratio relative to board
    n_clues = math.max(n_clues, math.floor(n * n * 0.08))
    n_clues = math.min(n_clues, #cand_cells)

    local clues = {}
    for r = 1, n do clues[r] = {} end
    for i = 1, n_clues do
        local r, c = cand_cells[i][1], cand_cells[i][2]
        local groups = computeClue(shaded, n, r, c)
        if #groups > 0 then
            clues[r][c] = groups
        end
    end

    return shaded, clues
end

-- ---------------------------------------------------------------------------
-- TapaBoard
-- ---------------------------------------------------------------------------

local TapaBoard = {}
TapaBoard.__index = TapaBoard

TapaBoard.DEFAULT_N          = DEFAULT_N
TapaBoard.SIZES              = SIZES
TapaBoard.DEFAULT_DIFFICULTY = DEFAULT_DIFFICULTY

function TapaBoard:new(opts)
    opts = opts or {}
    local n = opts.n or DEFAULT_N
    return setmetatable({
        n          = n,
        difficulty = opts.difficulty or DEFAULT_DIFFICULTY,
        solution   = emptyBoolGrid(n),  -- solution shading
        clues      = {},                -- clues[r][c] = list of numbers or nil
        user       = emptyBoolGrid(n),  -- player shading
        wrong      = emptyBoolGrid(n),  -- wrong-mark overlay
        reveal     = false,
        solved     = false,
    }, self)
end

function TapaBoard:generate(difficulty)
    self.difficulty = difficulty or self.difficulty
    local n = self.n

    local solution, clues
    for attempt = 1, 80 do
        solution, clues = tryGenerate(n, self.difficulty)
        if solution then break end
        if attempt % 20 == 0 then
            -- Relax: try with easier difficulty
        end
    end

    if not solution then
        -- Fallback: shade left half, one clue cell
        solution = emptyBoolGrid(n)
        for r = 1, n do
            for c = 1, math.floor(n/2) do
                solution[r][c] = true
            end
        end
        clues = {}
        for r = 1, n do clues[r] = {} end
        clues[1][math.floor(n/2)+1] = computeClue(solution, n, 1, math.floor(n/2)+1)
    end

    self.solution = solution
    self.clues    = clues
    self.user     = emptyBoolGrid(n)
    self.wrong    = emptyBoolGrid(n)
    self.reveal   = false
    self.solved   = false
end

-- Returns true if (r,c) is a clue cell.
function TapaBoard:isClue(r, c)
    return self.clues[r] and self.clues[r][c] ~= nil
end

function TapaBoard:tapCell(r, c)
    if r < 1 or r > self.n or c < 1 or c > self.n then return end
    if self:isClue(r, c) then return end
    self.user[r][c]  = not self.user[r][c]
    self.wrong[r][c] = false
    self:_checkSolved()
end

function TapaBoard:_checkSolved()
    local n = self.n
    -- Quick check: user matches solution
    for r = 1, n do
        for c = 1, n do
            if self.user[r][c] ~= self.solution[r][c] then
                self.solved = false; return
            end
        end
    end
    self.solved = true
end

-- Check user shading against rules, mark wrong cells.
-- Returns ok (bool), error_count (int).
function TapaBoard:checkProgress()
    local n = self.n
    local errors = 0
    self.wrong = emptyBoolGrid(n)

    -- Mark cells that differ from solution
    for r = 1, n do
        for c = 1, n do
            if not self:isClue(r, c) then
                if self.user[r][c] ~= self.solution[r][c] then
                    self.wrong[r][c] = true
                    errors = errors + 1
                end
            end
        end
    end
    return errors == 0, errors
end

function TapaBoard:countShaded()
    local n = self.n
    local count = 0
    for r = 1, n do
        for c = 1, n do
            if self.user[r][c] then count = count + 1 end
        end
    end
    return count
end

function TapaBoard:countSolutionShaded()
    local n = self.n
    local count = 0
    for r = 1, n do
        for c = 1, n do
            if self.solution[r][c] then count = count + 1 end
        end
    end
    return count
end

function TapaBoard:countClues()
    local n = self.n
    local count = 0
    for r = 1, n do
        for c = 1, n do
            if self:isClue(r, c) then count = count + 1 end
        end
    end
    return count
end

function TapaBoard:toggleReveal()
    self.reveal = not self.reveal
end

function TapaBoard:isShowingSolution()
    return self.reveal
end

function TapaBoard:serialize()
    local n = self.n
    local sol_out, user_out, wrong_out = {}, {}, {}
    for r = 1, n do
        sol_out[r]   = {}
        user_out[r]  = {}
        wrong_out[r] = {}
        for c = 1, n do
            sol_out[r][c]   = self.solution[r][c] and true or false
            user_out[r][c]  = self.user[r][c]     and true or false
            wrong_out[r][c] = self.wrong[r][c]    and true or false
        end
    end
    -- Serialize clues (table of arrays)
    local clues_out = {}
    for r = 1, n do
        clues_out[r] = {}
        for c = 1, n do
            if self.clues[r] and self.clues[r][c] then
                -- Store as an array of numbers
                local arr = {}
                for i, v in ipairs(self.clues[r][c]) do arr[i] = v end
                clues_out[r][c] = arr
            end
        end
    end
    return {
        n          = n,
        difficulty = self.difficulty,
        solution   = sol_out,
        clues      = clues_out,
        user       = user_out,
        wrong      = wrong_out,
        reveal     = self.reveal,
        solved     = self.solved,
    }
end

function TapaBoard:load(data)
    if type(data) ~= "table" or not data.solution then return false end
    local n = data.n or DEFAULT_N
    self.n          = n
    self.difficulty = data.difficulty or DEFAULT_DIFFICULTY

    self.solution = emptyBoolGrid(n)
    if data.solution then
        for r = 1, n do
            for c = 1, n do
                local v = data.solution[r] and data.solution[r][c]
                self.solution[r][c] = (v == true or v == 1)
            end
        end
    end

    self.clues = {}
    for r = 1, n do self.clues[r] = {} end
    if data.clues then
        for r = 1, n do
            if data.clues[r] then
                for c = 1, n do
                    local arr = data.clues[r][c]
                    if type(arr) == "table" and #arr > 0 then
                        local nums = {}
                        for i, v in ipairs(arr) do nums[i] = v end
                        self.clues[r][c] = nums
                    end
                end
            end
        end
    end

    self.user = emptyBoolGrid(n)
    if data.user then
        for r = 1, n do
            for c = 1, n do
                local v = data.user[r] and data.user[r][c]
                self.user[r][c] = (v == true or v == 1)
            end
        end
    end

    self.wrong = emptyBoolGrid(n)
    if data.wrong then
        for r = 1, n do
            for c = 1, n do
                local v = data.wrong[r] and data.wrong[r][c]
                self.wrong[r][c] = (v == true or v == 1)
            end
        end
    end

    self.reveal = data.reveal or false
    self.solved = data.solved or false
    return true
end

return TapaBoard
