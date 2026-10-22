# SPDX-License-Identifier: GPL-3.0-or-later
"""The relay's room protocol (netplay.md): python3 tools/relay/test_dena_relay.py"""
import asyncio
import os
import socket
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dena_relay  # noqa: E402

HELLO = dena_relay.HELLO


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


async def line(reader: asyncio.StreamReader) -> str:
    return (await asyncio.wait_for(reader.readline(), 5)).decode().strip()


async def request(port: int, text: str):
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    writer.write((HELLO + text + "\n").encode())
    await writer.drain()
    return reader, writer


class RoomTest(unittest.TestCase):
    def test_code_shape(self):
        code = dena_relay.Relay().new_code()
        self.assertEqual(len(code), dena_relay.CODE_LEN)
        self.assertTrue(all(c in dena_relay.ALPHABET for c in code))

    def test_lookup_join_and_bridge(self):
        async def run():
            port = free_port()
            ready = asyncio.Event()
            task = asyncio.create_task(dena_relay.serve("127.0.0.1", port, ready))
            await ready.wait()
            try:
                # Unknown codes and requests are refused.
                r, w = await request(port, "LOOKUP ZZZZZZ")
                self.assertTrue((await line(r)).startswith("ERR no room"))
                w.close()
                r, w = await request(port, "NOPE")
                self.assertTrue((await line(r)).startswith("ERR"))
                w.close()

                hr, hw = await request(port, "HOST 47330 192.168.1.5")
                room, code, ip = (await line(hr)).split()
                self.assertEqual((room, ip), ("ROOM", "127.0.0.1"))

                r, w = await request(port, "LOOKUP " + code.lower())
                self.assertEqual(await line(r),
                                 "HOST 127.0.0.1:47330 192.168.1.5:47330 YOU 127.0.0.1")
                w.close()

                jr, jw = await request(port, "JOIN " + code)
                peer, token = (await line(hr)).split()
                self.assertEqual(peer, "PEER")
                br, bw = await request(port, f"ACCEPT {code} {token}")
                self.assertEqual(await line(br), "OK")
                self.assertEqual(await line(jr), "OK")
                jw.write(b"ping")
                await jw.drain()
                self.assertEqual(await asyncio.wait_for(br.readexactly(4), 5), b"ping")
                bw.write(b"pong")
                await bw.drain()
                self.assertEqual(await asyncio.wait_for(jr.readexactly(4), 5), b"pong")
                for wr in (jw, bw, hw):
                    wr.close()
            finally:
                task.cancel()
        asyncio.run(run())


if __name__ == "__main__":
    unittest.main()
