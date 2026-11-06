-- ---------------------------------------------------------------------------
-- Tapa logic solver (1.6.0): deduces the shading the way a player does,
-- never by "assume this cell, see if it breaks" (the owner calls that
-- guessing, even on Hard). Used by the generator to grade puzzles and to
-- prove them unique: every rule below only forces what every solution
-- shares, so a grid it finishes has exactly one solution.
--
-- Cell state: 0 undecided, 1 shaded, 2 unshaded. Off-grid counts as
-- unshaded.
--
-- Tier 1 (what a beginner sees by looking at one spot):
--   - clue: list the ways the clue's runs can sit in its 8-cell ring; a ring
--     cell on which every way still possible agrees takes that value.
--   - 2x2: a block with three shaded cells has its fourth unshaded.
--   - local wall: once some cell is shaded, an undecided cell whose four
--     sides are all unshaded is unshaded; a shaded group with a single way
--     out, while shaded cells exist elsewhere, extends through it.
-- Tier 2 (the whole wall at once):
--   - an undecided cell no shaded cell can reach is unshaded;
--   - an undecided cell every path between two shaded cells goes through is
--     shaded.
--
-- Solver.solve(P, tier) returns status ("solved", "stuck", "contradiction"),
-- the hardest tier used, the number of tier-2 steps (each one cell or one
-- cut-off area, taken one at a time with tier 1 to a fixpoint in between,
-- as a player would) and the final state.
-- ---------------------------------------------------------------------------

local Solver = {}

-- 8 neighbours, clockwise from top: the order clue rings are read in.
local DIRS8 = { {-1,0},{-1,1},{0,1},{1,1},{1,0},{1,-1},{0,-1},{-1,-1} }
local DIRS4 = { {-1,0},{1,0},{0,-1},{0,1} }

-- RING_PATTERNS[key] = list of 8-value rings (1 shaded / 2 unshaded, in
-- DIRS8 order) whose runs, sorted descending and joined with ",", are key
-- ("0" for an empty ring).
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
        local key = #groups > 0 and table.concat(groups, ",") or "0"
        RING_PATTERNS[key] = RING_PATTERNS[key] or {}
        table.insert(RING_PATTERNS[key], ring)
    end
end
Solver.RING_PATTERNS = RING_PATTERNS

-- The key of a clue ({} or {0} for an empty ring).
local function clueKey(groups)
    if #groups == 0 or (#groups == 1 and groups[1] == 0) then return "0" end
    return table.concat(groups, ",")
end
Solver.clueKey = clueKey

