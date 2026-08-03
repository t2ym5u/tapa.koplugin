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
end)
