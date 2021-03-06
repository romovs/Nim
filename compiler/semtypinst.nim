#
#
#           The Nim Compiler
#        (c) Copyright 2015 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

# This module does the instantiation of generic types.

import ast, astalgo, msgs, types, magicsys, semdata, renderer, options

const
  tfInstClearedFlags = {tfHasMeta, tfUnresolved}

proc checkPartialConstructedType(info: TLineInfo, t: PType) =
  if tfAcyclic in t.flags and skipTypes(t, abstractInst).kind != tyObject:
    localError(info, errInvalidPragmaX, "acyclic")
  elif t.kind in {tyVar, tyLent} and t.sons[0].kind in {tyVar, tyLent}:
    localError(info, errVarVarTypeNotAllowed)

proc checkConstructedType*(info: TLineInfo, typ: PType) =
  var t = typ.skipTypes({tyDistinct})
  if t.kind in tyTypeClasses: discard
  elif tfAcyclic in t.flags and skipTypes(t, abstractInst).kind != tyObject:
    localError(info, errInvalidPragmaX, "acyclic")
  elif t.kind in {tyVar, tyLent} and t.sons[0].kind in {tyVar, tyLent}:
    localError(info, errVarVarTypeNotAllowed)
  elif computeSize(t) == szIllegalRecursion:
    localError(info, errIllegalRecursionInTypeX, typeToString(t))
  when false:
    if t.kind == tyObject and t.sons[0] != nil:
      if t.sons[0].kind != tyObject or tfFinal in t.sons[0].flags:
        localError(info, errInheritanceOnlyWithNonFinalObjects)

proc searchInstTypes*(key: PType): PType =
  let genericTyp = key.sons[0]
  internalAssert genericTyp.kind == tyGenericBody and
                 key.sons[0] == genericTyp and
                 genericTyp.sym != nil

  if genericTyp.sym.typeInstCache == nil:
    return

  for inst in genericTyp.sym.typeInstCache:
    if inst.id == key.id: return inst
    if inst.sons.len < key.sons.len:
      # XXX: This happens for prematurely cached
      # types such as Channel[empty]. Why?
      # See the notes for PActor in handleGenericInvocation
      return
    if not sameFlags(inst, key):
      continue

    block matchType:
      for j in 1 .. high(key.sons):
        # XXX sameType is not really correct for nested generics?
        if not compareTypes(inst.sons[j], key.sons[j],
                            flags = {ExactGenericParams}):
          break matchType

      return inst

proc cacheTypeInst*(inst: PType) =
  # XXX: add to module's generics
  #      update the refcount
  let gt = inst.sons[0]
  let t = if gt.kind == tyGenericBody: gt.lastSon else: gt
  if t.kind in {tyStatic, tyGenericParam} + tyTypeClasses:
    return
  gt.sym.typeInstCache.safeAdd(inst)


type
  LayeredIdTable* = object
    topLayer*: TIdTable
    nextLayer*: ptr LayeredIdTable

  TReplTypeVars* = object
    c*: PContext
    typeMap*: ptr LayeredIdTable # map PType to PType
    symMap*: TIdTable         # map PSym to PSym
    localCache*: TIdTable     # local cache for remembering alraedy replaced
                              # types during instantiation of meta types
                              # (they are not stored in the global cache)
    info*: TLineInfo
    allowMetaTypes*: bool     # allow types such as seq[Number]
                              # i.e. the result contains unresolved generics
    skipTypedesc*: bool       # wether we should skip typeDescs
    owner*: PSym              # where this instantiation comes from
    recursionLimit: int

proc replaceTypeVarsTAux(cl: var TReplTypeVars, t: PType): PType
proc replaceTypeVarsS(cl: var TReplTypeVars, s: PSym): PSym
proc replaceTypeVarsN*(cl: var TReplTypeVars, n: PNode; start=0): PNode

proc initLayeredTypeMap*(pt: TIdTable): LayeredIdTable =
  copyIdTable(result.topLayer, pt)

proc newTypeMapLayer*(cl: var TReplTypeVars): LayeredIdTable =
  result.nextLayer = cl.typeMap
  initIdTable(result.topLayer)