-- The grid's fixed geometry, shared by every solve of one size.
local geometry = {}
local function geom(n)
    local G = geometry[n]
    if G then return G end
    G = { n = n, N = n * n, nbr4 = {}, ring = {}, blocks = {} }
    for r = 1, n do
        for c = 1, n do
            local i = (r - 1) * n + c
            local l = {}
            for _, d in ipairs(DIRS4) do
                local nr, nc = r + d[1], c + d[2]
                if nr >= 1 and nr <= n and nc >= 1 and nc <= n then l[#l + 1] = (nr - 1) * n + nc end
            end
            G.nbr4[i] = l
            local ring = {}
            for k, d in ipairs(DIRS8) do
                local nr, nc = r + d[1], c + d[2]
                ring[k] = (nr >= 1 and nr <= n and nc >= 1 and nc <= n) and ((nr - 1) * n + nc) or false
            end
            G.ring[i] = ring
        end
    end
    for r = 1, n - 1 do
        for c = 1, n - 1 do
            local i = (r - 1) * n + c
            G.blocks[#G.blocks + 1] = { i, i + 1, i + n, i + n + 1 }
        end
    end
    geometry[n] = G
    return G
end
Solver.geom = geom

-- The patterns of the clue `groups` at cell i that fit the grid's edge.
function Solver.cluePatterns(n, i, groups)
    local ring = geom(n).ring[i]
    local pats = {}
    for _, p in ipairs(RING_PATTERNS[clueKey(groups)] or {}) do
        local ok = true
        for k = 1, 8 do
            if not ring[k] and p[k] == 1 then ok = false; break end
        end
        if ok then pats[#pats + 1] = p end
    end
    return pats
end

-- A problem: P = { n = n, clues = { { cell = i, pats = {...} }, ... } }.
-- Board.problem builds it from a clue grid.
function Solver.problem(clues, n)
    local P = { n = n, clues = {} }
    for r = 1, n do
        for c = 1, n do
            local g = clues[r] and clues[r][c]
            if g then
                local i = (r - 1) * n + c
                P.clues[#P.clues + 1] = { cell = i, pats = Solver.cluePatterns(n, i, g) }
            end
        end
    end
    return P
end

-- ---------------------------------------------------------------------------
-- Tier 1
-- ---------------------------------------------------------------------------

local cur, agree = {}, {}

-- One clue: returns ok, changed.
local function clueProp(cl, ring, s)
    local changed = false
    if s[cl.cell] == 1 then return false end
    if s[cl.cell] == 0 then s[cl.cell] = 2; changed = true end
    local free = false
    for k = 1, 8 do
        local i = ring[k]
        local v = i and s[i] or 2
        cur[k] = v
        if v == 0 then free = true end
        agree[k] = 0
    end
    local left = 0
    for _, p in ipairs(cl.pats) do
        local ok = true
        for k = 1, 8 do
            local v = cur[k]
            if v ~= 0 and v ~= p[k] then ok = false; break end
        end
        if ok then
            left = left + 1
            if free then
                for k = 1, 8 do
                    if cur[k] == 0 then
                        local a = agree[k]
                        if a == 0 then agree[k] = p[k] elseif a ~= p[k] then agree[k] = 3 end
                    end
                end
            end
        end
    end
    if left == 0 then return false end
    if free then
        for k = 1, 8 do
            local a = agree[k]
            if cur[k] == 0 and a ~= 3 and a ~= 0 then
                s[ring[k]] = a
                changed = true
            end
        end
    end
    return true, changed
end

local comp = {}
local function tier1(P, G, s)
    local N, nbr4 = G.N, G.nbr4
    while true do
        local changed = false
        for _, cl in ipairs(P.clues) do
            local ok, ch = clueProp(cl, G.ring[cl.cell], s)
            if not ok then return false end
            if ch then changed = true end
        end
        for _, b in ipairs(G.blocks) do
            local sh, free = 0, nil
            for k = 1, 4 do
                local v = s[b[k]]
                if v == 1 then sh = sh + 1 elseif v == 0 then free = b[k] end
            end
            if sh == 4 then return false end
            if sh == 3 and free then s[free] = 2; changed = true end
        end
        -- local wall
        local total = 0
        for i = 1, N do if s[i] == 1 then total = total + 1 end end
        if total > 0 then
            for i = 1, N do
                if s[i] == 0 then
                    local open = false
                    for _, j in ipairs(nbr4[i]) do
                        if s[j] ~= 2 then open = true; break end
                    end
                    if not open then s[i] = 2; changed = true end
                end
            end
            for i = 1, N do comp[i] = false end
            for i = 1, N do
                if s[i] == 1 and not comp[i] then
                    local stack, top, size = { i }, 1, 0
                    local exit, exits = nil, 0
                    comp[i] = true
                    while top > 0 do
                        local x = stack[top]; top = top - 1
                        size = size + 1
                        for _, y in ipairs(nbr4[x]) do
                            local v = s[y]
                            if v == 1 then
                                if not comp[y] then comp[y] = true; top = top + 1; stack[top] = y end
                            elseif v == 0 and comp[y] ~= i then
                                comp[y] = i   -- counted as this group's exit
                                exits = exits + 1; exit = y
                            end
                        end
                    end
                    -- (undecided cells marked as exits are reset below)
                    if size < total then
                        if exits == 0 then return false end
                        if exits == 1 then s[exit] = 1; changed = true; break end
                    end
                end
            end
        end
        if not changed then return true end
    end
end

-- ---------------------------------------------------------------------------
-- Tier 2: one step (returns ok, changed)
-- ---------------------------------------------------------------------------

local seen, stack2 = {}, {}
local function reach(G, s, from, blocked)
    local N, nbr4 = G.N, G.nbr4
    for i = 1, N do seen[i] = false end
    if blocked then seen[blocked] = true end
    seen[from] = true
    local top = 1
    stack2[1] = from
    while top > 0 do
        local x = stack2[top]; top = top - 1
        for _, y in ipairs(nbr4[x]) do
            if not seen[y] and s[y] ~= 2 then
                seen[y] = true
                top = top + 1; stack2[top] = y
            end
        end
    end
    if blocked then seen[blocked] = false end
end

-- The undecided cell of lowest index every path between two shaded cells
-- goes through, or nil: one depth-first search over the cells that may
-- still be shaded (Hopcroft-Tarjan cut vertices), with the shaded cells
-- counted per subtree. `first` is a shaded cell, the root.
local disc, low, sub, parent, nexti = {}, {}, {}, {}, {}
local function cutCell(G, s, first)
    local N, nbr4 = G.N, G.nbr4
    local total = 0
    for i = 1, N do
        disc[i] = 0
        if s[i] == 1 then total = total + 1 end
    end
    local best
    local time, top = 1, 1
    disc[first], low[first], sub[first], nexti[first], parent[first] = 1, 1, 1, 1, 0
    stack2[1] = first
    while top > 0 do
        local v = stack2[top]
        local l = nbr4[v]
        local k = nexti[v]
        if k <= #l then
            nexti[v] = k + 1
            local w = l[k]
            if s[w] ~= 2 then
                if disc[w] == 0 then
                    time = time + 1
                    disc[w], low[w], nexti[w], parent[w] = time, time, 1, v
                    sub[w] = (s[w] == 1) and 1 or 0
                    top = top + 1; stack2[top] = w
                elseif w ~= parent[v] and disc[w] < low[v] then
                    low[v] = disc[w]
                end
            end
        else
            top = top - 1
            local p = parent[v]
            if p ~= 0 then
                if low[v] < low[p] then low[p] = low[v] end
                sub[p] = sub[p] + sub[v]
                if low[v] >= disc[p] and s[p] == 0 and sub[v] > 0 and total > sub[v]
                   and (not best or p < best) then
                    best = p
                end
            end
        end
    end
    return best
end

local function tier2(G, s)
    local N = G.N
    local first
    for i = 1, N do if s[i] == 1 then first = i; break end end
    if not first then return true, false end
    reach(G, s, first)
    local cut = false
    for i = 1, N do
        if not seen[i] then
            if s[i] == 1 then return false end
            if s[i] == 0 then s[i] = 2; cut = true end
        end
    end
    if cut then return true, true end
    local i = cutCell(G, s, first)
    if i then
        s[i] = 1
        return true, true
    end
    return true, false
end

local function isDone(G, s)
    for i = 1, G.N do if s[i] == 0 then return false end end
    return true
end

-- state (optional): a state to go on from (it is changed in place);
-- otherwise every cell starts undecided.
function Solver.solve(P, tier, state)
    local G = geom(P.n)
    local s = state
    if not s then
        s = {}
        for i = 1, G.N do s[i] = 0 end
    end
    local steps = 0
    while true do
        if not tier1(P, G, s) then return "contradiction", steps > 0 and 2 or 1, steps, s end
        if isDone(G, s) then return "solved", steps > 0 and 2 or 1, steps, s end
        if (tier or 2) < 2 then return "stuck", 1, steps, s end
        local ok, ch = tier2(G, s)
        if not ok then return "contradiction", 2, steps, s end
        if not ch then return "stuck", steps > 0 and 2 or 1, steps, s end
        steps = steps + 1
    end
end

return Solver
