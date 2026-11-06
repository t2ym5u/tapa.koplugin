local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire_common(name)
    local key = _dir .. "common/" .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. "common/" .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local grid_utils    = lrequire_common("grid_utils")
local Hint = lrequire_common("hint")
local emptyBoolGrid = grid_utils.emptyBoolGrid
local shuffle       = grid_utils.shuffle
local Solver        = lrequire("solver")

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

-- Per difficulty (1.6.0; see buildClues and generate): the solver tier the
-- puzzle may need (solver.lua: 1 = each clue on its own, 2x2 and local
-- wall rules; 2 = the whole wall's connectivity) and `steps`, the window
-- of tier-2 steps it must need (each one forced cell or one cut-off area,
-- taken one at a time with the simple rules in between): none on Easy,
-- exactly one on Medium, two or more on Hard. `share`: the share of the
-- possible clue cells Easy keeps at least (Medium and Hard keep only the
-- clues they need).
local LEVELS = {
    easy   = { tier = 1, steps = { 0, 0 }, share = 0.6 },
    medium = { tier = 2, steps = { 1, 1 } },
    hard   = { tier = 2, steps = { 2, math.huge } },
}
-- Solution shadings tried per puzzle at most, per size, before the closest
-- puzzle to the level's window is kept (a measured count: about 1 ms per
-- shading on 6x6, 3 ms on 10x10 on a desktop, so generation stays under
-- about 1 s on a Kobo; how often Hard lands inside its window is in the
-- CHANGELOG). Easy and Medium nearly always stop at the first or second.
local MAX_SHADINGS = { [6] = 30, [8] = 16, [10] = 12 }

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

-- The solution shading, grown as one connected region: start from a random
-- cell, keep shading a random cell next to the region unless it would
-- complete a 2x2 block (a cell rejected once stays rejected -- shading
-- more can only add blocks), until 40% of the grid is shaded. Connected
-- and 2x2-free by construction, so it never fails. (Up to 1.5.x, 6x6 and
-- 8x8 scattered cells at random and bridged the pieces, which failed most
-- of the time and cost more than choosing the clues.)
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

-- 1.6.0: the clues are chosen by the logic solver (solver.lua), never by a
-- fixed share of the cells. Up to 1.5.x a share was picked at random and
-- raised until a branching search found one solution, which pushed every
-- level to 75-100% of the possible clues (Hard had the most) and let some
-- puzzles through that only trial and error could finish.
--
-- Every unshaded cell with a shaded neighbour can hold a clue: these are
-- the candidates, in random order. Their patterns (solver.lua) are listed
-- once.
local function clueCandidates(shaded, n)
    local out = {}
    for r = 1, n do
        for c = 1, n do
            if not shaded[r][c] then
                local groups = computeClue(shaded, n, r, c)
                if #groups > 0 then
                    local i = (r - 1) * n + c
                    out[#out + 1] = { r = r, c = c, i = i, groups = groups,
                                      pats = Solver.cluePatterns(n, i, groups) }
                end
            end
        end
    end
    shuffle(out)
    return out
end