proc lookup(typeMap: ptr LayeredIdTable, key: PType): PType =
  var tm = typeMap
  while tm != nil:
    result = PType(idTableGet(tm.topLayer, key))
    if result != nil: return
    tm = tm.nextLayer

template put(typeMap: ptr LayeredIdTable, key, value: PType) =
  idTablePut(typeMap.topLayer, key, value)

template checkMetaInvariants(cl: TReplTypeVars, t: PType) =
  when false:
    if t != nil and tfHasMeta in t.flags and
       cl.allowMetaTypes == false:
      echo "UNEXPECTED META ", t.id, " ", instantiationInfo(-1)
      debug t
      writeStackTrace()

proc replaceTypeVarsT*(cl: var TReplTypeVars, t: PType): PType =
  result = replaceTypeVarsTAux(cl, t)
  checkMetaInvariants(cl, result)

proc prepareNode(cl: var TReplTypeVars, n: PNode): PNode =
  let t = replaceTypeVarsT(cl, n.typ)
  if t != nil and t.kind == tyStatic and t.n != nil:
    return if tfUnresolved in t.flags: prepareNode(cl, t.n)
           else: t.n
  result = copyNode(n)
  result.typ = t
  if result.kind == nkSym: result.sym = replaceTypeVarsS(cl, n.sym)
  let isCall = result.kind in nkCallKinds
  for i in 0 ..< n.safeLen:
    # XXX HACK: ``f(a, b)``, avoid to instantiate `f`
    if isCall and i == 0: result.add(n[i])
    else: result.add(prepareNode(cl, n[i]))

proc isTypeParam(n: PNode): bool =
  # XXX: generic params should use skGenericParam instead of skType
  return n.kind == nkSym and
         (n.sym.kind == skGenericParam or
           (n.sym.kind == skType and sfFromGeneric in n.sym.flags))

proc hasGenericArguments*(n: PNode): bool =
  if n.kind == nkSym:
    return n.sym.kind == skGenericParam or
           tfInferrableStatic in n.sym.typ.flags or
           (n.sym.kind == skType and
            n.sym.typ.flags * {tfGenericTypeParam, tfImplicitTypeParam} != {})
  else:
    for i in 0..<n.safeLen:
      if hasGenericArguments(n.sons[i]): return true
    return false

proc reResolveCallsWithTypedescParams(cl: var TReplTypeVars, n: PNode): PNode =
  # This is needed for tgenericshardcases
  # It's possible that a generic param will be used in a proc call to a
  # typedesc accepting proc. After generic param substitution, such procs
  # should be optionally instantiated with the correct type. In order to
  # perform this instantiation, we need to re-run the generateInstance path
  # in the compiler, but it's quite complicated to do so at the moment so we
  # resort to a mild hack; the head symbol of the call is temporary reset and
  # overload resolution is executed again (which may trigger generateInstance).
  if n.kind in nkCallKinds and sfFromGeneric in n[0].sym.flags:
    var needsFixing = false
    for i in 1 ..< n.safeLen:
      if isTypeParam(n[i]): needsFixing = true
    if needsFixing:
      n.sons[0] = newSymNode(n.sons[0].sym.owner)
      return cl.c.semOverloadedCall(cl.c, n, n, {skProc, skFunc}, {})

  for i in 0 ..< n.safeLen:
    n.sons[i] = reResolveCallsWithTypedescParams(cl, n[i])

  return n

