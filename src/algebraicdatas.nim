
import strformat
import strutils
import sequtils
import tables
import options

import macros
import macroutils
import ast_pattern_matching


func enumerate*[T](s: openArray[T]): auto =
    toSeq(0..<s.len).zip(s)

type
    VariantKind = enum
        NoField
        Tagged
        Untagged
    MatchError = object of ValueError

template variant {.pragma.}
template kind {.pragma.}


func scanName(name: NimNode): (NimNode, NimNode) =
    name.matchAst:
    of nnkIdent:
        return (name, newEmptyNode())
    of nnkBracketExpr:
        name[0].expectKind(nnkIdent)
        result[0] = name[0]
        result[1] = nnkGenericParams.newNimNode()
        let generics = name[1..^1]
        for e in generics:
            e.matchAst:
            of nnkIdent:
                result[1].add newIdentDefs(e, newEmptyNode())
            of nnkExprColonExpr:
                result[1].add newIdentDefs(e[0], e[1])

func scanFields(body: NimNode): (seq[NimNode], seq[(NimNode, VariantKind, seq[NimNode])]) =
    var
        fields: seq[NimNode]
        kinds: typeof(result[1])
    for field in body:
        field.matchAst:
        of nnkCall(`field`@nnkIdent, nnkStmtList(`typ`@nnkIdent)):
            fields.add newIdentDefs(field, typ)
        of nnkObjConstr:
            field[0].expectKind(nnkIdent)
            var kind: (NimNode, VariantKind, seq[NimNode]) = (field[0], Tagged, @[])
            let
                params = field[1..^1]
            for param in params:
                param.expectKind(nnkExprColonExpr)
                kind[2].add newIdentDefs(param[0], param[1])
            kinds.add kind
        of nnkCall:
            field[0].expectKind(nnkIdent)
            var kind: (NimNode, VariantKind, seq[NimNode]) = (field[0], Untagged, @[])
            let
                params = field[1..^1]
            for i, param in params:
                param.expectKind(nnkIdent)
                kind[2].add param
            kinds.add kind
        of nnkIdent:
            var kind: (NimNode, VariantKind, seq[NimNode]) = (field, NoField, @[])
            kinds.add kind
    (fields, kinds)

proc makeType(name: NimNode, generics: NimNode, fields: seq[NimNode], kinds: seq[(NimNode, VariantKind, seq[NimNode])]): NimNode =
    func generalize(id: NimNode, generics: NimNode): NimNode =
        if generics.kind == nnkEmpty:
            return id
        generics.expectKind(nnkGenericParams)
        # id, @[T1: SomeInteger, T2: SomeFloat] -> id[T1, T2]
        nnkBracketExpr.newTree(id).add(
            generics.mapIt(
                block:
                    it.expectKind(nnkIdentDefs);
                    it[0]
            )
        )
    name.expectKind(nnkIdent)
    result = nnkTypeSection.newNimNode()
    let
        genericParams = generics.mapIt(it)
        kindId = ident(fmt"{name}kind")
        kind = newEnum(kindId, kinds.mapIt(it[0]), true, true)[0]
        impls = kinds.filterIt(it[1] != NoField).mapIt(
            nnkTypeDef.newTree(
                postfix(ident(fmt"{it[0]}Impl"), "*"),
                generics,
                case it[1]
                of Tagged:
                    nnkObjectTy.newTree(
                        newEmptyNode(),
                        newEmptyNode(),
                        nnkRecList.newTree(
                            it[2].mapIt(newIdentDefs(postfix(it[0], "*"), it[1]))
                        )
                    )
                of Untagged:
                    nnkTupleConstr.newTree(
                        it[2]
                    )
                of NoField:
                    newEmptyNode()
            )
        )
        variant = nnkTypeDef.newTree(
            nnkPragmaExpr.newTree(
                postfix(name, "*"),
                nnkPragma.newTree(
                    bindSym"variant"
                )
            ),
            generics,
            nnkObjectTy.newTree(
                newEmptyNode(),
                newEmptyNode(),
                nnkRecList.newTree(fields.mapIt(newIdentDefs(postfix(it[0], "*"), it[1]))).add(
                    nnkRecCase.newTree(
                        newIdentDefs(postfix(ident"kind", "*"), kindId)
                    ).add kinds.mapIt(
                        nnkOfBranch.newTree(
                            newDotExpr(kindId, it[0]),
                            nnkRecList.newTree(
                                case it[1]
                                of NoField:
                                    newNilLit()
                                else:
                                    newIdentDefs(
                                        postfix(ident(fmt"{it[0]}Field"), "*"),
                                        ident(fmt"{it[0]}Impl").generalize(generics)
                                    )
                            )
                        )
                    )
                )
            )
        )
    result.add kind
    result.add impls
    result.add variant

