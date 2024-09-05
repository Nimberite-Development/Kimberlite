import std/[
  macros,
  json
]

import ./primitives

template registerPacket(id: range[0..high(int32).int], state: ConnectionState) {.pragma.}

type
  ClientboundPacket* = object of Packet

  ClientboundStatusResponse* {.registerPacket(0x00, Status).} = object of ClientboundPacket
    serverlist*: JsonNode

  ClientboundPingResponse* {.registerPacket(0x01, Status).} = object of ClientboundPacket
    nonce*: int64

  ClientboundDisconnectLogin* {.registerPacket(0x00, Login).} = object of ClientboundPacket
    reason*: JsonNode

proc id*[T: Packet](_: T | typedesc[T]): int32 = getCustomPragmaVal(T, registerPacket).id.int32
proc state*[T: Packet](_: T | typedesc[T]): ConnectionState = getCustomPragmaVal(T, registerPacket).state

proc writeImpl(buf: Buffer, val: CappedString) =
  ## Writes a string up to the given length to the buffer.
  if val.unwrap.len > val.N: raise newException(ValueError, "The given string is bigger than `" & $val.N & "`!")
  buf.writeString(val.unwrap)

proc writeImpl(buf: Buffer, val: VarLen) =
  ## Writes a variable length integer to the buffer.
  buf.writeVar(val.unwrap)

proc writeImpl(buf: Buffer, val: VarEnum) =
  ## Writes a variable length enum to the buffer.
  when sizeof(val.E) notin [4, 8]: {.error: "Variable length enums must either be 32 or 64 bits in size!".}
  type Impl = (when sizeof(val.E) == 4: int32 else: int64)
  buf.writeVar(Impl(val.unwrap))

proc writeImpl(buf: Buffer, val: (bool | SomeNumber) and not (int | uint | float)) =
  ## Writes a boolean or number type from the buffer to the buffer.
  buf.writeNum(val)

proc writeImpl(buf: Buffer, val: JsonNode) =
  ## Writes a JSON type from the buffer to the buffer.
  buf.writeString($val)


proc write*[T: ClientboundPacket](buf: Buffer, val: T) =
  ## Generic write proc for writing a clientbound packet to a buffer.
  mixin writeImpl

  for _, field in val.fieldPairs:
    when compiles(buf.writeImpl(field)):
      buf.writeImpl(field)
    else:
      {.error: "Unimplemented writing for type `" & $typeof(field) & "`.".}