proc replaceTypeVarsN(cl: var TReplTypeVars, n: PNode; start=0): PNode =
  if n == nil: return
  result = copyNode(n)
  if n.typ != nil:
    result.typ = replaceTypeVarsT(cl, n.typ)
    checkMetaInvariants(cl, result.typ)
  case n.kind
  of nkNone..pred(nkSym), succ(nkSym)..nkNilLit:
    discard
  of nkSym:
    result.sym = replaceTypeVarsS(cl, n.sym)
    if result.sym.typ.kind == tyVoid:
      # don't add the 'void' field
      result = newNode(nkRecList, n.info)
  of nkRecWhen:
    var branch: PNode = nil              # the branch to take
    for i in countup(0, sonsLen(n) - 1):
      var it = n.sons[i]
      if it == nil: illFormedAst(n)
      case it.kind
      of nkElifBranch:
        checkSonsLen(it, 2)
        var cond = prepareNode(cl, it.sons[0])
        var e = cl.c.semConstExpr(cl.c, cond)
        if e.kind != nkIntLit:
          internalError(e.info, "ReplaceTypeVarsN: when condition not a bool")
        if e.intVal != 0 and branch == nil: branch = it.sons[1]
      of nkElse:
        checkSonsLen(it, 1)
        if branch == nil: branch = it.sons[0]
      else: illFormedAst(n)
    if branch != nil:
      result = replaceTypeVarsN(cl, branch)
    else:
      result = newNodeI(nkRecList, n.info)
  of nkStaticExpr:
    var n = prepareNode(cl, n)
    n = reResolveCallsWithTypedescParams(cl, n)
    result = if cl.allowMetaTypes: n
             else: cl.c.semExpr(cl.c, n)
  else:
    var length = sonsLen(n)
    if length > 0:
      newSons(result, length)
      if start > 0:
        result.sons[0] = n.sons[0]
      for i in countup(start, length - 1):
        result.sons[i] = replaceTypeVarsN(cl, n.sons[i])

proc replaceTypeVarsS(cl: var TReplTypeVars, s: PSym): PSym =
  if s == nil: return nil
  # symbol is not our business:
  if cl.owner != nil and s.owner != cl.owner:
    return s
  #result = PSym(idTableGet(cl.symMap, s))
  #if result == nil:
  result = copySym(s, false)
  incl(result.flags, sfFromGeneric)
  #idTablePut(cl.symMap, s, result)
  result.owner = s.owner
  result.typ = replaceTypeVarsT(cl, s.typ)
  result.ast = replaceTypeVarsN(cl, s.ast)

proc lookupTypeVar(cl: var TReplTypeVars, t: PType): PType =
  result = cl.typeMap.lookup(t)
  if result == nil:
    if cl.allowMetaTypes or tfRetType in t.flags: return
    localError(t.sym.info, errCannotInstantiateX, typeToString(t))
    result = errorType(cl.c)
    # In order to prevent endless recursions, we must remember
    # this bad lookup and replace it with errorType everywhere.
    # These code paths are only active in "nim check"
    cl.typeMap.put(t, result)
  elif result.kind == tyGenericParam and not cl.allowMetaTypes:
    internalError(cl.info, "substitution with generic parameter")

proc instCopyType*(cl: var TReplTypeVars, t: PType): PType =
  # XXX: relying on allowMetaTypes is a kludge
  result = copyType(t, t.owner, cl.allowMetaTypes)
  if cl.allowMetaTypes: return
  result.flags.incl tfFromGeneric
  if not (t.kind in tyMetaTypes or
         (t.kind == tyStatic and t.n == nil)):
    result.flags.excl tfInstClearedFlags
  when false:
    if newDestructors:
      result.assignment = nil
      #result.destructor = nil
      result.sink = nil

template typeBound(c, newty, oldty, field, info) =
  let opr = newty.field
  if opr != nil and sfFromGeneric notin opr.flags:
    # '=' needs to be instantiated for generics when the type is constructed:
    newty.field = c.instTypeBoundOp(c, opr, oldty, info, attachedAsgn, 1)

