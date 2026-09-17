# Slapp — what you bought

Voice-first app builder: describe an iPhone or Watch app out loud and watch a
real coding agent write, build, and run it while you talk. Sessions are real
Pi coding sessions on your Mac — the phone is a second door into the same run.

## Run it

1. **Server** (runs on your Mac): `cd server && npm install && node slappd.mjs`
2. **iOS app**: open `ios/` in Xcode, set your own signing team in
   `project.yml`, run on a device.
3. Hosts, paths, and credentials from the original setup are localhost
   placeholders — point them at your own machine and your own model keys.

## Notes
- Config values, paths, and credentials from the author's own fleet are
  replaced with placeholders. Bring your own model backend.
- License: see `LICENSE.md`.

## Access and updates

Send your GitHub username to **snailmail3d@gmail.com** and you'll be added to
this repo. Updates land here, so `git pull`. Questions to the same address.
