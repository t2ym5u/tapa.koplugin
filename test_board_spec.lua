local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

describe("TapaBoard", function()
    local Board

    setup(function()
        Board = require("board")
    end)


    local function newBoard(n, diff)
        math.randomseed(42)
        local b = Board:new{ n = n or 8 }
        b:generate(diff or "medium")
        return b
    end

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

    describe("construction", function()
        it("creates an 8×8 board by default", function()
            local b = Board:new()
            assert.are.equal(8, b.n)
        end)

        it("exposes SIZES", function()
            assert.are.same({6, 8, 10}, Board.SIZES)
        end)
    end)

    describe("generate", function()
        it("solution has no 2×2 all-shaded block", function()
            local b = newBoard(8)
            local n = b.n
            for r = 1, n-1 do
                for c = 1, n-1 do
                    local block = b.solution[r][c] and b.solution[r+1][c]
                        and b.solution[r][c+1] and b.solution[r+1][c+1]
                    assert.is_false(block, ("2x2 block at [%d][%d]"):format(r, c))
                end
            end
        end)

        it("shaded cells in the solution are orthogonally connected", function()
            local b = newBoard(8)
            assert.is_true(isConnected(b.solution, b.n))
        end)

        it("clue cells hold non-empty lists of run lengths in 1..8", function()
            local b = newBoard(8)
            for r = 1, b.n do
                for c = 1, b.n do
                    local groups = b.clues[r] and b.clues[r][c]
                    if groups then
                        assert.is_true(#groups >= 1)
                        for _, v in ipairs(groups) do
                            assert.is_true(v >= 1 and v <= 8)
                        end
                    end
                end
            end
        end)

        it("clue cells are never shaded in the solution", function()
            local b = newBoard(8)
            for r = 1, b.n do
                for c = 1, b.n do
                    if b:isClue(r, c) then
                        assert.is_false(b.solution[r][c])
                    end
                end
            end
        end)
    end)

    describe("tapCell", function()
        it("toggles a non-clue cell", function()
            local b = newBoard(8)
            local r, c
            for rr = 1, b.n do
                for cc = 1, b.n do
                    if not b:isClue(rr, cc) then r, c = rr, cc; goto done end
                end
            end
            ::done::
            assert.is_false(b.user[r][c])
            b:tapCell(r, c)
            assert.is_true(b.user[r][c])
            b:tapCell(r, c)
            assert.is_false(b.user[r][c])
        end)

        it("does nothing on a clue cell", function()
            local b = newBoard(8)
            local r, c
            for rr = 1, b.n do
                for cc = 1, b.n do
                    if b:isClue(rr, cc) then r, c = rr, cc; goto done end
                end
            end
            ::done::
            if not r then return end
            b:tapCell(r, c)
            assert.is_false(b.user[r][c])
        end)
    end)

    describe("checkProgress", function()
        it("marks a non-clue cell that doesn't match the solution", function()
            local b = newBoard(8)
            local r, c
            for rr = 1, b.n do
                for cc = 1, b.n do
                    if not b:isClue(rr, cc) then r, c = rr, cc; goto done end
                end
            end
            ::done::
            b.user[r][c] = not b.solution[r][c]
            local ok, errors = b:checkProgress()
            assert.is_false(ok)
            assert.is_true(errors >= 1)
            assert.is_true(b.wrong[r][c])
        end)

        it("reports zero errors when user matches solution", function()
            local b = newBoard(8)
            for r = 1, b.n do
                for c = 1, b.n do
                    if not b:isClue(r, c) then b.user[r][c] = b.solution[r][c] end
                end
            end
            local ok, errors = b:checkProgress()
            assert.is_true(ok)
            assert.are.equal(0, errors)
        end)
    end)

    describe("counts", function()
        it("countShaded / countSolutionShaded / countClues are consistent", function()
            local b = newBoard(8)
            assert.are.equal(0, b:countShaded())
            local sol_count = 0
            for r = 1, b.n do for c = 1, b.n do if b.solution[r][c] then sol_count = sol_count + 1 end end end
            assert.are.equal(sol_count, b:countSolutionShaded())
            assert.is_true(b:countClues() >= 1)
        end)
    end)

    describe("toggleReveal", function()
        it("flips isShowingSolution", function()
            local b = newBoard(8)
            assert.is_false(b:isShowingSolution())
            b:toggleReveal()
            assert.is_true(b:isShowingSolution())
        end)
    end)

    describe("serialize / load", function()
        it("round-trips solution, clues and user shading", function()
            local b = newBoard(8)
            local r, c
            for rr = 1, b.n do
                for cc = 1, b.n do
                    if not b:isClue(rr, cc) then r, c = rr, cc; goto done end
                end
            end
            ::done::
            b:tapCell(r, c)

            local data = b:serialize()
            local b2 = Board:new{ n = 8 }
            local ok = b2:load(data)
            assert.is_true(ok)
            assert.are.equal(b.n, b2.n)
            assert.are.equal(b.user[r][c], b2.user[r][c])
            for rr = 1, b.n do
                for cc = 1, b.n do
                    assert.are.equal(b.solution[rr][cc], b2.solution[rr][cc])
                end
            end
        end)

        it("load returns false for invalid data", function()
            local b = Board:new()
            assert.is_false(b:load(nil))
            assert.is_false(b:load({}))
        end)
    end)
    describe("uniqueness check (1.5.0)", function()
        local function centre(groups)
            return { {}, { [2] = groups }, {} }
        end

        it("counts the shadings around a single 3x3 clue", function()
            assert.are.equal(8, (Board.countSolutions(centre({ 1 }), 3, 100, 1e6)))
            assert.are.equal(8, (Board.countSolutions(centre({ 2 }), 3, 100, 1e6)))
            -- two separate cells can't join up: no other cell to shade
            assert.are.equal(0, (Board.countSolutions(centre({ 1, 1 }), 3, 100, 1e6)))
            assert.are.equal(1, (Board.countSolutions(centre({ 8 }), 3, 100, 1e6)))
        end)

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

        it("solves a single clue only when it is forced", function()
            -- 3x3, centre clue 8: the whole ring is shaded
            local st, tier, steps, s = Solver.solve(Solver.problem({ {}, { [2] = { 8 } }, {} }, 3), 2)
            assert.are.equal("solved", st)
            assert.are.equal(1, tier)
            assert.are.equal(0, steps)
            for i = 1, 9 do assert.are.equal(i == 5 and 2 or 1, s[i]) end
            -- clue 1: eight shadings fit, logic must stop short
            assert.are.equal("stuck", (Solver.solve(Solver.problem({ {}, { [2] = { 1 } }, {} }, 3), 2)))
        end)

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

        it("reports progress between 0 and 1", function()
            math.randomseed(5)
            local b = Board:new{ n = 6 }
            local calls = 0
            b:generate("hard", function(f)
                calls = calls + 1
                assert.is_true(f > 0 and f < 1)
            end)
            assert.is_true(calls > 0)
        end)
    end)

    describe("win check (1.6.0)", function()
        it("accepts any shading that keeps the rules, not only the stored one", function()
            -- 3x3 with one clue {1} in a corner: (1,2) or (2,1) or (2,2)
            -- shaded alone all keep it; stored solution is (1,2)
            local b = Board:new{ n = 3 }
            b.solution = { { false, true, false }, { false, false, false }, { false, false, false } }
            b.clues = { { [1] = { 1 } }, {}, {} }
            b.user = { { false, false, false }, { true, false, false }, { false, false, false } }
            b:_checkSolved()
            assert.is_true(b.solved)
            -- two separate pieces: not connected
            b.user = { { false, false, true }, { true, false, false }, { false, false, false } }
            b:_checkSolved()
            assert.is_false(b.solved)
            -- clue broken
            b.user = { { false, false, false }, { false, false, false }, { false, false, true } }
            b:_checkSolved()
            assert.is_false(b.solved)
            -- 2x2 block
            b.clues = { { [1] = { 2 } }, {}, {} }
            b.user = { { false, true, true }, { false, true, true }, { false, false, false } }
            b:_checkSolved()
            assert.is_false(b.solved)
        end)

        it("accepts the generated solution", function()
            for _, diff in ipairs({ "easy", "medium", "hard" }) do
                math.randomseed(77)
                local b = Board:new{ n = 8 }
                b:generate(diff)
                for r = 1, 8 do
                    for c = 1, 8 do b.user[r][c] = b.solution[r][c] end
                end
                b:_checkSolved()
                assert.is_true(b.solved, diff)
            end
        end)

        it("loads a 1.5.x save", function()
            local b = Board:new{ n = 6 }
            local data = {
                n = 6, difficulty = "hard",
                solution = { { true, true, false, false, false, false }, { false, true, false, false, false, false },
                             { false, false, false, false, false, false }, { false, false, false, false, false, false },
                             { false, false, false, false, false, false }, { false, false, false, false, false, false } },
                clues = { {}, { [1] = { 3 } }, {}, {}, {}, {} },
                user = { { true, false, false, false, false, false } },
            }
            assert.is_true(b:load(data))
            assert.are.same({ 3 }, b.clues[2][1])
            assert.is_true(b.user[1][1])
        end)
    end)

    describe("fallback shading", function()
        it("the comb with every clue shown is solved at tier 1 on every size", function()
            local Solver = dofile(DIR .. "solver.lua")
            for _, n in ipairs({ 6, 8, 10 }) do
                local shaded = {}
                for r = 1, n do
                    shaded[r] = {}
                    for c = 1, n do shaded[r][c] = (c == 1 or r % 2 == 1) end
                end
                local clues = {}
                for r = 1, n do
                    clues[r] = {}
                    for c = 1, n do
                        if not shaded[r][c] then
                            clues[r][c] = Board._computeClue(shaded, n, r, c)
                        end
                    end
                end
                local st, tier = Solver.solve(Solver.problem(clues, n), 1)
                assert.are.equal("solved", st, "n=" .. n)
                assert.are.equal(1, tier)
            end
        end)
    end)
end)