proc handleGenericInvocation(cl: var TReplTypeVars, t: PType): PType =
  # tyGenericInvocation[A, tyGenericInvocation[A, B]]
  # is difficult to handle:
  const eqFlags = eqTypeFlags + {tfGcSafe}
  var body = t.sons[0]
  if body.kind != tyGenericBody: internalError(cl.info, "no generic body")
  var header: PType = t
  # search for some instantiation here:
  if cl.allowMetaTypes:
    result = PType(idTableGet(cl.localCache, t))
  else:
    result = searchInstTypes(t)

  if result != nil and eqFlags*result.flags == eqFlags*t.flags: return
  for i in countup(1, sonsLen(t) - 1):
    var x = t.sons[i]
    if x.kind in {tyGenericParam}:
      x = lookupTypeVar(cl, x)
      if x != nil:
        if header == t: header = instCopyType(cl, t)
        header.sons[i] = x
        propagateToOwner(header, x)
    else:
      propagateToOwner(header, x)

  if header != t:
    # search again after first pass:
    result = searchInstTypes(header)
    if result != nil and eqFlags*result.flags == eqFlags*t.flags: return
  else:
    header = instCopyType(cl, t)

  result = newType(tyGenericInst, t.sons[0].owner)
  result.flags = header.flags
  # be careful not to propagate unnecessary flags here (don't use rawAddSon)
  result.sons = @[header.sons[0]]
  # ugh need another pass for deeply recursive generic types (e.g. PActor)
  # we need to add the candidate here, before it's fully instantiated for
  # recursive instantions:
  if not cl.allowMetaTypes:
    cacheTypeInst(result)
  else:
    idTablePut(cl.localCache, t, result)

  let oldSkipTypedesc = cl.skipTypedesc
  cl.skipTypedesc = true

  var typeMapLayer = newTypeMapLayer(cl)
  cl.typeMap = addr(typeMapLayer)

  for i in countup(1, sonsLen(t) - 1):
    var x = replaceTypeVarsT(cl, t.sons[i])
    assert x.kind != tyGenericInvocation
    header.sons[i] = x
    propagateToOwner(header, x)
    cl.typeMap.put(body.sons[i-1], x)

  for i in countup(1, sonsLen(t) - 1):
    # if one of the params is not concrete, we cannot do anything
    # but we already raised an error!
    rawAddSon(result, header.sons[i])

  let bbody = lastSon body
  var newbody = replaceTypeVarsT(cl, bbody)
  let bodyIsNew = newbody != bbody
  cl.skipTypedesc = oldSkipTypedesc
  newbody.flags = newbody.flags + (t.flags + body.flags - tfInstClearedFlags)
  result.flags = result.flags + newbody.flags - tfInstClearedFlags

  cl.typeMap = cl.typeMap.nextLayer

  # This is actually wrong: tgeneric_closure fails with this line:
  #newbody.callConv = body.callConv
  # This type may be a generic alias and we want to resolve it here.
  # One step is enough, because the recursive nature of
  # handleGenericInvocation will handle the alias-to-alias-to-alias case
  if newbody.isGenericAlias: newbody = newbody.skipGenericAlias
  rawAddSon(result, newbody)
  checkPartialConstructedType(cl.info, newbody)
  let dc = newbody.deepCopy
  if cl.allowMetaTypes == false:
    if dc != nil and sfFromGeneric notin newbody.deepCopy.flags:
      # 'deepCopy' needs to be instantiated for
      # generics *when the type is constructed*:
      newbody.deepCopy = cl.c.instTypeBoundOp(cl.c, dc, result, cl.info,
                                              attachedDeepCopy, 1)
    if bodyIsNew and newbody.typeInst == nil:
      #doassert newbody.typeInst == nil
      newbody.typeInst = result
      if tfRefsAnonObj in newbody.flags and newbody.kind != tyGenericInst:
        # can come here for tyGenericInst too, see tests/metatype/ttypeor.nim
        # need to look into this issue later
        assert newbody.kind in {tyRef, tyPtr}
        assert newbody.lastSon.typeInst == nil
        newbody.lastSon.typeInst = result
    if newDestructors:
      cl.c.typesWithOps.add((newbody, result))
    else:
      typeBound(cl.c, newbody, result, assignment, cl.info)
    let methods = skipTypes(bbody, abstractPtrs).methods
    for col, meth in items(methods):
      # we instantiate the known methods belonging to that type, this causes
      # them to be registered and that's enough, so we 'discard' the result.
      discard cl.c.instTypeBoundOp(cl.c, meth, result, cl.info,
        attachedAsgn, col)

