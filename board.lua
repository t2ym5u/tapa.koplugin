local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire_common(name)
    local key = _dir .. "common/" .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. "common/" .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local grid_utils    = lrequire_common("grid_utils")
local Hint = lrequire_common("hint")
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

-- Grows the shading as one connected region instead: start from a random
-- cell, keep shading a random cell next to the region unless it would
-- complete a 2x2 block (a cell rejected once stays rejected -- shading
-- more can only add blocks), until the same 40% density. Connected and
-- 2x2-free by construction, so it never fails. Used from 10x10 up, where
-- generateShading's scatter-then-bridge only connects ~1 time in 1250
-- (1.5.0: about 0.2 s of retries per 10x10 puzzle on a desktop, seconds
-- on an e-reader); 6x6 and 8x8 keep generateShading so their puzzles stay
-- the same per seed.
local function growShading(n)
    local shaded = emptyBoolGrid(n)
    local target = math.floor(n * n * 0.40)
    local queued = emptyBoolGrid(n)
    local frontier = {}
    local function push(r, c)
        if not queued[r][c] then
            queued[r][c] = true
            frontier[#frontier + 1] = { r, c }
        end
    end
    push(math.random(n), math.random(n))
    local count = 0
    while count < target and #frontier > 0 do
        local idx = math.random(#frontier)
        local cell = frontier[idx]
        frontier[idx] = frontier[#frontier]
        frontier[#frontier] = nil
        local r, c = cell[1], cell[2]
        local blocks = false
        for dr = -1, 0 do
            for dc = -1, 0 do
                local r1, c1 = r + dr, c + dc
                if r1 >= 1 and r1 + 1 <= n and c1 >= 1 and c1 + 1 <= n then
                    local others = 0
                    for _, q in ipairs({ { r1, c1 }, { r1, c1 + 1 }, { r1 + 1, c1 }, { r1 + 1, c1 + 1 } }) do
                        if shaded[q[1]][q[2]] then others = others + 1 end
                    end
                    if others == 3 then blocks = true end
                end
            end
        end
        if not blocks then
            shaded[r][c] = true
            count = count + 1
            for _, d in ipairs(DIRS4) do
                local nr, nc = r + d[1], c + d[2]
                if nr >= 1 and nr <= n and nc >= 1 and nc <= n and not shaded[nr][nc] then
                    push(nr, nc)
                end
            end
        end
    end
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
-- Backtracking with propagation to a fixpoint at every node; each rule
-- only forces what every solution extending the current partial grid
-- shares, so solutions are counted exactly:
--   - clue: every 8-cell ring pattern matching the clue's groups is listed
--     once up front (off-grid neighbours count as unshaded); a ring cell
--     on which all patterns still compatible with the decided cells agree
--     takes that value, and no compatible pattern left is a contradiction.
--   - 2x2: a block with three shaded cells has its fourth unshaded.
--   - connectivity: among the "maybe-shaded" (shaded or undecided) 4-
--     connected components, two holding a shaded cell can never be
--     reconciled (dead branch), and once some cell is shaded the
--     components holding none can only end up unshaded.
-- The search branches on a ring cell of the clue with the fewest patterns
-- left, else the first undecided cell. Cell state: 0 undecided, 1 shaded,
-- 2 unshaded. node_budget counts search nodes, so a seed gives the same
-- verdict on every device.
-- 1.5.0: replaces a cell-by-cell backtracker that checked a clue only once
-- its whole ring was decided (up to 2 s at 10x10 on a desktop, nearly a
-- minute on an e-reader).
-- ---------------------------------------------------------------------------

-- RING_PATTERNS[key] = list of 8-value rings (1 shaded / 2 unshaded, in
-- DIRS8 order) whose groups, sorted descending and joined with ",", are key.
local RING_PATTERNS = {}
do
    for p = 0, 255 do
        local ring, rest = {}, p
        for k = 1, 8 do
            ring[k] = (rest % 2 == 1) and 1 or 2
            rest = math.floor(rest / 2)
        end
        local start
        for k = 1, 8 do if ring[k] == 2 then start = k; break end end
        local groups = {}
        if not start then
            groups[1] = 8
        else
            local run = 0
            for i = 0, 7 do
                if ring[(start + i - 1) % 8 + 1] == 1 then
                    run = run + 1
                elseif run > 0 then
                    groups[#groups + 1] = run; run = 0
                end
            end
            if run > 0 then groups[#groups + 1] = run end
        end
        table.sort(groups, function(a, b) return a > b end)
        local key = table.concat(groups, ",")
        RING_PATTERNS[key] = RING_PATTERNS[key] or {}
        table.insert(RING_PATTERNS[key], ring)
    end
end

local function countSolutions(clues, n, limit, node_budget)
    local N = n * n
    local state = {}
    for i = 1, N do state[i] = 0 end
    local nbr4 = {}
    for r = 1, n do for c = 1, n do
        local l = {}
        for _, d in ipairs(DIRS4) do
            local nr, nc = r + d[1], c + d[2]
            if nr >= 1 and nr <= n and nc >= 1 and nc <= n then l[#l + 1] = (nr - 1) * n + nc end
        end
        nbr4[(r - 1) * n + c] = l
    end end
    local blocks = {}
    for r = 1, n - 1 do for c = 1, n - 1 do
        local i = (r - 1) * n + c
        blocks[#blocks + 1] = { i, i + 1, i + n, i + n + 1 }
    end end

    -- Each clue: its ring (cell index, or false off the grid) and the
    -- patterns still possible (shrunk per node into a scratch list).
    local clue_list = {}
    for r = 1, n do for c = 1, n do
        if clues[r][c] then
            local ring = {}
            for k, d in ipairs(DIRS8) do
                local nr, nc = r + d[1], c + d[2]
                ring[k] = (nr >= 1 and nr <= n and nc >= 1 and nc <= n) and ((nr - 1) * n + nc) or false
            end
            local pats = {}
            for _, p in ipairs(RING_PATTERNS[table.concat(clues[r][c], ",")] or {}) do
                local ok = true
                for k = 1, 8 do
                    if not ring[k] and p[k] == 1 then ok = false; break end
                end
                if ok then pats[#pats + 1] = p end
            end
            clue_list[#clue_list + 1] = { ring = ring, pats = pats, left = #pats }
            state[(r - 1) * n + c] = 2
        end
    end end

    local trail, tn = {}, 0
    local changed = false
    local function set(i, v)
        local s = state[i]
        if s == v then return true end
        if s ~= 0 then return false end
        state[i] = v
        tn = tn + 1; trail[tn] = i
        changed = true
        return true
    end
    local function undo(mark)
        while tn > mark do state[trail[tn]] = 0; trail[tn] = nil; tn = tn - 1 end
    end

    local cur, any = {}, {}
    local function cluesProp()
        for _, cl in ipairs(clue_list) do
            local ring = cl.ring
            local free = false
            for k = 1, 8 do
                local i = ring[k]
                local s = i and state[i] or 2
                cur[k] = s
                if s == 0 then free = true end
                any[k] = 0
            end
            local left = 0
            for _, p in ipairs(cl.pats) do
                local ok = true
                for k = 1, 8 do
                    local s = cur[k]
                    if s ~= 0 and s ~= p[k] then ok = false; break end
                end
                if ok then
                    left = left + 1
                    if free then
                        for k = 1, 8 do
                            if cur[k] == 0 then
                                local a = any[k]
                                if a == 0 then any[k] = p[k] elseif a ~= p[k] then any[k] = 3 end
                            end
                        end
                    end
                end
            end
            if left == 0 then return false end
            cl.left = left
            if free then
                for k = 1, 8 do
                    local a = any[k]
                    if cur[k] == 0 and a ~= 3 then
                        if not set(ring[k], a) then return false end
                    end
                end
            end
        end
        return true
    end

    local function blocksProp()
        for _, b in ipairs(blocks) do
            local sh, free = 0, nil
            for k = 1, 4 do
                local s = state[b[k]]
                if s == 1 then sh = sh + 1 elseif s == 0 then free = b[k] end
            end
            if sh == 4 then return false end
            if sh == 3 and free then
                if not set(free, 2) then return false end
            end
        end
        return true
    end

    local comp, stamp, stack = {}, 0, {}
    for i = 1, N do comp[i] = 0 end
    local function regionProp()
        stamp = stamp + 1
        local base = stamp
        local anchored = nil   -- stamp of the one component holding a shaded cell
        local any_shaded = false
        for i = 1, N do
            if state[i] ~= 2 and comp[i] <= base - 1 then
                -- new maybe-shaded component, labelled with a fresh stamp
                stamp = stamp + 1
                local id = stamp
                local has = false
                local top = 1
                stack[1] = i; comp[i] = id
                while top > 0 do
                    local j = stack[top]; top = top - 1
                    if state[j] == 1 then has = true end
                    for _, k in ipairs(nbr4[j]) do
                        if state[k] ~= 2 and comp[k] ~= id then
                            comp[k] = id
                            top = top + 1; stack[top] = k
                        end
                    end
                end
                if has then
                    if anchored then return false end
                    anchored = id
                    any_shaded = true
                end
            end
        end
        if any_shaded then
            for i = 1, N do
                if state[i] == 0 and comp[i] ~= anchored then
                    if not set(i, 2) then return false end
                end
            end
        end
        return true
    end

    local function propagate()
        repeat
            changed = false
            if not cluesProp() or not blocksProp() or not regionProp() then return false end
        until not changed
        return true
    end

    local function pickCell()
        local best, best_left = nil, math.huge
        for _, cl in ipairs(clue_list) do
            if cl.left < best_left then
                for k = 1, 8 do
                    local i = cl.ring[k]
                    if i and state[i] == 0 then best, best_left = i, cl.left; break end
                end
            end
        end
        if best then return best end
        for i = 1, N do if state[i] == 0 then return i end end
    end

    local solutions, nodes, exhausted = 0, 0, false
    local function search()
        nodes = nodes + 1
        if nodes > node_budget then exhausted = true; return end
        if not propagate() then return end
        local i = pickCell()
        if not i then
            -- complete: clues, 2x2 and connectivity all hold (propagate)
            solutions = solutions + 1
            return
        end
        for v = 1, 2 do
            local mark = tn
            set(i, v)
            search()
            undo(mark)
            if solutions >= limit or exhausted then return end
        end
    end
    search()
    return solutions, exhausted, nodes
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
-- generate() -- far too slow). Since 1.5.0 only 6x6/8x8 go through this
-- retry loop; 10x10 uses growShading, which never fails.
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
-- Search nodes allowed per uniqueness check; running out counts as "not
-- unique". With the propagation above a unique clue set is proved in under
-- 100 nodes at every size (measured on 450 puzzles), so this only cuts
-- short the rare non-unique set that wanders before its second solution
-- turns up.
local function uniquenessNodeBudget(n) -- luacheck: ignore n
    return 1000
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
            shaded = n >= 10 and growShading(n) or generateShading(n)
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

-- Like tapCell(), but sets the state outright. Used by the Hint button.
function TapaBoard:setCellFilled(r, c, filled)
    if r < 1 or r > self.n or c < 1 or c > self.n then return false end
    if self:isClue(r, c) then return false end
    self.user[r][c]  = filled and true or false
    self.wrong[r][c] = false
    self:_checkSolved()
    return true
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

-- user/solution are plain booleans, and false doubles as "not filled", which
-- is exactly the default notion of empty.
Hint.install(TapaBoard, {
    getUser     = function(b, r, c) return b.user[r][c] end,
    getSolution = function(b, r, c) return b.solution[r][c] end,
    isGiven     = function(b, r, c) return b:isClue(r, c) end,
    setCell     = function(b, r, c, v) return b:setCellFilled(r, c, v) end,
    blank       = false,
})

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

-- exposed for the specs
TapaBoard.countSolutions = countSolutions

return TapaBoard
