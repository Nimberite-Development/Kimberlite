# Standard library
import std/[
  strformat,
  strutils,
  options, # Self-explanatory
  tables,  # Used primarily for storing clients in a table so that they can be referenced easily.
  json
]
# Continuation Passing Style stuff
import cps
# The IO queue
import sys/ioqueue
# Networking
import sys/sockets
import sys/sockets/addresses
# MC-related networking
import modernnet
import modernnet/helpers
# UUID
import uuids

# Kimberlite code
import kimberlite/[
  packets # Contains packet definitions
]


type
  ServerCont* = ref object of Continuation

  Server* = ref object
    ## Kimberlite server object
    running*: bool
    sock*: AsyncListener[TCP]
    clients*: Table[AsyncConn[TCP], Client]
    # Event queue
    eq: seq[Continuation]

  Client* = ref object
    ## Kimberlite client object
    conn*: AsyncConn[TCP]
    buf*, internalBuf: seq[byte]
    protocol*: int32
    connected*, disableStatusResponse: bool
    state*: ConnectionState
    uuid*: UUID


# ? Adds a continuation to the queue
proc spawn*(s: Server, cont: Continuation) = s.eq.add cont

# ? Initialise the server object.
proc init*(S: typedesc[Server], address: IP4Endpoint | IP6Endpoint | IPEndpoint): S =
  ## Initialize the server object
  result = S(sock: listenTcpAsync(address))

# ? Closes the client.
proc close*(c: Client) = #{.cps: ServerCont.} =
  ## Close the client connection
  c.connected = false

# ? Reads data from the socket into the buffer.
proc readToBuf(c: Client): bool {.cps: ServerCont.} =
  ## Reads data from the socket into the buffer. Reads 4kb at a time. Returns false on 0 bytes read.
  result = true
  let bytesRead = c.conn.read(cast[ptr UncheckedArray[byte]](addr c.internalBuf[0]), c.internalBuf.len)

  if bytesRead <= 0:
    c.close()
    return false

  c.buf.add c.internalBuf[0..<bytesRead]

# ? Reads a raw packet from the socket.
proc readPacket(c: Client): Option[RawPacket] {.cps: ServerCont.} =
  ## Reads the packet ID and buffer from a socket. Returns `RawPacket` on success.
  var res = readRawPacket(c.buf)

  while not res.isOk:
    if not c.readToBuf(): return none(RawPacket)
    res = readRawPacket(c.buf)

  for _ in 0..<res.ok.bytesRead: c.buf.delete(0)

  some(res.ok.packet)

# ? Writes a packet to the socket.
template writePacket[P: ClientboundPacket](c: Client, packet: P): bool =
  ## Writes a packet to a socket. Returns true on success, false otherwise.
  var buf = newBuffer()

  buf.writeVar[:int32](packet.id)
  buf.write packet

  var b = newBuffer()
  b.writeVar[:int32](buf.len.int32)
  buf.buf = b.buf & buf.buf

  c.conn.write(cast[ptr UncheckedArray[byte]](addr buf.buf[0]), buf.len) == buf.len

# ? Util for printing a buffer as hex
proc toHex(buf: Buffer): string {.cps: ServerCont.} =
  ## Echoes the contents of the buffer to the console
  result = newStringOfCap(buf.buf.len * 3)

  for b in buf.buf:
    result &= toHex(b) & " "

  result.setLen result.len - 1

# ? Template for clean definition of handlers.
template handler(T: typedesc[ServerboundPacket], c, s, p: untyped{nkIdent}, body: untyped) {.dirty.} =
  proc execute(e: Empty[T], c: Client, s: Server, p: RawPacket) {.cps: ServerCont.} = body

# ? Unimplemented packet handler
ServerboundUnimplementedPacket.handler(client, server, packet):
  ## Allows for us to implement plugins that implement packets instead of me, if I so desire :)
  echo "Unimplemented packet ID: " & byte(packet.id).toHex
  echo "Packet Data: " & packet.buf.toHex
  client.close()

# ? Handshake handler
ServerboundHandshake.handler(client, server, packet):
  ## Handles the handshake and updates the state.
  # Extract the protocol version from here~
  let sbh = ServerboundHandshake.read packet.buf
  client.protocol = sbh.version.unwrap()
  # Set the client state to indicate that the handshake has been completed
  case sbh.nextState.unwrap
  of nsStatus:
    client.state = Status
  of nsLogin:
    client.state = Login
  else:
    echo "Unhandled handshake state: " & $sbh.nextState
    client.close()

# ? Status response handler
ServerboundStatusRequest.handler(client, server, packet):
  ## Handles the status response and updates the state.
  # Return if the status response is disabled, that's what the vanilla server does,
  # but it's probably unnecessary, to be honest.
  if client.disableStatusResponse: return

  if not (client.writePacket ClientboundStatusResponse(serverlist: buildServerListJson("1.21.1", client.protocol, 0, 0))):
    client.close()

  client.disableStatusResponse = true

#? Ping response handler
ServerboundPingRequest.handler(client, server, packet):
  ## Handles the ping response and updates the state.
  let sbpr = ServerboundPingRequest.read packet.buf

  if not (client.writePacket ClientboundPingResponse(nonce: sbpr.nonce)):
    client.close()

  client.disableStatusResponse = true

# ? Login start handler
ServerboundLoginStart.handler(client, server, packet):
  ## Handles the initial login packet.
  let sbls = ServerboundLoginStart.read packet.buf
  client.uuid = sbls.uuid

  echo "Client with username `" & $sbls.username & "` and `" & $sbls.uuid & "` connected!"

  discard client.writePacket(ClientboundDisconnectLogin(reason: %*{"text": "Unimplemented."}))
  client.close()

# ? Handles MC clients.
proc handleClient(server: Server, client: Client) {.cps: ServerCont.} =
  mixin execute # Used to execute the packet handler

  discard client.readToBuf()

  while client.connected:
    # If the packet fails to be read, close the client as we assume it has been disconnected.
    let packet = (let p = client.readPacket(); if p.isSome: p.unsafeGet else: (client.close(); break))

    # Execute the packet handler.
    handlePacket(client.state, packet.id, client, server, packet)

# ? Starts the server
proc start(s: Server) {.cps: ServerCont.} =
  ## Start the MC server
  defer: s.running = false

  s.running = true

  while s.running:
    let (conn, _) = s.sock.accept()

    var c = Client(conn: conn, connected: true, internalBuf: newSeq[byte](1024 * 4))
    s.spawn: whelp handleClient(s, c)

# ? Runs the server dispatcher
proc run*(s: Server) =
  ## Run the MC server
  s.spawn: whelp start(s)

  while true:
    poll(s.eq)

    while s.eq.len > 0:
      let cont = s.eq[0]
      s.eq.delete(0)
      if cont == nil: continue
      discard trampoline cont

var server = Server.init(
  initEndpoint(ip4(0, 0, 0, 0), 25575.Port)
)

setControlCHook proc() {.noconv.} =
  server.running = false
  server.sock.close()

server.run()