proc eraseVoidParams*(t: PType) =
  # transform '(): void' into '()' because old parts of the compiler really
  # don't deal with '(): void':
  if t.sons[0] != nil and t.sons[0].kind == tyVoid:
    t.sons[0] = nil

  for i in 1 ..< t.sonsLen:
    # don't touch any memory unless necessary
    if t.sons[i].kind == tyVoid:
      var pos = i
      for j in i+1 ..< t.sonsLen:
        if t.sons[j].kind != tyVoid:
          t.sons[pos] = t.sons[j]
          t.n.sons[pos] = t.n.sons[j]
          inc pos
      setLen t.sons, pos
      setLen t.n.sons, pos
      return

proc skipIntLiteralParams*(t: PType) =
  for i in 0 ..< t.sonsLen:
    let p = t.sons[i]
    if p == nil: continue
    let skipped = p.skipIntLit
    if skipped != p:
      t.sons[i] = skipped
      if i > 0: t.n.sons[i].sym.typ = skipped

  # when the typeof operator is used on a static input
  # param, the results gets infected with static as well:
  if t.sons[0] != nil and t.sons[0].kind == tyStatic:
    t.sons[0] = t.sons[0].base

proc propagateFieldFlags(t: PType, n: PNode) =
  # This is meant for objects and tuples
  # The type must be fully instantiated!
  if n.isNil:
    return
  internalAssert n.kind != nkRecWhen
  case n.kind
  of nkSym:
    propagateToOwner(t, n.sym.typ)
  of nkRecList, nkRecCase, nkOfBranch, nkElse:
    for son in n:
      propagateFieldFlags(t, son)
  else: discard

proc replaceTypeVarsTAux(cl: var TReplTypeVars, t: PType): PType =
  template bailout =
    if cl.recursionLimit > 100:
      # bail out, see bug #2509. But note this caching is in general wrong,
      # look at this example where TwoVectors should not share the generic
      # instantiations (bug #3112):

      # type
      #   Vector[N: static[int]] = array[N, float64]
      #   TwoVectors[Na, Nb: static[int]] = (Vector[Na], Vector[Nb])
      result = PType(idTableGet(cl.localCache, t))
      if result != nil: return result
    inc cl.recursionLimit

  result = t
  if t == nil: return

  if t.kind in {tyStatic, tyGenericParam} + tyTypeClasses:
    let lookup = cl.typeMap.lookup(t)
    if lookup != nil: return lookup

  case t.kind
  of tyGenericInvocation:
    result = handleGenericInvocation(cl, t)
    if result.lastSon.kind == tyUserTypeClass:
      result.kind = tyUserTypeClassInst

  of tyGenericBody:
    localError(cl.info, errCannotInstantiateX, typeToString(t))
    result = errorType(cl.c)
    #result = replaceTypeVarsT(cl, lastSon(t))

  of tyFromExpr:
    if cl.allowMetaTypes: return
    # This assert is triggered when a tyFromExpr was created in a cyclic
    # way. You should break the cycle at the point of creation by introducing
    # a call such as: `n.typ = makeTypeFromExpr(c, n.copyTree)`
    # Otherwise, the cycle will be fatal for the prepareNode call below
    assert t.n.typ != t
    var n = prepareNode(cl, t.n)
    if n.kind != nkEmpty:
      n = cl.c.semConstExpr(cl.c, n)
    if n.typ.kind == tyTypeDesc:
      # XXX: sometimes, chained typedescs enter here.
      # It may be worth investigating why this is happening,
      # because it may cause other bugs elsewhere.
      result = n.typ.skipTypes({tyTypeDesc})
      # result = n.typ.base
    else:
      if n.typ.kind != tyStatic:
        # XXX: In the future, semConstExpr should
        # return tyStatic values to let anyone make
        # use of this knowledge. The patching here
        # won't be necessary then.
        result = newTypeS(tyStatic, cl.c)
        result.sons = @[n.typ]
        result.n = n
      else:
        result = n.typ

  of tyInt, tyFloat:
    result = skipIntLit(t)

  of tyTypeDesc:
    let lookup = cl.typeMap.lookup(t)
    if lookup != nil:
      result = lookup
      if tfUnresolved in t.flags or cl.skipTypedesc: result = result.base
    elif t.sons[0].kind != tyNone:
      result = makeTypeDesc(cl.c, replaceTypeVarsT(cl, t.sons[0]))

  of tyUserTypeClass, tyStatic:
    result = t

  of tyGenericInst, tyUserTypeClassInst:
    bailout()
    result = instCopyType(cl, t)
    idTablePut(cl.localCache, t, result)
    for i in 1 ..< result.sonsLen:
      result.sons[i] = replaceTypeVarsT(cl, result.sons[i])
    propagateToOwner(result, result.lastSon)

  else:
    if containsGenericType(t):
      #if not cl.allowMetaTypes:
      bailout()
      result = instCopyType(cl, t)
      result.size = -1 # needs to be recomputed
      #if not cl.allowMetaTypes:
      idTablePut(cl.localCache, t, result)

      for i in countup(0, sonsLen(result) - 1):
        if result.sons[i] != nil:
          var r = replaceTypeVarsT(cl, result.sons[i])
          if result.kind == tyObject:
            # carefully coded to not skip the precious tyGenericInst:
            let r2 = r.skipTypes({tyAlias, tySink})
            if r2.kind in {tyPtr, tyRef}:
              r = skipTypes(r2, {tyPtr, tyRef})
          result.sons[i] = r
          if result.kind != tyArray or i != 0:
            propagateToOwner(result, r)
      # bug #4677: Do not instantiate effect lists
      result.n = replaceTypeVarsN(cl, result.n, ord(result.kind==tyProc))
      case result.kind
      of tyArray:
        let idx = result.sons[0]
        internalAssert idx.kind != tyStatic

      of tyObject, tyTuple:
        propagateFieldFlags(result, result.n)

      of tyProc:
        eraseVoidParams(result)
        skipIntLiteralParams(result)

      else: discard

