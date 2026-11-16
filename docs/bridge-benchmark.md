# Packet bridge benchmark

How fast `PacketBridge` (`Sources/OpenConnectTunnelCore/PacketBridge.swift`) moves
packets between the system's packet flow and libopenconnect. It exists to
answer [improvements.md](improvements.md) item 13: is the socket pair between
the two a bottleneck?

## Running it

The benchmark is a Swift Testing suite that is skipped unless you opt in:

```sh
BRIDGE_BENCH=1 swift test --filter PacketBridgeBenchmark
```

Each case runs for 3 seconds and prints one line starting with `BENCH`. The
suite is `.serialized`; run in parallel the cases compete for CPU and the
numbers are meaningless. Source:
`Tests/OpenConnectTunnelTests/PacketBridgeBenchmark.swift`.

## What it measures

| Case | What moves |
|---|---|
| `systemToLibrary` | A fake packet flow hands the bridge batches of 128 packets back to back; a thread on `libraryFD` reads and counts the datagrams. |
| `libraryToSystem` | A thread on `libraryFD` writes datagrams as fast as it can; the bridge reads them and passes batches to a fake `writePackets`, which counts them. |
| `rawSocketPairBaseline` | The same datagrams over a bare `socketpair`, with no bridge. The difference to the other two is the bridge's own cost. |

It leaves out `NEPacketTunnelFlow` itself (the XPC hop to the system) and the
VPN transport (ESP or TLS encryption, the network). It is the ceiling the
bridge puts on a tunnel, not the speed of a real one.

## Packet size

The benchmark uses 1400-byte packets (`packetSize` in the test). That figure is
an assumption, not something measured from a real tunnel: it stands for a
typical full-size packet inside a VPN tunnel. A 1500-byte Ethernet MTU minus
the outer IP, UDP and ESP (or TLS) headers leaves roughly 1300 to 1400 bytes,
and the server tells the client the real value (the provider applies it as the
tunnel MTU when it is between 576 and 9000, see `TunnelPlan`).

The size changes the Gbit/s figure but not the packet rate much, because the
cost is mostly per packet (one `recv`/`send` and one copy each). Smaller
packets give a lower Gbit/s at a similar packets-per-second rate; to check
another size, change `packetSize`.

## Results

Apple M4 Pro (Mac16,8), 1400-byte packets, 3 s per case, serialized:

| Case | Throughput | Packet rate |
|---|---|---|
| System to libopenconnect | 12.2 Gbit/s | 1087 kpps |
| libopenconnect to system | 14.4 Gbit/s | 1283 kpps |
| Bare socket pair (no bridge) | 18.1 Gbit/s | 1617 kpps |

The bridge costs about 25 to 30 percent against a bare socket pair, and still
moves over a million packets per second in each direction. That is far more
than the ESP or TLS transport can encrypt on one connection, so the bridge is
not the limit and handing libopenconnect the utun descriptor directly would
not be worth the fragility (see item 13).

## If speed ever is a problem

Measure end to end instead: run `iperf3` through a real tunnel, with the
server on the far side of the VPN, and compare with the same transfer outside
it. That includes `NEPacketTunnelFlow` and the transport, which this benchmark
does not.
