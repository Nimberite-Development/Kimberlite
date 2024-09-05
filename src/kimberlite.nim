# Standard library
import std/[
  strformat,
  strutils,
  options, # Self-explanatory
  tables   # Used primarily for storing clients in a table so that they can be referenced easily.
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
    protocol*: int32
    connected*, disableStatusResponse: bool
    state*: ConnectionState


# ? Adds a continuation to the queue
proc spawn*(s: Server, cont: Continuation) = s.eq.add cont

# ? Initialise the server object.
proc init*(S: typedesc[Server], address: IP4Endpoint | IP6Endpoint | IPEndpoint): S =
  ## Initialize the server object
  result = S(sock: listenTcpAsync(address))

# ? Reads a raw packet from the socket.
proc readPacket(c: Client): Option[RawPacket] {.cps: ServerCont.} =
  ## Reads the packet ID and buffer from a socket. Returns `RawPacket` on success.
  var
    b = seq[byte].new()
    res = readRawPacket(b[])

  while not res.isOk:
    # Make the buffer bigger so we can read more data
    let offset = b[].len
    b[].setLen(b[].len + res.err)
    if c.conn.read(cast[ptr UncheckedArray[byte]](addr b[][offset]), res.err) <= 0: return none(RawPacket)
    res = readRawPacket(b[])

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

# ? Closes the client.
proc close*(c: Client) {.cps: ServerCont.} =
  ## Close the client connection
  c.conn.close()
  c.connected = false

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

  if not (client.writePacket ClientboundStatusResponse(response: buildServerListJson("1.21.1", client.protocol, 0, 0))):
    client.close()

  client.disableStatusResponse = true

#? Ping response handler
ServerboundPingRequest.handler(client, server, packet):
  ## Handles the ping response and updates the state.
  let sbpr = ServerboundPingRequest.read packet.buf

  if not (client.writePacket ClientboundPingResponse(nonce: sbpr.nonce)):
    client.close()

  client.disableStatusResponse = true

# ? Handles MC clients.
proc handleClient(server: Server, client: Client) {.cps: ServerCont.} =
  mixin execute # Used to execute the packet handler

  while client.connected:
    # If the packet fails to be read, close the client as we assume it has been disconnected.
    let packet = (let p = client.readPacket(); if p.isSome: p.unsafeGet else: (client.close(); break))

    # Execute the packet handler.
    handlePacket(client.state, packet.id, client, server, packet)
    #[
    if not client.playMode:
      case packet.id
      of 0x00:
        if not client.handshook:
          let sbh = ServerboundHandshake.read packet.buf
          client.protocol = sbh.version.unwrap()
          # TODO: Implement logic for protocol version-dependent behaviour
          client.handshook = true
        else:
          let res = ClientboundStatusResponse(response: buildServerListJson("1.21.1", client.protocol, 0, 0))

          if not (client.conn.writePacket res): client.close()

      of 0x01:
        let pingReq = ServerboundPingRequest.read packet.buf

        if not (client.conn.writePacket ClientboundPingResponse(nonce: pingReq.nonce)): client.close()
      else:
        echo &"Unsupported packet! ID `0x{toHex(byte(packet.id))}`, Contents `{toHex(packet.buf)}`"
        client.close()
    else:
      client.close()
  ]#

# ? Starts the server
proc start(s: Server) {.cps: ServerCont.} =
  ## Start the MC server
  defer: s.running = false

  s.running = true

  while s.running:
    let (conn, _) = s.sock.accept()

    s.spawn: whelp handleClient(s, Client(conn: conn, connected: true))

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