-- The solver problem made of the candidates `list[k]` with keep[k] ~= false.
local function problemOf(n, list, keep)
    local P = { n = n, clues = {} }
    for k, e in ipairs(list) do
        if not keep or keep[k] then
            P.clues[#P.clues + 1] = { cell = e.i, pats = e.pats }
        end
    end
    return P
end

-- Does a clue at e still tell the solver anything in state s (its own
-- cell, or a cell of its ring, undecided)?
local function cluesUndecided(e, ring, s)
    if s[e.i] == 0 then return true end
    for k = 1, 8 do
        local j = ring[k]
        if j and s[j] == 0 then return true end
    end
    return false
end

-- The clues of one shading for a level, or nil when even every candidate
-- clue leaves the solver stuck (then the shading is dropped).
--  1. Add clues where the solver is stuck: solve at the level's tier; while
--     it stops short, show the next candidate that still bears on an
--     undecided cell and go on from where it stopped (a clue only adds
--     constraints, so what was deduced stays true).
--  2. Remove the clues not needed: in random order, hide each clue for good
--     if the puzzle is still solved from scratch at the level's tier, in no
--     more steps than the level allows (Easy stops at its share).
-- Every solve is by deduction only (no trial), so the result is proved to
-- have exactly one solution. Returns clue list, tier, steps.
local function buildClues(shaded, n, lv, tick)
    local cand = clueCandidates(shaded, n)
    local ring = Solver.geom(n).ring
    -- Easy starts with its share of the candidates shown
    local floor = math.floor((lv.share or 0) * #cand)
    local chosen = {}
    for k = 1, floor do chosen[k] = cand[k] end
    local P = problemOf(n, chosen)
    local st, s, _
    local nxt = floor + 1
    while true do
        tick()
        st, _, _, s = Solver.solve(P, lv.tier, s)
        if st == "solved" then break end
        if st == "contradiction" then return nil end   -- (the shading itself fits every clue)
        local pick
        while nxt <= #cand do
            local e = cand[nxt]
            nxt = nxt + 1
            if cluesUndecided(e, ring[e.i], s) then pick = e; break end
        end
        if not pick then return nil end
        chosen[#chosen + 1] = pick
        P.clues[#P.clues + 1] = { cell = pick.i, pats = pick.pats }
    end
    local keep, order = {}, {}
    for k = 1, #chosen do keep[k] = true; order[k] = k end
    shuffle(order)
    local cap, kept = lv.steps[2], #chosen
    for o = 1, #order do
        local k = order[o]
        if kept <= floor then break end
        keep[k] = false
        kept = kept - 1
        tick()
        local st2, steps
        st2, _, steps = Solver.solve(problemOf(n, chosen, keep), lv.tier)
        if st2 ~= "solved" or steps > cap then keep[k] = true; kept = kept + 1 end
    end
    local tier, steps
    st, tier, steps = Solver.solve(problemOf(n, chosen, keep), lv.tier)
    assert(st == "solved")
    local clues = {}
    for r = 1, n do clues[r] = {} end
    for k, e in ipairs(chosen) do
        if keep[k] then clues[e.r][e.c] = e.groups end
    end
    return clues, tier, steps
end

-- ---------------------------------------------------------------------------
-- Uniqueness counter, by branching search. Since 1.6.0 the generator no
-- longer uses it (the logic solver in solver.lua proves uniqueness without
-- guessing); the specs keep it as an independent check of that proof.
-- No "given" mask -- clue cells (numbers at a subset of unshaded cells,
-- showing the circular run-length grouping of shaded 8-neighbors) ARE the
-- entire puzzle; the whole shading is unknown. Uniqueness means: is there only one shading (connected via
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

-- How far a puzzle needing `steps` tier-2 steps is from its level's window.
local function missBy(lv, steps)
    if steps < lv.steps[1] then return lv.steps[1] - steps end
    if steps > lv.steps[2] then return steps - lv.steps[2] end
    return 0
end

-- Last resort, never seen in practice: a comb (first column plus every
-- other row) with every candidate clue, proved by the specs to solve at
-- tier 1 for every size.
local function combShading(n)
    local shaded = emptyBoolGrid(n)
    for r = 1, n do
        shaded[r][1] = true
        if r % 2 == 1 then
            for c = 1, n do shaded[r][c] = true end
        end
    end
    return shaded
end

-- No "given" mask to dig here -- the clues ARE the puzzle -- so each try
-- draws a solution shading and lets buildClues choose its clues. The first
-- puzzle inside the level's window of tier-2 steps wins; after
-- MAX_SHADINGS tries the closest one is kept. Every puzzle kept is solved
-- by deduction alone, so it is unique and never needs guessing. Shadings
-- and tries are counted, never timed: a seed always gives the same puzzle
-- (the Daily Challenge relies on it).
-- on_progress (optional): called with a 0..1 fraction as it goes.
function TapaBoard:generate(difficulty, on_progress)
    self.difficulty = difficulty or self.difficulty
    local n = self.n
    local lv = LEVELS[self.difficulty] or LEVELS[DEFAULT_DIFFICULTY]
    local solves, typical = 0, n * n
    local function tick()
        solves = solves + 1
        if on_progress then on_progress(solves / (solves + typical)) end
    end

    local best
    for _ = 1, MAX_SHADINGS[n] or MAX_SHADINGS[10] do
        local shaded = growShading(n)
        local clues, _, steps = buildClues(shaded, n, lv, tick)
        if clues then
            local miss = missBy(lv, steps)
            if not best or miss < best.miss then
                best = { solution = shaded, clues = clues, miss = miss }
            end
            if miss == 0 then break end
        end
    end
    if not best then
        local shaded = combShading(n)
        best = { solution = shaded, clues = buildClues(shaded, n, LEVELS.easy, tick) }
    end

    self.solution = best.solution
    self.clues    = best.clues
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

-- Solved when the shading keeps every rule (1.6.0), not only when it
-- equals the stored solution: no clue cell shaded, every clue matches its
-- ring, one connected wall, no 2x2 block. New puzzles have one solution,
-- but a game saved by an older version may have several, and any of them
-- wins.
function TapaBoard:_checkSolved()
    local n = self.n
    local any = false
    for r = 1, n do
        for c = 1, n do
            local g = self.clues[r] and self.clues[r][c]
            if g then
                if self.user[r][c] then self.solved = false; return end
                local got = computeClue(self.user, n, r, c)
                if #got ~= #g then self.solved = false; return end
                for k = 1, #g do
                    if got[k] ~= g[k] then self.solved = false; return end
                end
            end
            if self.user[r][c] then any = true end
        end
    end
    self.solved = any and isConnected(self.user, n) and not has2x2(self.user, n)
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
TapaBoard._computeClue   = computeClue

return TapaBoard