func makeConstructor(name: NimNode, generics: NimNode, fields: seq[NimNode], kinds: seq[(NimNode, VariantKind, seq[NimNode])]): seq[NimNode] =
    func generalize(id: NimNode, generics: NimNode): NimNode =
        if generics.kind == nnkEmpty:
            return id
        generics.expectKind(nnkGenericParams)
        # id, @[T1: SomeInteger, T2: SomeFloat] -> id[T1, T2]
        nnkBracketExpr.newTree(id).add(
            generics.mapIt(
                block:
                    it.expectKind(nnkIdentDefs);
                    it[0]
            )
        )
    let
        kindId = ident(fmt"{name.strVal}Kind")
    result.add nnkProcDef.newTree(
        postfix(ident(fmt"new{name.strVal}"), "*"),
        newEmptyNode(),
        generics,
        nnkFormalParams.newTree(
            name.generalize(generics)
        ).add(fields),
        newEmptyNode(),
        newEmptyNode(),
        newStmtList(
            nnkObjConstr.newTree(
                name.generalize(generics),
            ).add fields.mapIt(
                newColonExpr(
                    it[0],
                    it[0]
                )
            )
        )
    )
    result.add kinds.mapIt(
        nnkProcDef.newTree(
            postfix(it[0], "*"),
            newEmptyNode(),
            generics,
            nnkFormalParams.newTree(
                name.generalize(generics),
                newIdentDefs(
                    ident":val",
                    name.generalize(generics)
                )
            ).add(
                case it[1]
                of Untagged:
                    it[2].enumerate.mapIt newIdentDefs(ident(fmt"a{it[0]}"), it[1])
                else:
                    it[2]
            ),
            newEmptyNode(),
            newEmptyNode(),
            newStmtList(
                newAssignment(ident"result", ident":val")
            ).add(
                case it[1]
                    of Tagged:
                        @[newAssignment(
                            ident"result".newDotExpr(ident(fmt"{it[0].strVal}Field")),
                            nnkObjConstr.newTree(
                                ident(fmt"{it[0].strVal}Impl").generalize(generics)
                            ).add(
                                it[2].mapIt(
                                    newColonExpr(it[0], it[0])
                                )
                            )
                        )]
                    of Untagged:
                        @[newAssignment(
                            ident"result".newDotExpr(ident(fmt"{it[0].strVal}Field")),
                            nnkTupleConstr.newTree(
                                it[2].enumerate.mapIt ident(fmt"a{it[0]}")
                            )
                        )]
                    of NoField:
                        @[]
            )
        )
    )
    result.add kinds.mapIt(
        nnkProcDef.newTree(
            postfix(it[0], "*"),
            newEmptyNode(),
            generics,
            nnkFormalParams.newTree(
                name.generalize(generics),
                newIdentDefs(
                    ident"_",
                    nnkBracketExpr.newTree(
                        ident"typedesc",
                        name.generalize(generics)
                    )
                )
            ).add(
                case it[1]
                of Untagged:
                    it[2].enumerate.mapIt newIdentDefs(ident(fmt"a{it[0]}"), it[1])
                else:
                    it[2]
            ),
            newEmptyNode(),
            newEmptyNode(),
            newStmtList(
                nnkObjConstr.newTree(
                    name.generalize(generics),
                    newColonExpr(
                        ident"kind",
                        newDotExpr(
                            kindId,
                            ident(it[0].strVal),
                        )
                    )
                ).add(
                    case it[1]
                    of Tagged:
                        @[newColonExpr(
                            ident(fmt"{it[0].strVal}Field"),
                            nnkObjConstr.newTree(
                                ident(fmt"{it[0].strVal}Impl").generalize(generics)
                            ).add(
                                it[2].mapIt(
                                    newColonExpr(it[0], it[0])
                                )
                            )
                        )]
                    of Untagged:
                        @[newColonExpr(
                            ident(fmt"{it[0].strVal}Field"),
                            nnkTupleConstr.newTree(
                                it[2].enumerate.mapIt ident(fmt"a{it[0]}")
                            )
                        )]
                    of NoField:
                        @[]
                )
            )
        )
    )

