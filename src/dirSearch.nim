import os
import ospaths
import system
import times
import strformat
import strutils
import sequtils
import nre

type
    BycopyItr {.bycopy.} = int
    PathKind = enum ## definition of path kind
        pAny,   ## not select something special
        pFile,  ## select file
        pDir,   ## select direction
        pArchive,   ## select archive file
        pRec    ## select reparse point(including link, symbolic link)
    PathRegexKind = enum
        str, any, wldc, reg
    PathElement = object
        value: string
        rKind: PathRegexKind
        pKind: PathKind
    PathSearch = object
        debug: bool
        pathElements: seq[PathElement]
        rootPath: string
        osPathSeparator: string
        anyString: string
        wldcString: string
        regexStartString: string
        regexEndString: string
        kindStartString: string
        kindEndString: string

proc lastArr[T](arr: openArray[T]): T =
    ## returns last element of `arr`
    result = arr[len(arr)-1]

proc selectArr[T](arr: openArray[T], starts = -1, ends = -1): seq[T] =
    var arrLen = len(arr)
    let start = if starts == -1: 0 else: starts
    let endp = if ends == -1: arrLen-1 else: ends
    result = arr[start..<endp]

proc makePathElements(self: var PathSearch, pathString: string) =
    ## makes PathElement sequence from `pathString`
    let splitPathString = pathString.split(self.osPathSeparator)
    if splitPathString.lastArr() == self.anyString:
        self.pathElements = @[]
    else:
        var
            res = PathElement(value:"", rKind: PathRegexKind.str, pKind:PathKind.pAny)
            regexItr = 0
        for i, elem in splitPathString:
            if elem.startsWith(self.regexStartString):
                res.value = elem
                regexItr = i
            if elem.endsWith(self.regexEndString):
                if i != regexItr:
                    res.value = [res.value,elem].join(self.osPathSeparator)
                regexItr = -1
                res.rKind = PathRegexKind.reg
                res.value = $(res.value.selectArr(len(self.regexStartString),len(res.value)-len(self.regexEndString))).join()
                self.pathElements.add(res)
                res = PathElement(value:"", rKind: PathRegexKind.str, pKind:PathKind.pAny)
            else:
                res.value = elem
                if res.value == self.anyString: #dot
                    res.rKind = PathRegexKind.any
                elif isSome(res.value.match(re"^[*]+$")):
                    res.rKind = PathRegexKind.wldc
                else:
                    res.value = "^" & res.value & "$"
                self.pathElements.add(res)
                res = PathElement(value:"", rKind: PathRegexKind.str, pKind:PathKind.pAny)

proc walkDirRegex(rootPath: string, regex: Regex, level: int, sep: string): seq[string] =
    ## level: *の数だけinc -> 「*/abc」ならregex=abc,level=2
    ##      : any_の場合は-1
    ## TODO:kind未実装
    ## TODO:再帰しない実装
    for kind,path in rootPath.walkDir(true):
        if level <= 1:
            if path.match(regex).isSome():
                result = concat(result, @[[rootPath, path].join(sep)])
        if level != 1:
            result = concat(result, walkDirRegex([rootPath, path].join(sep), regex, level-1, sep))

