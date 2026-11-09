-- Difficulty guarantees for Tapa: every size x level builds a unique
-- puzzle quickly, the game's logic solver (solver.lua) finishes it at the
-- level's tier with no trial, Easy needs tier 1 only, Medium exactly one
-- tier-2 step and Hard more, Easy shows the most clues, and a seed gives the
-- same puzzle without reading the clock.
local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

-- Runs fn with os.clock/os.time/os.date replaced by functions that fail:
-- a generator must bound its work by counts, never by time.
local function withoutClock(fn)
    local oc, ot, od = os.clock, os.time, os.date
    local function boom(name) return function() error("generator read " .. name, 2) end end
    os.clock, os.time, os.date = boom("os.clock"), boom("os.time"), boom("os.date")
    local ok, err = pcall(fn)
    os.clock, os.time, os.date = oc, ot, od
    if not ok then error(err, 0) end
end

describe("Tapa difficulty", function()
    local Board

    setup(function()
        Board = require("board")
    end)

    local function isConnected(shaded, n)
        local sr, sc
        for r = 1, n do
            for c = 1, n do
                if shaded[r][c] then sr, sc = r, c; goto found end
            end
        end
        ::found::
        if not sr then return true end
        local visited = {}
        for r = 1, n do visited[r] = {} end
        local stack = {{sr, sc}}
        visited[sr][sc] = true
        local count = 1
        while #stack > 0 do
            local cell = table.remove(stack)
            for _, d in ipairs({{-1,0},{1,0},{0,-1},{0,1}}) do
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
        for r = 1, n do for c = 1, n do if shaded[r][c] then total = total + 1 end end end
        return count == total
    end

    describe("uniqueness", function()
        it("every generated puzzle is unique, and generation is fast", function()
            for _, n in ipairs({ 6, 8, 10 }) do
                for _, diff in ipairs({ "easy", "medium", "hard" }) do
                    local worst = 0
                    for seed = 1, 8 do
                        math.randomseed(seed * 7919 + n)
                        local t0 = os.clock()
                        local b = Board:new{ n = n }
                        b:generate(diff)
                        worst = math.max(worst, os.clock() - t0)
                        assert.is_true(isConnected(b.solution, n))
                        for r = 1, n - 1 do
                            for c = 1, n - 1 do
                                assert.is_false(b.solution[r][c] and b.solution[r + 1][c]
                                    and b.solution[r][c + 1] and b.solution[r + 1][c + 1] or false)
                            end
                        end
                        local solutions, exhausted = Board.countSolutions(b.clues, n, 2, 1e6)
                        assert.is_false(exhausted)
                        assert.are.equal(1, solutions,
                            ("n=%d diff=%s seed=%d: not unique"):format(n, diff, seed))
                    end
                    -- ~20 ms worst on a desktop (10x10 took up to 2 s before
                    -- 1.5.0); generous for slow CI.
                    assert.is_true(worst < 1.0, ("n=%d diff=%s took %.2fs"):format(n, diff, worst))
                end
            end
        end)
    end)

    describe("logic solver and levels (1.6.0)", function()
        local Solver

        setup(function()
            Solver = dofile(DIR .. "solver.lua")
        end)

        -- the solver's verdict; a solved grid must be the stored solution
        local function grade(b)
            local st, tier, steps, s = Solver.solve(Solver.problem(b.clues, b.n), 2)
            if st == "solved" then
                for r = 1, b.n do
                    for c = 1, b.n do
                        assert.are.equal(b.solution[r][c] and 1 or 2, s[(r - 1) * b.n + c])
                    end
                end
            end
            return st, tier, steps
        end

        local function clueShare(b)
            local clues, cand = 0, 0
            for r = 1, b.n do
                for c = 1, b.n do
                    if b.clues[r][c] then clues = clues + 1 end
                    if not b.solution[r][c] then
                        for dr = -1, 1 do
                            for dc = -1, 1 do
                                local rr, cc = r + dr, c + dc
                                if (dr ~= 0 or dc ~= 0) and b.solution[rr] and b.solution[rr][cc] then
                                    cand = cand + 1
                                    goto counted
                                end
                            end
                        end
                        ::counted::
                    end
                end
            end
            return clues / cand
        end

        it("every puzzle is solved by logic alone at its level's tier, and the levels are in order", function()
            for _, n in ipairs({ 6, 8, 10 }) do
                local share, steps_sum = {}, {}
                for _, diff in ipairs({ "easy", "medium", "hard" }) do
                    share[diff], steps_sum[diff] = 0, 0
                    for seed = 1, 10 do
                        math.randomseed(seed * 7919 + n)
                        local b = Board:new{ n = n }
                        b:generate(diff)
                        local st, tier, steps = grade(b)
                        local where = ("n=%d %s seed=%d"):format(n, diff, seed)
                        assert.are.equal("solved", st, where)
                        if diff == "easy" then
                            assert.are.equal(1, tier, where)
                        else
                            assert.are.equal(2, tier, where)
                        end
                        if diff == "medium" then assert.are.equal(1, steps, where) end
                        share[diff] = share[diff] + clueShare(b) / 10
                        steps_sum[diff] = steps_sum[diff] + steps / 10
                    end
                end
                -- Easy shows the most clues, Hard needs the most steps
                assert.is_true(share.easy > share.medium + 0.1, "n=" .. n)
                assert.is_true(share.easy > share.hard + 0.1, "n=" .. n)
                assert.is_true(steps_sum.hard > steps_sum.medium + 0.5, "n=" .. n)
            end
        end)

        it("Hard needs two steps or more on most seeds", function()
            for _, n in ipairs({ 6, 8, 10 }) do
                local inside = 0
                for seed = 1, 30 do
                    math.randomseed(seed * 7919 + n)
                    local b = Board:new{ n = n }
                    b:generate("hard")
                    local _, _, steps = grade(b)
                    if steps >= 2 then inside = inside + 1 end
                end
                -- measured 29-30 / 30 at 6x6 and 8x8, 26 / 30 at 10x10
                assert.is_true(inside >= 24, ("n=%d: %d/30"):format(n, inside))
            end
        end)

        it("the same seed gives the same puzzle", function()
            local function draw()
                math.randomseed(1234)
                local b = Board:new{ n = 8 }
                b:generate("hard")
                return b
            end
            local a, b = draw(), draw()
            assert.are.same(a.solution, b.solution)
            assert.are.same(a.clues, b.clues)
        end)

        it("generation never reads the clock", function()
            for _, n in ipairs(Board.SIZES) do
                for _, diff in ipairs({ "easy", "medium", "hard" }) do
                    local b = Board:new{ n = n }
                    math.randomseed(n * 11)
                    withoutClock(function() b:generate(diff) end)
                end
            end
        end)
    end)
end)