macro Algebraic*(name: untyped, body: untyped): untyped =
    var
        (name, generics) = scanName(name)
        (fields, kinds) = scanFields(body)
    result = newStmtList()
    result.add makeType(name, generics, fields, kinds)
    result.add makeConstructor(name, generics, fields, kinds)

macro error2(msg: static[string], n: untyped): untyped =
    ## macro version of `error` in macros
    ## This is useful for use in template
    error msg, n
macro hint2(msg: static[string], n: untyped): untyped =
    ## macro version of `hint` in macros
    ## This is useful for use in template
    hint msg, n
macro warning2(msg: static[string], n: untyped): untyped =
    ## macro version of `warning` in macros
    ## This is useful for use in template
    warning msg, n

template `==?`(a, b: untyped): untyped =
    when compiles(a.contains(b)):
        a.contains(b)
    elif compiles(a == b):
        a == b
    else:
        bind error2
        static:
            const
                s1 = $typeof(a)
                s2 = $typeof(b)
            error2(
                astToStr(a) & " is of type " & s1 & "\n" &  "selector is of type " & s2 & "\n" & "`==`(" & s1 & ", " & s2 & ") and `contains`(" & s1 & ", " & s2 & ") is not declared",
                a
            )
        false
    
template `:=`(a: untyped, b: typed): untyped =
    when declaredInScope(a):
        a = b
    else:
        let a = b
    true

template `:==`(a: untyped, b: typed): untyped =
    when declaredInScope(a):
        bind `==?`
        a ==? b
    else:
        bind `:=`
        a := b

template matchDiscardingPattern(selector: NimNode, pattern: NimNode, inductive: untyped): untyped =
    pattern.matchAst:
    # discarding the value
    # _
    of nnkIdent(strVal = "_"):
        return newBoolLitNode(true)
    # capturing or comparing to an already captured variable
    # name
    of `p`@nnkIdent:
        return infix(p, bindSym":==", selector)
    # captruing, never comparing
    # name@_
    of nnkInfix(ident"@", `id`@nnkIdent, nnkIdent(strVal = "_")):
        return infix(id, bindSym":=", selector)
    # mathing and capturing
    # name@pat
    of nnkInfix(ident"@", `id`@nnkIdent, `p`@_):
        return infix(inductive, "and", infix(id, bindSym":=", selector))
    of nnkPrefix(ident"!", `id`@nnkIdent):
        return infix(id, bindSym"==?", selector)
    else:
        discard

macro `?=`*(pattern: untyped, selector: AtomType|string): untyped =
    func impl(selector: NimNode, pattern: NimNode): NimNode =
        selector.matchDiscardingPattern(pattern, impl(selector, pattern))
        pattern.matchAst:
        # match with literals: strict pattern
        # such as 3, 'a' or "abc"
        of `p`@nnkLiterals:
            result = infix(p, bindSym"==?", selector)
        of `p`@nnkInfix(ident"..", `a`@_, `b`@_):
            result = newCall("contains", p, selector)
        else:
            error "invlid pattern", pattern
    selector.impl(pattern)

func scanTupleInfo(selector: NimNode): (NimNodeKind, int, seq[string]) =
    let a = selector.getTypeImpl
    if a.kind == nnkTupleTy:
        (a.kind, a.len, toSeq(a.children).mapIt(it[0].strVal))
    elif a.kind == nnkTupleConstr:
        (a.kind, a.len, @[])
    else:
        # TODO:
        raise newException(MatchError, "Unexpected Error")

proc mathcTupleConstr(selector: NimNode, pattern: NimNode, tupleLen: int): NimNode =
    selector.matchDiscardingPattern(pattern, mathcTupleConstr(selector, p, tupleLen))
    pattern.matchAst:
    # (pat0, pat1)
    of `p`@nnkPar:
        # TODO: use exactly match now
        #       support shorter pattern
        p.expectLen(tupleLen)
        result = toSeq(p.children).enumerate.mapIt(
            infix(it[1], "?=", selector.newIndex(it[0]))
        ).foldl(infix(a, "and", b))
    else:
        error "invalid pattern", pattern

