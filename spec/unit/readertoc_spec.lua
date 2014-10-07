require("commonrequire")
local DocumentRegistry = require("document/documentregistry")
local ReaderUI = require("apps/reader/readerui")
local DEBUG = require("dbg")

describe("Readertoc module", function()
    local sample_epub = "spec/front/unit/data/juliet.epub"
    local readerui = ReaderUI:new{
        document = DocumentRegistry:openDocument(sample_epub),
    }
    local toc = readerui.toc
    local toc_max_depth = nil
    it("should get max toc depth", function()
        toc_max_depth = toc:getMaxDepth()
        assert.are.same(2, toc_max_depth)
    end)
    it("should get toc title from page", function()
        local title = toc:getTocTitleByPage(56)
        assert(title == "Prologue")
        local title = toc:getTocTitleByPage(172)
        assert(title == "SCENE IV. Hall in Capulet's house.")
    end)
    describe("getTocTicks API", function()
        local ticks_level_0 = nil
        it("should get ticks of level 0", function()
            ticks_level_0 = toc:getTocTicks(0)
            assert.are.same(26, #ticks_level_0)
        end)
        local ticks_level_1 = nil
        it("should get ticks of level 1", function()
            ticks_level_1 = toc:getTocTicks(1)
            assert.are.same(7, #ticks_level_1)
        end)
        local ticks_level_m1 = nil
        it("should get ticks of level -1", function()
            ticks_level_m1 = toc:getTocTicks(1)
            assert.are.same(7, #ticks_level_m1)
        end)
        it("should get the same ticks of level -1 and level 1", function()
            if toc_max_depth == 2 then
                assert.are.same(ticks_level_1, ticks_level_m1)
            end
        end)
    end)
    it("should get page of next chapter", function()
        assert.are.same(25, toc:getNextChapter(10, 0))
        assert.are.same(103, toc:getNextChapter(100, 0))
        assert.are.same(nil, toc:getNextChapter(200, 0))
    end)
    it("should get page of previous chapter", function()
        assert.are.same(9, toc:getPreviousChapter(10, 0))
        assert.are.same(95, toc:getPreviousChapter(100, 0))
        assert.are.same(190, toc:getPreviousChapter(200, 0))
    end)
    it("should get page left of chapter", function()
        assert.are.same(15, toc:getChapterPagesLeft(10, 0))
        assert.are.same(3, toc:getChapterPagesLeft(100, 0))
        assert.are.same(nil, toc:getChapterPagesLeft(200, 0))
    end)
end)
