# RomM server support

Connect the app to a self-hosted [RomM](https://github.com/rommapp/romm)
server, download its games and keep battery saves and save states in step
with it. Free. Code: `app/lib/src/romm/`.

## Behaviour

- **Settings → Your server → RomM server.** A form takes the server address,
  username and password. `http://` is added when missing; a trailing `/` or
  `/api` is dropped. Connect checks the login with `GET /api/users/me`
  (HTTP Basic auth) and only keeps it when that succeeds. Errors: wrong login,
  unreachable server, or the server's own message.
- The login is stored in app-private storage (`romm/account.json`). Disconnect forgets it and every link.
- **Browse the server**: platforms with games (`GET /api/platforms`), then
  that platform's ROMs (`GET /api/roms?platform_id=`, paged 500 at a time;
  `{items,total}` or a bare list are both accepted) with search, cover
  (`path_cover_small`, fetched with the same auth) and size. A ROM already in
  the library shows a check.
- **Download** streams `GET /api/roms/{id}/content/{fs_name}` to
  `romm/downloads/`, shows progress, imports it with the normal importer
  (same rules, same duplicate handling) and deletes the temporary file. The
  game is linked to its RomM id (`links`, keyed by the game's SHA-1).
- Games imported another way are linked when the server has a ROM with the
  same SHA-1 (or CRC32), checked at each sync while unlinked games exist.

## Save and state sync

- For each linked game: the battery save `saves/<sha1>.srm` ↔ RomM save
  `<rom file stem>.srm`, and state slots `states/<sha1>/<slot>.state` ↔ RomM
  state `<stem>.<slot>.state` (quick, slot1–slot9). Thumbnails stay local.
- Each file remembers the local modified time and the server `updated_at` from
  the last sync (`seen`). Only the local side changed → upload
  (`POST /api/{saves|states}?rom_id=&emulator=dena-emu`, multipart field
  `saveFile`/`stateFile` for RomM 4 plus `saves`/`states` for RomM 3). Only the
  server changed → download from `download_path`, written atomically and
  stamped with the server time. Both changed → the newer wins; a local file
  that gets replaced is first copied to `romm/conflicts/<time>/`.
- Triggers: after connecting, after each game, and when the app is paused or
  resumed (toggle "Sync automatically"). Never while a game runs; a game that
  starts during a sync waits for it so it loads the newest save.

## Android

`usesCleartextTraffic` is on so `http://` servers on the home network work.

## Acceptance tests (`app/test/romm/romm_test.dart`)

- Address normalization; a wrong password keeps nothing; the login survives a
  restart.
- Download imports the game, links it and leaves no temporary file.
- Saves and states upload, an unchanged second sync moves nothing, and a save
  written by another device downloads.
- A game imported another way is matched by hash and receives its save.
- No sync while a game runs.

## Not yet

- Uploading local games to the server; RomM collections and firmware (BIOS).
- Storing the password in the Android Keystore instead of app storage.