func matchTupleField(selector: NimNode, pattern: NimNode, tupleFields: seq[string], usedFields: var seq[string]): NimNode =
    pattern.matchAst:
    of nnkExprColonExpr(`field`@nnkIdent, `p`@_):
        if field.strVal notin tupleFields:
            error "undeclared field: " & field.strVal & "notin " & $tupleFields, field
        if field.strVal in usedFields:
            error "this field has already appeared in patten: " & field.strVal, field
        # if (p.kind == nnkIdent and p.strVal == field.strVal):
        p.matchAst:
        of nnkIdent(strVal = field.strVal):
            hint &"You can simply use the pattern `{p.strVal}` instead of `{p.strVal}: {p.strVal}` if you don't want to compare it with an existing variable", pattern
        of nnkInfix(ident"@", `p`@nnkIdent(strVal = field.strVal), nnkIdent(strVal = "_")):
            hint &"You can simply use the pattern `{p.strVal}` instead of `{p.strVal}: {p.strVal}@_` if you don't want to compare it with an existing variable", pattern
        else:
            discard
        usedFields.add field.strVal
        result = infix(p, "?=", newDotExpr(selector, field))
    of `field`@nnkIdent:
        if field.strVal notin tupleFields:
            error(
                tupleFields.filterIt(it notin usedFields).mapIt(
                    &"You can use the pattern `{it}: subpattern` or `{it}`."
                ).join("\n") & &"\nundeclared field: {field.strVal}",
                field
            )
        if field.strVal in usedFields:
            error "this field has already appeared in patten: " & field.strVal, field
        usedFields.add field.strVal
        result = infix(field, bindSym":=", newDotExpr(selector, field))
    else:
        error(
                tupleFields.filterIt(it notin usedFields).mapIt(
                    &"You can use the pattern `{it}: subpattern` or `{it}`."
                ).join("\n"), pattern
            )
        error "invalid pattern", pattern

func matchTupleTy(selector: NimNode, pattern: NimNode, tupleFields: seq[string]): NimNode =
    selector.matchDiscardingPattern(pattern, matchTupleTy(selector, pattern, tupleFields))
    pattern.matchAst:
    of `p`@nnkPar:
        var usedFields: seq[string]
        result = toSeq(p.children).mapIt(
            selector.matchTupleField(it, tupleFields, usedFields)
        ).foldl(infix(a, "and", b))
    else:
        error "invalid pattern", pattern

macro `?=`*(pattern: untyped, selector: tuple): untyped =
    proc impl(selector: NimNode, pattern: NimNode): NimNode =
        let (tupleKind, tupleLen, tupleFields) = scanTupleInfo(selector)
        case tupleKind:
        # (val0, val1)
        of nnkTupleConstr:
            result = selector.mathcTupleConstr(pattern, tupleLen)
        # (tag0: val0, tag1: val1)
        of nnkTupleTy:
            result = selector.matchTupleTy(pattern, tupleFields)
        else:
            # TODO:
            error "unreachable", selector
    selector.impl(pattern)

