# Running a relay server (netplay and link cable rooms)

Joining a **room** by its code (netplay.md) needs a relay server: it keeps the
room codes, tells the joiner where the host is so the two PCs can connect
directly, and bridges the bytes when they cannot. No relay ships with Dena.emu and none is
deployed by the project; whoever wants rooms runs their own and types its
address into **Settings > NETPLAY.CFG > Relay server** on both PCs.

The server is one file, `tools/relay/dena_relay.py`: Python 3.9 or newer,
standard library only. It keeps nothing on disk and never sees games or saves,
only the bytes two players exchange while bridged (input for netplay, link
words for the link cable). A bridged netplay game uses well under 10 KB/s per
direction plus the host's state once at the start.

## Quick try (any PC)

```
python3 tools/relay/dena_relay.py --port 47340
```

Then set the relay to `<that PC's address>:47340` on both PCs. Rooms only help
across the internet when the relay itself is reachable from both players, so for
real use run it on a small VPS.

## On a VPS (Debian / Ubuntu, systemd)

1. Copy the script: `sudo install -D -m 0755 dena_relay.py /opt/dena-relay/dena_relay.py`
2. A user with no rights: `sudo useradd --system --no-create-home dena-relay`
3. `/etc/systemd/system/dena-relay.service`:

   ```
   [Unit]
   Description=Dena.emu relay server
   After=network-online.target

   [Service]
   User=dena-relay
   ExecStart=/usr/bin/python3 /opt/dena-relay/dena_relay.py --host 0.0.0.0 --port 47340 --quiet
   Restart=on-failure
   NoNewPrivileges=true
   ProtectSystem=strict
   ProtectHome=true
   PrivateTmp=true

   [Install]
   WantedBy=multi-user.target
   ```

4. `sudo systemctl enable --now dena-relay`
5. Open TCP 47340 in the firewall (`sudo ufw allow 47340/tcp`) and in the
   provider's security group.
6. In Dena.emu on both PCs: Settings > NETPLAY.CFG > Relay server =
   `<vps address>:47340`.

`journalctl -u dena-relay` shows rooms opening and closing (drop `--quiet` to
see each connection).

## Limits built into the server

- A room lives while the host's connection stays open, at most 6 hours.
- One host IP holds at most 4 rooms; the first line must arrive within 15 s.
- The host must accept a joiner's bridge within 10 s.

## Ports on the players' side

- Nothing to forward for rooms: the joiner tries the host directly (its LAN
  address when both share a public address, then the public one) and falls
  back to the relay bridge.
- Joining by plain address over the internet (free, no relay) needs the host
  to forward TCP 47330 (netplay) or 47320 (link cable) to its PC.
