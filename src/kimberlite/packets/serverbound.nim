import std/[
  tables,
  macros
]

import ./primitives

type
  Empty*[T] = object

  ConnectionState* = enum
    InitialConnection, Status, Login, Configuration, Playing

var ServerboundPacketHandler* {.compileTime.} = newStmtList()

macro registerPacket(id: static range[0..high(int32).int], state: static ConnectionState, body: untyped) =
  ## Registers a packet with its ID.
  result = body.copyNimTree()
  result[0] = result[0][0]
  assert result[0].kind == nnkPostfix
  assert result[0][1].kind == nnkIdent

  var stateNode = ServerboundPacketHandler.findChild(it.len > 0 and it[0] == newLit(state))
  if stateNode == nil:
    stateNode = newStmtList(newLit(state))
    ServerboundPacketHandler.add stateNode

  if stateNode.findChild(it.len > 0 and it[0] == newLit(id)) != nil:
    error("Packet with state `" & $state & "` and ID " & $id & " already exists!", result[0])

  stateNode.add newStmtList(newLit(id), result[0][1])

  echo ServerboundPacketHandler.treeRepr


macro handlePacket*(state: ConnectionState, id: range[0..high(int32).int],
  client, server, packet: untyped{nkIdent}) =
  ## Returns the packet with the given state and ID.
  result = newNimNode(nnkCaseStmt).add(state)

  for stateNode in ServerboundPacketHandler.children:
    # Iterate over the state-handler node pairs.
    let ofBrnch = newNimNode(nnkOfBranch).add(stateNode[0])
    result.add ofBrnch

    let handlerCase = newNimNode(nnkCaseStmt).add(id)
    ofBrnch.add handlerCase

    for handlerNode in stateNode.children:
      # Skip the first node which is the state.
      if handlerNode.kind == nnkCall: continue
      # Make another case statement for handling packet IDs.
      let typ = handlerNode[1]
      handlerCase.add(newNimNode(nnkOfBranch).add(handlerNode[0], (quote do:
        Empty[`typ`]().execute(`client`, `server`, `packet`))))

    handlerCase.add newNimNode(nnkElse).add(quote do:
      Empty[ServerboundUnimplementedPacket]().execute(`client`, `server`, `packet`))

  result.add newNimNode(nnkElse).add(quote do:
    `client`.close()
    echo "Unimplemented behaviour for state `" ,`state`, "` and ID ", `id`, "!"
  )
  echo result.treeRepr
  echo result.repr

type
  ServerboundPacket* = object of Packet

  NextState* {.size(4).}= enum
    nsStatus = 1, nsLogin, nsTransfer

  ServerboundUnimplementedPacket* = object of ServerboundPacket

  ServerboundHandshake* {.registerPacket(0x00, InitialConnection).} = object of ServerboundPacket
    ## ServerboundHandshake packet for MC 1.21.1
    ## https://wiki.vg/index.php?title=Protocol&oldid=19478#Handshake
    version*: VarLen[int32]
    address*: CappedString[255]
    port*: uint16
    nextState*: VarEnum[NextState]

  ServerboundStatusRequest* {.registerPacket(0x00, Status).} = object of ServerboundPacket

  ServerboundPingRequest* {.registerPacket(0x01, Status).} = object of ServerboundPacket
    nonce*: int64


proc readImpl(buf: Buffer, T: typedesc[CappedString]): T =
  ## Reads a string up to the given length and writes it to the `field`.
  T(buf.readString(T.N))

proc readImpl(buf: Buffer, T: typedesc[VarLen]): T =
  ## Reads a variable length integer and writes it to the `field`.
  T(buf.readVar[:T.R]())

proc readImpl(buf: Buffer, T: typedesc[VarEnum]): T =
  ## Reads a variable length enum and writes it to the `field`.
  when sizeof(T.E) notin [4, 8]: {.error: "Variable length enums must either be 32 or 64 bits in size!".}
  type Impl = (when sizeof(T.E) == 4: int32 else: int64)
  T(buf.readVar[:Impl]())

proc readImpl(buf: Buffer, T: typedesc[SizedOrdinal]): T =
  ## Reads a boolean or number type from the buffer and writes it to the `field`.
  buf.readNum[:T]()


proc read*[T: ServerboundPacket](_: typedesc[T], buf: Buffer): T =
  ## Generic read proc for reading a serverbound packet from a buffer.
  mixin readImpl

  for _, field in result.fieldPairs:
    when compiles(buf.readImpl(typeof(field))):
      field = buf.readImpl(typeof(field))
    else:
      {.error: "Unimplemented parsing for type `" & $typeof(field) & "`.".}