proc instAllTypeBoundOp*(c: PContext, info: TLineInfo) =
  if not newDestructors: return
  var i = 0
  while i < c.typesWithOps.len:
    let (newty, oldty) = c.typesWithOps[i]
    typeBound(c, newty, oldty, destructor, info)
    typeBound(c, newty, oldty, sink, info)
    typeBound(c, newty, oldty, assignment, info)
    inc i
  setLen(c.typesWithOps, 0)

proc initTypeVars*(p: PContext, typeMap: ptr LayeredIdTable, info: TLineInfo;
                   owner: PSym): TReplTypeVars =
  initIdTable(result.symMap)
  initIdTable(result.localCache)
  result.typeMap = typeMap
  result.info = info
  result.c = p
  result.owner = owner

proc replaceTypesInBody*(p: PContext, pt: TIdTable, n: PNode;
                         owner: PSym, allowMetaTypes = false): PNode =
  var typeMap = initLayeredTypeMap(pt)
  var cl = initTypeVars(p, addr(typeMap), n.info, owner)
  cl.allowMetaTypes = allowMetaTypes
  pushInfoContext(n.info)
  result = replaceTypeVarsN(cl, n)
  popInfoContext()

proc replaceTypesForLambda*(p: PContext, pt: TIdTable, n: PNode;
                            original, new: PSym): PNode =
  var typeMap = initLayeredTypeMap(pt)
  var cl = initTypeVars(p, addr(typeMap), n.info, original)
  idTablePut(cl.symMap, original, new)
  pushInfoContext(n.info)
  result = replaceTypeVarsN(cl, n)
  popInfoContext()

proc generateTypeInstance*(p: PContext, pt: TIdTable, info: TLineInfo,
                           t: PType): PType =
  var typeMap = initLayeredTypeMap(pt)
  var cl = initTypeVars(p, addr(typeMap), info, nil)
  pushInfoContext(info)
  result = replaceTypeVarsT(cl, t)
  popInfoContext()

proc prepareMetatypeForSigmatch*(p: PContext, pt: TIdTable, info: TLineInfo,
                                 t: PType): PType =
  var typeMap = initLayeredTypeMap(pt)
  var cl = initTypeVars(p, addr(typeMap), info, nil)
  cl.allowMetaTypes = true
  pushInfoContext(info)
  result = replaceTypeVarsT(cl, t)
  popInfoContext()

template generateTypeInstance*(p: PContext, pt: TIdTable, arg: PNode,
                               t: PType): untyped =
  generateTypeInstance(p, pt, arg.info, t)