proc getTypeImpl2*(n: NimNode): NimNode =
    result = n.getTypeInst
    result = if result.kind == nnkSym:
        result.getImpl
    else:
        result[0].getImpl
    while true:
        result.matchAst:
        of nnkTypeDef(nnkSym, nnkEmpty, `n`@nnkSym): # that is, alias
            result = n.getImpl
        of nnkTypeDef(nnkSym, nnkEmpty, nnkDistinctTy(`n`@nnkSym)):
            result = n.getImpl
        of nnkTypeDef(nnkSym, nnkEmpty, nnkRefTy(`n`@nnkSym)):
            result = n.getImpl
        else:
            return


    if n.kind == nnkSym: # either an variable or a proc
        let impl = n.getImpl()
        if impl.kind in RoutineNodes:
            return impl.pragma
        elif impl.kind == nnkIdentDefs and impl[0].kind == nnkPragmaExpr:
            return impl[0][1]
        else:
            typ.matchAst:
            of nnkSym:
                typ.getImpl.matchAst:
                of nnkTypeDef(nnkPragmaExpr(_, `p`@nnkPragma), {nnkGenericParams, nnkEmpty}, {nnkObjectTy, nnkTupleTy, nnkEnumTy}):
                    return p
                of nnkTypeDef(_, {nnkGenericParams, nnkEmpty}, {nnkObjectTy, nnkTupleTy, nnkEnumTy}):
                    return newEmptyNode()
            of nnkBracketExpr:
                typ[0].getImpl.matchAst:
                of nnkTypeDef(nnkPragmaExpr(_, `p`@nnkPragma), {nnkGenericParams, nnkEmpty}, {nnkObjectTy, nnkTupleTy, nnkEnumTy}):
                    return p
                of nnkTypeDef(_, {nnkGenericParams, nnkEmpty}, {nnkObjectTy, nnkTupleTy, nnkEnumTy}):
                    return newEmptyNode()
            else:
                discard

            # let timpl = typ.getImpl()
            # if timpl.len>0 and timpl[0].len>1:
            #     return timpl[0][1]
            # else:
            #     return timpl

    if n.kind in {nnkDotExpr, nnkCheckedFieldExpr}:
        let name = $(if n.kind == nnkCheckedFieldExpr: n[0][1] else: n[1])
        let typInst = getTypeInst(if n.kind == nnkCheckedFieldExpr or n[0].kind == nnkHiddenDeref: n[0][0] else: n[0])
        var typDef = getImpl(if typInst.kind == nnkVarTy: typInst[0] else: typInst)
        while typDef != nil:
            typDef.expectKind(nnkTypeDef)
            let typ = typDef[2]
            typ.expectKind({nnkRefTy, nnkPtrTy, nnkObjectTy})
            let isRef = typ.kind in {nnkRefTy, nnkPtrTy}
            if isRef and typ[0].kind in {nnkSym, nnkBracketExpr}: # defines ref type for another object(e.g. X = ref X)
                typDef = getImpl(typ[0])
            else: # object definition, maybe an object directly defined as a ref type
                let
                    obj = (if isRef: typ[0] else: typ)
                var identDefsStack = newSeq[NimNode](obj[2].len)
                for i in 0..<identDefsStack.len: identDefsStack[i] = obj[2][i]
                while identDefsStack.len > 0:
                    var identDefs = identDefsStack.pop()
                    if identDefs.kind == nnkRecCase:
                        identDefsStack.add(identDefs[0])
                        for i in 1..<identDefs.len:
                            let varNode = identDefs[i]
                            # if it is and empty branch, skip
                            if varNode[0].kind == nnkNilLit: continue
                            if varNode[1].kind == nnkIdentDefs:
                                identDefsStack.add(varNode[1])
                            else: # nnkRecList
                                for j in 0 ..< varNode[1].len:
                                    identDefsStack.add(varNode[1][j])

                    else:
                        for i in 0 .. identDefs.len - 3:
                            let varNode = identDefs[i]
                            if varNode.kind == nnkPragmaExpr:
                                var varName = varNode[0]
                                if varName.kind == nnkPostfix:
                                    # This is a public field. We are skipping the postfix *
                                    varName = varName[1]
                                if eqIdent($varName, name):
                                    return varNode[1]

                if obj[1].kind == nnkOfInherit: # explore the parent object
                    typDef = getImpl(obj[1][0])
                else:
                    typDef = nil


proc hasCustomPragma*(n: NimNode, pragma: NimNode): bool =
    # quoted from `macros` module
    n.expectKind({nnkSym, nnkDotExpr, nnkBracketExpr, nnkTypeOfExpr, nnkCheckedFieldExpr})
    pragma.expectKind({nnkSym})
    let pragmaNode = customPragmaNode(n)
    for p in pragmaNode:
        if (p.kind == nnkSym and p == pragma) or
                (p.kind in {nnkExprColonExpr, nnkCall, nnkCallStrLit} and p.len > 0 and p[0].kind == nnkSym and p[0] == pragma):
            return true
    return false

proc scanKinds(selector: NimNode): (seq[NimNode], seq[NimNode], seq[NimNode]) =
    let reclist = selector.getTypeImpl[2]
    for reccase in reclist:
        if reccase.kind != nnkRecCase:
            continue
        assert reccase.kind == nnkRecCase
        assert reccase[0].kind == nnkIdentDefs
        result[0] = reccase[0][1].getTypeImpl[1..^1] # `Kind`
        for e in reccase[1..^1]:
            if e.kind == nnkRecCase:
                continue
            assert e.kind == nnkOfBranch
            assert e[0].kind == nnkIntLit
            assert e[1].kind == nnkRecList
            if e[1].len == 0:
                result[1].add newEmptyNode()
                result[2].add newEmptyNode()
                continue
            assert e[1][0].kind == nnkIdentDefs
            result[1].add e[1][0][0] # `Kind`Field
            result[2].add e[1][0][1] # `Kind`Impl
    

