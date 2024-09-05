# Stdlib
import std/[
  tables, # Used to make a map of packets to their IDs.
  json    # Used for JSON objects, TODO: Use Jsony or Sunny instead.
]
# MC-related networking
import modernnet

type
  # Client states
  ConnectionState* = enum
    InitialConnection, Status, Login, Configuration, Playing

  # Aliases
  SizedOrdinal* = (VarLen[int32 | int64] | SomeInteger) and not(int | uint)

  # Distinct types
  VarLen*[R: int32 | int64] = distinct R
  VarEnum*[E: enum] = distinct E
  CappedString*[N: static range[0..high(int32).int]] = distinct string

  # Packet definitions
  Packet* = object of RootObj


proc `$`*(s: VarLen): string = $s.R(s)
proc `$`*(s: VarEnum): string = $s.E(s)
proc `$`*(s: CappedString): string = string(s)

proc unwrap*(s: VarLen): VarLen.R = VarLen.R(s)
proc unwrap*(s: VarEnum): VarEnum.E = VarEnum.E(s)
proc unwrap*(s: CappedString): CappedString.N = CappedString.N(s)

proc varLen*(val: int32 | int64): VarLen[typeof(val)] = VarLen(val)
proc varLen*(val: enum): VarEnum[typeof(val)] =
  when sizeof(val) notin [4, 8]: {.error: "Variable length enums must either be 32 or 64 bits in size!".} else: VarEnum(val)
proc cappedString*(val: string, length: static range[0..high(int32).int] = 23767): CappedString[length] =
  if val.len > length: raise newException(ValueError, "The given string is bigger than `" & $length & "`!")
  CappedString(val)


export buffer