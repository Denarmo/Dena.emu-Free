#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Dena.emu relay server: room codes and byte bridging for netplay and the
link cable over the internet. Spec: docs/specs/netplay.md; how to run it:
docs/dev/relay-server.md.

Python 3.9+, standard library only. It never sees games or saves, only the
bytes two players exchange, and keeps nothing on disk.

    python3 dena_relay.py --port 47340
"""
from __future__ import annotations

import argparse
import asyncio
import logging
import secrets
import time

ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
CODE_LEN = 6
HELLO = "DENA-RELAY 1 "
LINE_MAX = 256
ROOM_TTL = 6 * 3600  # seconds a room may live
ROOMS_PER_IP = 4
ACCEPT_TIMEOUT = 10.0  # host must open its bridge within this
IDLE_TIMEOUT = 15.0  # first line must arrive within this
PING_EVERY = 20.0

log = logging.getLogger("dena-relay")


class Room:
    def __init__(self, code: str, host_ip: str, port: int, lan: str,
                 writer: asyncio.StreamWriter):
        self.code = code
        self.host_ip = host_ip
        self.port = port
        self.lan = lan
        self.writer = writer
        self.created = time.monotonic()
        # token -> future resolved with the host's bridge (reader, writer)
        self.pending: dict[str, asyncio.Future] = {}


class Relay:
    def __init__(self, max_rooms: int = 1000, max_bridges: int = 200):
        self.rooms: dict[str, Room] = {}
        self.max_rooms = max_rooms
        self.max_bridges = max_bridges
        self.bridges = 0

    def new_code(self) -> str:
        while True:
            code = "".join(secrets.choice(ALPHABET) for _ in range(CODE_LEN))
            if code not in self.rooms:
                return code

    def expire(self) -> None:
        now = time.monotonic()
        for code, room in list(self.rooms.items()):
            if now - room.created > ROOM_TTL:
                log.info("room %s expired", code)
                room.writer.close()
                self.rooms.pop(code, None)

    async def handle(self, reader: asyncio.StreamReader,
                     writer: asyncio.StreamWriter) -> None:
        peer = writer.get_extra_info("peername") or ("?", 0)
        ip = peer[0]
        try:
            line = await asyncio.wait_for(reader.readline(), IDLE_TIMEOUT)
        except (asyncio.TimeoutError, ConnectionError):
            writer.close()
            return
        text = line.decode("ascii", "replace").strip()
        if len(line) > LINE_MAX or not text.startswith(HELLO):
            await self.say(writer, "ERR not a Dena.emu relay request", close=True)
            return
        verb, *args = text[len(HELLO):].split()
        try:
            if verb == "HOST" and len(args) >= 1:
                await self.host(reader, writer, ip, args)
            elif verb == "LOOKUP" and len(args) == 1:
                await self.lookup(writer, ip, args[0].upper())
            elif verb == "JOIN" and len(args) == 1:
                await self.join(reader, writer, args[0].upper())
            elif verb == "ACCEPT" and len(args) == 2:
                await self.accept(reader, writer, args[0].upper(), args[1])
            else:
                await self.say(writer, "ERR unknown request", close=True)
        except ConnectionError:
            writer.close()

    @staticmethod
    async def say(writer: asyncio.StreamWriter, text: str, close: bool = False) -> None:
        writer.write((text + "\n").encode("ascii"))
        try:
            await writer.drain()
        except ConnectionError:
            pass
        if close:
            writer.close()

    async def host(self, reader, writer, ip: str, args: list[str]) -> None:
        self.expire()
        if len(self.rooms) >= self.max_rooms:
            await self.say(writer, "ERR the relay is full, try later", close=True)
            return
        if sum(1 for r in self.rooms.values() if r.host_ip == ip) >= ROOMS_PER_IP:
            await self.say(writer, "ERR too many rooms from this address", close=True)
            return
        try:
            port = int(args[0])
        except ValueError:
            port = 0
        if not 0 < port < 65536:
            await self.say(writer, "ERR bad port", close=True)
            return
        lan = args[1] if len(args) > 1 else "-"
        room = Room(self.new_code(), ip, port, lan, writer)
        self.rooms[room.code] = room
        log.info("room %s opened by %s", room.code, ip)
        await self.say(writer, f"ROOM {room.code} {ip}")
        try:
            # The room lives while this connection does; pings keep NATs open.
            while True:
                try:
                    data = await asyncio.wait_for(reader.read(256), PING_EVERY)
                except asyncio.TimeoutError:
                    await self.say(writer, "PING")
                    if writer.is_closing():
                        break
                    continue
                if not data:
                    break
        finally:
            if self.rooms.get(room.code) is room:
                del self.rooms[room.code]
            for fut in room.pending.values():
                if not fut.done():
                    fut.cancel()
            writer.close()
            log.info("room %s closed", room.code)

    async def lookup(self, writer, ip: str, code: str) -> None:
        room = self.rooms.get(code)
        if room is None:
            await self.say(writer, "ERR no room with that code", close=True)
            return
        lan = f"{room.lan}:{room.port}" if room.lan != "-" else "-"
        await self.say(writer, f"HOST {room.host_ip}:{room.port} {lan} YOU {ip}", close=True)

    async def join(self, reader, writer, code: str) -> None:
        room = self.rooms.get(code)
        if room is None:
            await self.say(writer, "ERR no room with that code", close=True)
            return
        if self.bridges >= self.max_bridges:
            await self.say(writer, "ERR the relay is full, try later", close=True)
            return
        token = secrets.token_hex(8)
        fut = asyncio.get_running_loop().create_future()
        room.pending[token] = fut
        await self.say(room.writer, f"PEER {token}")
        try:
            h_reader, h_writer = await asyncio.wait_for(fut, ACCEPT_TIMEOUT)
        except (asyncio.TimeoutError, asyncio.CancelledError):
            await self.say(writer, "ERR the host did not answer", close=True)
            return
        finally:
            room.pending.pop(token, None)
        await self.say(writer, "OK")
        await self.say(h_writer, "OK")
        log.info("room %s: bridge up", code)
        self.bridges += 1
        try:
            await asyncio.gather(self.pipe(reader, h_writer), self.pipe(h_reader, writer))
        finally:
            self.bridges -= 1
            log.info("room %s: bridge closed", code)

    async def accept(self, reader, writer, code: str, token: str) -> None:
        room = self.rooms.get(code)
        fut = room.pending.get(token) if room else None
        if fut is None or fut.done():
            await self.say(writer, "ERR nobody is waiting", close=True)
            return
        fut.set_result((reader, writer))
        # join() owns both ends from here.

    @staticmethod
    async def pipe(src: asyncio.StreamReader, dst: asyncio.StreamWriter) -> None:
        try:
            while True:
                data = await src.read(65536)
                if not data:
                    break
                dst.write(data)
                await dst.drain()
        except ConnectionError:
            pass
        finally:
            dst.close()


async def serve(host: str, port: int, ready: asyncio.Event | None = None) -> None:
    relay = Relay()
    server = await asyncio.start_server(relay.handle, host, port)
    log.info("listening on %s:%d", host, port)
    if ready:
        ready.set()
    async with server:
        await server.serve_forever()


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--host", default="0.0.0.0", help="address to listen on")
    ap.add_argument("--port", type=int, default=47340, help="TCP port (default 47340)")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()
    logging.basicConfig(level=logging.WARNING if a.quiet else logging.INFO,
                        format="%(asctime)s %(message)s")
    try:
        asyncio.run(serve(a.host, a.port))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