proc matchVariantObject(selector: NimNode, pattern: NimNode): NimNode =
    assert selector.hasCustomPragma(bindSym"variant")
    let
        (kinds, kindFields, kindImpls) = selector.scanKinds()
    pattern.matchAst:
    of {nnkCall, nnkObjConstr} |= pattern[0].kind == nnkIdent:
        let
            id = pattern[0]
            i = kinds.mapIt(it.strVal).find(id.strVal)
            args = if pattern.len > 1: pattern[1..^1] else: @[]
        if i == -1:
            error "You can use one of " & $kinds.mapIt(it.strVal), pattern
        if kindFields[i].kind == nnkEmpty and kindImpls[i].kind == nnkEmpty:
            error &"It has no fields\nYou can simply use the pattern `{kinds[i].strVal}`", pattern
        return infix(infix(selector.newDotExpr(ident"kind"), "==", kinds[i]), "and", infix(nnkPar.newTree(args), "?=", selector.newDotExpr(kindFields[i])))
    of nnkIdent |= pattern.strVal in kinds.mapIt(it.strVal):
        let
            i = kinds.mapIt(it.strVal).find(pattern.strVal)
        if kindFields[i].kind != nnkEmpty and kindImpls[i].kind != nnkEmpty:
            error &"It has field(s)\nYou must use `{kinds[i].strVal}(subpatterns)`", pattern
        return infix(selector.newDotExpr(ident"kind"), "==", kinds[i])
    else:
        discard

    selector.matchDiscardingPattern(pattern, matchVariantObject(selector, pattern))
    error "invalid pattern", pattern

    

macro `?=`*(pattern: untyped, selector: object): untyped =
    proc impl(selector: NimNode, pattern: NimNode): NimNode =
        if selector.hasCustomPragma(bindSym"variant"):
            return selector.matchVariantObject(pattern)
        selector.matchDiscardingPattern(pattern, impl(selector, pattern))
        let fields = toSeq(selector.getTypeImpl[2].children).filterIt(it.kind==nnkIdentDefs).mapIt(it[0].strVal)
        selector.matchTupleTy(pattern, fields)
    selector.impl(pattern)

macro match*(n: varargs[untyped]): untyped =
    func impl(selector: NimNode, body: NimNode): NimNode =
        body.matchAst:
        # discarding the value
        # _
        of nnkOfBranch(nnkIdent(strVal = "_"), `body`@nnkStmtList):
            result = nnkElse.newTree(
                body
            )
        of nnkOfBranch(nnkInfix(nnkIdent(strVal="and"), `p`@_,  `cond`@_), `body`@nnkStmtList):
            result = nnkElifBranch.newTree(
                infix(infix(`p`, "?=", selector), "and", cond),
                body
            )
        # pattern mathing
        of nnkOfBranch(`p`@_, `body`@nnkStmtList):
            result = nnkElifBranch.newTree(
                infix(`p`, "?=", selector),
                body
            )
        # else branch
        of nnkElse(`body`@nnkStmtList):
            hint "You can use wildcard `_` instead of `else` branch", body
            result = nnkElse.newTree(
                body
            )
        else:
            error "invalid branch", body
    func ifVerify(ifStmt: NimNode): NimNode =
        if ifStmt.len == 1 and ifStmt[0].kind == nnkElse:
            let s = ifStmt[0][0]
            ifStmt[0] = nnkElifBranch.newTree(
                newBoolLitNode(true),
                s
            )
        ifStmt
    let
        selector = n[0]
        body = n[1..^1]
    newBlockStmt(
        ident(":match"),
        newStmtList(
            newLetStmt(
                ident":selector",
                selector
            ),
            nnkIfStmt.newTree(
                body.mapIt(
                    ident":selector".impl(it)
                )
            ).addElse(
                # TODO: check wheathre patterns are exhaustive or not
                nnkElse.newTree(newStmtList(
                    block:
                        let
                            err = bindSym"MatchError"
                        quote do:
                            raise newException(typeof `err`, "No match. (This behavior is adhoc implementation.)")
                ))
            ).ifVerify()
        )
    )

template optAnd*{true and a}(a: bool): bool = a
template optAnd*{a and true}(a: bool): bool = a
template optAnd*{false and a}(a: bool{noSideEffect}): bool = false
template optAnd*{a and false}(a: bool{noSideEffect}): bool = false
template optOr*{true or a}(a: bool{noSideEffect}): bool = true
template optOr*{a or true}(a: bool{noSideEffect}): bool = true
template otpOr*{false or a}(a: bool): bool = a
template otpOr*{a or false}(a: bool): bool = a


{.experimental: "caseStmtMacros".}
