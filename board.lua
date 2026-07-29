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
-- Builds a random shaded region (connected, no 2x2) -- no clues picked yet,
-- see pickClues below. Split out from the old combined tryGenerate so the
-- (cheap) clue-density escalation doesn't need to redo this (comparatively
-- expensive) part each time.
local function generateShading(n)
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

    return shaded
end

-- Picks clue cells (non-shaded cells adjacent to >=1 shaded neighbor) at
-- the given ratio of all such candidates. Repicking which candidates
-- become clues for the SAME shading -- especially at a HIGHER ratio -- is
-- much cheaper than regenerating the shading itself, and more revealed
-- clues can only add constraints, never remove any -- same lever as
-- shikaku's clue-cell repositioning / lightup's wall-number escalation.
local function pickClues(shaded, n, ratio)
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
    local n_clues = math.max(2, math.floor(#cand_cells * ratio))
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

    return clues
end


-- ---------------------------------------------------------------------------
-- Uniqueness counter. No "given" mask -- clue cells (numbers at a subset
-- of unshaded cells, showing the circular run-length grouping of shaded
-- 8-neighbors) ARE the entire puzzle; the whole shading is unknown, and
-- the win-check is a literal comparison to the stored solution (not
-- rule-based). Uniqueness means: is there only one shading (connected via
-- 4-adjacency, no 2x2 all-shaded block, every clue cell fixed unshaded and
-- matching its own group clue exactly) consistent with the shown clues?
--
-- Backtracking over non-clue cells, ordered clue-by-clue (finish ALL of
-- one clue's 8 neighbors before starting the next -- distance-based
-- ordering processes every clue's ring in parallel, so none of them
-- actually completes, and triggers its exact-match check, until deep into
-- the search). Two pruning rules beyond the per-cell 2x2/clue checks:
--   - once a clue's 8 neighbors are all decided, its group-match is
--     checked immediately;
--   - after any cell is decided UNSHADED, check whether the "maybe-
--     shaded" (shaded-or-still-undecided) cells split into 2+ connected
--     components that EACH already anchor a confirmed-shaded cell -- those
--     can never be reconciled, so the branch is dead. (A weaker, unsound
--     version of this check -- requiring the ENTIRE maybe-shaded set to
--     stay one component, not just the confirmed-shaded anchors -- was
--     tried first and wrongly rejected valid partial assignments where an
--     isolated pocket of merely-undecided cells was always going to
--     resolve to all-unshaded anyway; caught via the standard sanity
--     check returning solutions=0 for the generator's own known-good
--     layout at n=10.)
-- Full connectivity is otherwise only verified once every cell is
-- decided.
-- ---------------------------------------------------------------------------

local function countSolutions(clues, n, limit, node_budget)
    local shaded = {}
    for r = 1, n do shaded[r] = {} end

    local clue_cells = {}
    for r = 1, n do
        for c = 1, n do
            if clues[r][c] then
                clue_cells[#clue_cells + 1] = { r = r, c = c, groups = clues[r][c] }
                shaded[r][c] = false
            end
        end
    end

    local order, seen = {}, {}
    for _, cl in ipairs(clue_cells) do
        for _, d in ipairs(DIRS8) do
            local nr, nc = cl.r + d[1], cl.c + d[2]
            local key = nr * 1000 + nc
            if nr >= 1 and nr <= n and nc >= 1 and nc <= n and not clues[nr][nc] and not seen[key] then
                seen[key] = true
                order[#order + 1] = { r = nr, c = nc }
            end
        end
    end
    for r = 1, n do
        for c = 1, n do
            local key = r * 1000 + c
            if not clues[r][c] and not seen[key] then
                seen[key] = true
                order[#order + 1] = { r = r, c = c }
            end
        end
    end

    local solutions, nodes, exhausted = 0, 0, false

    local function violates2x2(r, c)
        for dr = -1, 0 do
            for dc = -1, 0 do
                local r1, r2 = r + dr, r + dr + 1
                local c1, c2 = c + dc, c + dc + 1
                if r1 >= 1 and r2 <= n and c1 >= 1 and c2 <= n then
                    if shaded[r1][c1] and shaded[r1][c2] and shaded[r2][c1] and shaded[r2][c2] then
                        return true
                    end
                end
            end
        end
        return false
    end

    local function neighborsAllDecided(cl)
        for _, d in ipairs(DIRS8) do
            local nr, nc = cl.r + d[1], cl.c + d[2]
            if nr >= 1 and nr <= n and nc >= 1 and nc <= n and shaded[nr][nc] == nil then return false end
        end
        return true
    end

    local function checkClue(cl)
        -- computeClue (the existing production function above) reads
        -- directly from `shaded`, which already reflects the current
        -- (possibly partial) state -- only called once neighborsAllDecided
        -- confirms no nil neighbors remain, so its "nil treated as
        -- unshaded" default can't affect the result here.
        local groups = computeClue(shaded, n, cl.r, cl.c)
        if #groups ~= #cl.groups then return false end
        for i = 1, #groups do if groups[i] ~= cl.groups[i] then return false end end
        return true
    end

    local affecting = {}
    for r = 1, n do affecting[r] = {} end
    for _, cl in ipairs(clue_cells) do
        for _, d in ipairs(DIRS8) do
            local nr, nc = cl.r + d[1], cl.c + d[2]
            if nr >= 1 and nr <= n and nc >= 1 and nc <= n then
                affecting[nr][nc] = affecting[nr][nc] or {}
                table.insert(affecting[nr][nc], cl)
            end
        end
    end

    local function isConnectedFull()
        local sr, sc
        for r = 1, n do
            for c = 1, n do
                if shaded[r][c] then sr, sc = r, c end
            end
            if sr then break end
        end
        if not sr then return true end
        local visited = {}
        for r = 1, n do visited[r] = {} end
        local stack = { { sr, sc } }
        visited[sr][sc] = true
        local count = 1
        while #stack > 0 do
            local cell = table.remove(stack)
            for _, d in ipairs(DIRS4) do
                local nr, nc = cell[1] + d[1], cell[2] + d[2]
                if nr >= 1 and nr <= n and nc >= 1 and nc <= n and shaded[nr][nc] and not visited[nr][nc] then
                    visited[nr][nc] = true
                    count = count + 1
                    stack[#stack + 1] = { nr, nc }
                end
            end
        end
        local total = 0
        for r = 1, n do for c = 1, n do if shaded[r][c] then total = total + 1 end end end
        return count == total
    end

    -- See header: only a "maybe-shaded" component that already anchors a
    -- confirmed-shaded cell is a genuine problem; 2+ such anchored
    -- components can never be reconciled.
    local function potentialRegionSingleComponent()
        local visited = {}
        for r = 1, n do visited[r] = {} end
        local components_with_true = 0

        for r = 1, n do
            for c = 1, n do
                if shaded[r][c] ~= false and not visited[r][c] then
                    local stack = { { r, c } }
                    visited[r][c] = true
                    local has_true = shaded[r][c] == true
                    while #stack > 0 do
                        local cell = table.remove(stack)
                        for _, d in ipairs(DIRS4) do
                            local nr, nc = cell[1] + d[1], cell[2] + d[2]
                            if nr >= 1 and nr <= n and nc >= 1 and nc <= n
                                and shaded[nr][nc] ~= false and not visited[nr][nc] then
                                visited[nr][nc] = true
                                if shaded[nr][nc] == true then has_true = true end
                                stack[#stack + 1] = { nr, nc }
                            end
                        end
                    end
                    if has_true then
                        components_with_true = components_with_true + 1
                        if components_with_true > 1 then return false end
                    end
                end
            end
        end
        return true
    end

    local function search(idx)
        if solutions >= limit or exhausted then return end
        nodes = nodes + 1
        if nodes > node_budget then exhausted = true; return end

        if idx > #order then
            if isConnectedFull() then solutions = solutions + 1 end
            return
        end

        local cell = order[idx]
        local r, c = cell.r, cell.c
        for _, val in ipairs({ false, true }) do
            shaded[r][c] = val
            local ok = true
            if val and violates2x2(r, c) then ok = false end
            if ok and affecting[r][c] then
                for _, cl in ipairs(affecting[r][c]) do
                    if neighborsAllDecided(cl) and not checkClue(cl) then ok = false; break end
                end
            end
            if ok and not val then
                ok = potentialRegionSingleComponent()
            end
            if ok then search(idx + 1) end
            shaded[r][c] = nil
            if solutions >= limit or exhausted then return end
        end
    end

    search(1)
    return solutions, exhausted
end

local function uniquenessNodeBudget(n)
    if n <= 8 then return 30000 end
    return 60000
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

-- Retry budget for the shading generation itself (connected, no 2x2):
-- raised from 80 after measuring 87-91% fallback at n=10 (0-3% at n=6/8) --
-- random shading + connectivity-repair attempts only rarely land on a
-- connected, 2×2-free region at that size, but each attempt is cheap, so a
-- much higher cap clears the fallback rate to 0/100 with acceptable
-- worst-case latency (~0.8s) rather than needing a generation-strategy
-- redesign. Kept separate from the uniqueness escalation loop below (each
-- shading attempt now costs up to 9 verification calls, not 1, so reusing
-- this same cap there would mean up to ~27000 verification calls per
-- generate() -- far too slow).
local GENERATE_MAX_ATTEMPTS = 3000
local SHADING_ATTEMPTS_FOR_UNIQUENESS = 20

-- No "given" mask to dig here -- clue cells ARE the entire puzzle, and the
-- win-check is a literal comparison to the stored solution -- so like
-- hitori/nurikabe/starbattle/lightup this generates+verifies whole
-- candidates instead of digging. Measured pre-fix: severe, real ambiguity
-- (0% unique at every size/difficulty).
--
-- A first attempt just added a uniqueness gate to the existing retry loop
-- (regenerate the whole shading+clue-selection, check, repeat) -- this
-- did NOT work: essentially 0% unique even after all 3000 attempts,
-- because every fresh attempt draws from the SAME distribution at the
-- SAME nominal clue density, and that density is (like hitori's nominal
-- black-cell density) almost never unique on its own -- retrying doesn't
-- change the odds. Fixed the same way as hitori/lightup: escalate the
-- CLUE density in bounded steps for a given shading (repicking which
-- candidate cells become clues is much cheaper than regenerating the
-- shading, and more clues can only add constraints) before giving up on
-- that shading and drawing a fresh one.
local function uniquenessNodeBudget(n)
    if n <= 8 then return 30000 end
    return 60000
end

-- Multipliers on the nominal ratio. "hard"'s base ratio (0.12) is low
-- enough that even 2x isn't close to sufficient (measured 0% unique still
-- at that ceiling) -- the last tier's multiplier is deliberately large
-- enough to hit the 1.0 (reveal every candidate cell) ceiling regardless
-- of the starting difficulty, guaranteeing a maximally-constrained
-- last-resort attempt before giving up on a shading.
local CLUE_REVEAL_ESCALATION = { 1.0, 1.5, 2.5, 4.5, 10.0 }

function TapaBoard:generate(difficulty)
    self.difficulty = difficulty or self.difficulty
    local n = self.n
    local node_budget = uniquenessNodeBudget(n)
    local base_ratio = DIFF_CONFIG[self.difficulty] or DIFF_CONFIG.medium

    local solution, clues
    local best_solution, best_clues

    for shading_attempt = 1, SHADING_ATTEMPTS_FOR_UNIQUENESS do
        if solution then break end
        local shaded = nil
        for _ = 1, GENERATE_MAX_ATTEMPTS / SHADING_ATTEMPTS_FOR_UNIQUENESS do
            shaded = generateShading(n)
            if shaded then break end
        end
        if shaded then
            for _, mult in ipairs(CLUE_REVEAL_ESCALATION) do
                if solution then break end
                local ratio = math.min(1.0, base_ratio * mult)
                -- at ratio 1.0 every candidate cell becomes a clue
                -- regardless of pick order, so repeating is pure waste
                local sub_attempts = ratio >= 1.0 and 1 or 2
                for _ = 1, sub_attempts do
                    local candidate_clues = pickClues(shaded, n, ratio)

                    if not best_solution then
                        best_solution, best_clues = shaded, candidate_clues
                    end

                    local solutions, exhausted = countSolutions(candidate_clues, n, 2, node_budget)
                    if solutions == 1 and not exhausted then
                        solution, clues = shaded, candidate_clues
                        break
                    end
                end
            end
        end
    end
    if not solution then
        solution, clues = best_solution, best_clues
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
