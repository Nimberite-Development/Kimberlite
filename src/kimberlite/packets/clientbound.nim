import std/json # Used for serverlist JSON

import ./primitives

type
  ClientboundPacket* = object of Packet

  ClientboundStatusResponse* {.packetId(0x00).} = object of ClientboundPacket
    response*: JsonNode

  ClientboundPingResponse* {.packetId(0x01).} = object of ClientboundPacket
    nonce*: int64


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