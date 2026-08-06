# Deploy Pipeline Design

Date: 2026-08-06

## Problem

`homeconnect_local_hass` is a HACS-style Home Assistant custom integration
(`custom_components/homeconnect_ws`). We want to customize it locally and get
those changes running on a real Home Assistant instance repeatedly, without
manually copying files or fighting HA's restart mechanics each time.

This spec covers only the deploy mechanism - not the integration
customization itself, which is separate future work.

## Environment

- HA runs as **Home Assistant OS** on a dedicated box at `192.168.1.14`.
- Reachable via the **Advanced SSH & Web Terminal** add-on, SSH on **port
  22** (not the add-on's more common default of 22222), user `elazar`.
- `elazar` has **passwordless `sudo`** but no `SUPERVISOR_TOKEN` access, so
  the Supervisor `ha` CLI can't authenticate over this SSH session.
- `/config` is a symlink to `/homeassistant`; `/config/custom_components` is
  `root:root`-owned and not group-writable, so writes there need `sudo`.
- `rsync` is available on the HA box but **not** on the local dev machine
  (Windows + Git Bash), so file sync uses `tar` over SSH instead.
- HA's REST API (port 8123) is reachable directly from the dev machine and
  is used for triggering a restart, authenticated with a Long-Lived Access
  Token from an admin account.

## Design

A single manual script, `script/deploy.sh`, run from the repo root:

1. **Sync**: tar the local `custom_components/homeconnect_ws/` directory,
   stream it over SSH, and on the remote side `sudo rm -rf` the old
   directory and extract the new one, then `sudo chown -R root:root` it.
   This is a full replace (not an incremental sync), so files deleted
   locally are also removed remotely.
2. **Restart**: POST to `/api/services/homeassistant/restart` with the
   Long-Lived Access Token, best-effort (short timeout, response ignored).
   See "Restart response is unreliable" below for why.
3. **Confirm**: poll `GET /` on the HA base URL every 3s for up to 90s.
   Success is HA responding again; if it never responds within the window,
   the script exits non-zero with a warning (the file sync itself already
   succeeded either way, so this only flags the restart/reload step).

Configuration lives in `.env.deploy` (gitignored, git-untracked secret) with
a checked-in `.env.deploy.example` template holding the three variables:
`HA_SSH_HOST` (an SSH config alias), `HA_URL`, `HA_TOKEN`.

SSH access itself is set up outside the repo: a dedicated ed25519 deploy key
(`~/.ssh/id_ed25519_ha_deploy`, no passphrase, used only for this) and a `ha`
alias in `~/.ssh/config` pointing at `elazar@192.168.1.14:22`.

## Restart response is unreliable

Calling `homeassistant.restart` via the REST API produces inconsistent HTTP
outcomes even when the restart itself works correctly: empty replies,
connection timeouts, or a 500 response with HA's own generic error page
("Server got itself in trouble"). This happens because HA's web server is
being torn down while still trying to send the response. Firing the same
call again shortly after a just-completed restart can also produce a 500
with no restart actually happening (likely some internal guard/race in that
window).

Because of this, the script never treats the restart call's HTTP response as
a signal of success or failure. It fires the call best-effort and instead
verifies success independently by polling until HA responds to ordinary
requests again, within a 90s window.

## Out of scope

- Automatic/on-save deploys - deploying is a manual, deliberate action for
  now (`./script/deploy.sh`).
- Actual customization of the integration's behavior.
- Deploying to multiple HA instances or environments.