proc searchImpl(self: PathSearch, rootPath: string): seq[string] {.inline.} =
    let debug = self.debug
    var
        pItr: ptr int
        qItr: int
        searchQueue: seq[tuple[realPath:string,virtualPath:string,rItr:int]] = @[(rootPath, "", 0)]
        newSearchQueue: seq[tuple[realPath:string,virtualPath:string,rItr:int]]
        queueLen :int
        rootPath: string
        regex: Regex
        level: int
        sep: string
        walkResSeq: seq[string]
        virtualPath: string
    while len(searchQueue) != 0:
        queueLen = len(searchQueue)
        for qItr in 0..<queueLen:
            pItr = addr(searchQueue[qItr].rItr)
            rootPath = searchQueue[qItr].realPath
            regex = re(self.pathElements[pItr[]].value)
            level = 1
            sep = self.osPathSeparator
            if self.pathElements[pItr[]].rKind == PathRegexKind.any:
                inc(pItr[])
                regex = re(self.pathElements[pItr[]].value)
                level = -1
            elif self.pathElements[pItr[]].rKind == PathRegexKind.wldc:
                level = len(self.pathElements[pItr[]].value)+1
                inc(pItr[])
                regex = re(self.pathElements[pItr[]].value)
            if debug: echo fmt"rItr:{pItr[]}"
            if debug: echo fmt"regex:{regex.pattern}"
            if debug: echo fmt"kind:{self.pathElements[pItr[]].rKind}"
            walkResSeq = rootPath.walkDirRegex(regex, level, sep)
            if debug: echo fmt"walkResSeq:{walkResSeq}"
            for walkRes in walkResSeq:
                virtualPath = ""
                if false: # for zipfile block
                    discard
                if searchQueue[qItr].rItr == len(self.pathElements)-1:
                    result.add(walkRes)
                else:
                    newSearchQueue.add((walkRes,virtualPath,pItr[]+1))
        searchQueue = @[]
        searchQueue = newSearchQueue
        newSearchQueue = @[]

proc initPathSearch(pathString: string, debug=false): PathSearch =
    result = PathSearch()
    result.debug = debug
    result.osPathSeparator = $(ospaths.DirSep)
    result.anyString = "..."
    result.wldcString = "*"
    result.regexStartString = "<<"
    result.regexEndString = ">>"
    result.kindStartString = "||"
    result.kindEndString = "||"
    result.makePathElements(pathString)
    if result.debug: echo fmt"pathElements:{result.pathElements}"

proc search(self: PathSearch, rootPath: string): seq[string] =
    result = self.searchImpl(rootPath)
 #[
proc test__all(): bool =
    var test_directory_structure = @[
        r"test\あ\あい",
        r"test\あ\あう",
        r"test\A\AB",
        r"test\A\AC",
    ]
    var
        fp: File
        path: string
    for p in test_directory_structure:
        path = os.joinPath(os.getCurrentDir, p)
        createDir(path)
        fp.open(os.joinPath(path,p.split(r"\").lastArr()), fmWrite)
        fp.write(fmt"{path}\n")
        fp.close()
    var testPattern: seq[string] = @[
        r"",# all直指定（正常）
        r"",# 始めdot指定（正常）
        r"",# 途中dot指定（正常）
        r"",# 終わりdot指定（エラー）
        r"",# 始め*指定（正常）
        r"",# 途中*指定（正常）
        r"",# 終わり*指定（正常）
        r"",# 始めreg指定（正常）
        r"",# 途中reg指定（正常）
        r"",# 終わりreg指定（正常）
    ]
    var
        rootPath = r"testRoot"
        pt: PathSearch
        res: seq[string]
    for pattern in testPattern:
        pt = initPathSearch(pattern)
        res = pt.search(rootPath)
        # pt = initPathSearch(rootPath)
        # res = pt.search(pattern)
]#

if isMainModule:
    var time = cpuTime()
    var
        ps: PathSearch
        res: seq[string]
        debug = true

    ps = initPathSearch(r"testRoot\A\あ\Aあ\<<Aあ![.]txt>>", debug)
    res = ps.search(os.getCurrentDir())
    echo "*********************************************"
    echo res
    echo "---------------------------------------------"

    ps = initPathSearch(r"...\Aあ!.txt", debug)
    res = ps.search(os.getCurrentDir())
    echo "*********************************************"
    echo res
    echo "---------------------------------------------"
    
    ps = initPathSearch(r"...\project_boringwork\...\<<Aあ![.]txt>>", false)
    res = ps.search(r"Z:")
    echo "*********************************************"
    echo res
    echo "---------------------------------------------"
    echo "Time:" & $(cpuTime()-time)