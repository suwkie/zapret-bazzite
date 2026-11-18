# zapret-bazzite

Flowseal's [zapret-discord-youtube](https://github.com/Flowseal/zapret-discord-youtube)
strategies with a Fedora Atomic (Bazzite) install path, running the upstream
[bol-van/zapret](https://github.com/bol-van/zapret) `nfqws` engine under
nftables and systemd.

## Features

- All 22 Flowseal `general*` strategies, converted from Windows `winws` flags
  to Linux `nfqws` arguments at install time.
- One-command install, interactive menu, strategy switching, autostart.
- Strategy probe against Discord/YouTube/Google endpoints.
- Game filter toggle (TCP+UDP `1024-65535`).
- Discord RTC and Minecraft/Hypixel (TCP 25565) bypass toggles.
- Pinned, checksum-verified engine (`v72.13`) and pinned, checksum-verified
  Flowseal commit; lists and fake payloads included.
- No Python, no iptables, no extra runtime services.

## Requirements

- Bazzite, or another Fedora Atomic desktop (Silverblue, Kinoite, Aurora).
- Root for install and for applying nftables rules.
- A kernel with NFQUEUE support (`nfnetlink_queue`, `nft_queue`); Fedora's
  kernel ships both as modules and loads them on demand.
- `nft`, `curl`, `tar`, `flock`, `sudo` (all normally present); if one is
  missing, layer it: `sudo rpm-ostree install nftables && sudo systemctl reboot`.

The tree installs under `/usr/local/lib/zapret-arch` — `/opt` and `/usr` are
read-only on an ostree system, `/usr/local` is the writable one. The installer
relabels the tree to `bin_t`, because systemd's `init_t` may not execute from
the default label it gets there.

## Install

One file, no clone — the whole project is embedded in the script:

```bash
gh release download v0.2.0 --repo suwkie/zapret-bazzite   --pattern 'install-zapret-bazzite.sh' --dir /tmp
sudo bash /tmp/install-zapret-bazzite.sh
```

From a clone, the same installer:

```bash
gh repo clone suwkie/zapret-bazzite      # or: git clone https://github.com/suwkie/zapret-bazzite.git
cd zapret-bazzite
sudo ./install.sh
```

`install-zapret-bazzite.sh` carries the engine installer, CLI, profiles, unit
template and extras; it extracts to a temporary directory, installs, and points
`state/source` at the installed copy so `sudo zapret-arch update` keeps working
after the temp directory is gone. The desktop GUI is not inside it — take the
GUI archive below, or build it from the clone.

Do not pass `--start` on the first run: if the SELinux relabel did not take,
the unit fails with `203/EXEC` and the installer rolls the whole tree back.
Start it once by hand, then it is enabled.

Options:

```text
--prefix DIR    install under DIR (default /usr/local/lib/zapret-arch)
--no-systemd    write the unit template but do not install it (staging)
--start         start the service after install
```

`--prefix` is for unprivileged staging: run the installer without sudo, and
it selects `--no-systemd` automatically. A root install refuses a prefix or
ancestor that is not root-owned or that is group/world-writable.

The installer downloads the pinned engine and pinned Flowseal commit,
converts and dry-run-validates every strategy, writes the upstream config,
installs `zapret-arch.service`, and enables it. If `zapret.service` or
`zapret_discord_youtube.service` is already running, stop it first; the
installer refuses to fight a live `nfqws`. After a successful install it stops
and disables those two conflicting units but leaves their files and
`/opt/zapret` untouched. Their unit files can be re-enabled if you remove this
install.

## Quick start

```bash
sudo zapret-arch            # interactive menu
sudo zapret-arch list       # strategies, * = current
sudo zapret-arch probe      # per-endpoint HTTP codes for current strategy
sudo zapret-arch test       # probe every strategy, restore the previous one
sudo zapret-arch use general
sudo zapret-arch minecraft on   # Hypixel / Minecraft TCP 25565
sudo zapret-arch voice off      # if Discord RTC breaks
sudo zapret-arch status
```

A typical first run:

1. Enable Secure DNS in the browser (see below).
2. `sudo zapret-arch test` and note which strategies reach the endpoints.
3. `sudo zapret-arch use <winner>`.
4. `sudo zapret-arch games on` only if a game needs it.
5. For Hypixel: `sudo zapret-arch minecraft on`.

## Interactive TUI

`sudo zapret-arch` (or `sudo zapret-arch menu`) opens a full-screen dashboard:
service state, queue 201, game filter, the 22 strategies with their last probe
score, and a detail pane for the selected strategy.

| Key | Action |
| --- | --- |
| `↑`/`k`, `↓`/`j` | move selection |
| `PgUp`/`PgDn`, `Home`/`End` | page / jump |
| `Enter` | apply selected strategy |
| `t` / `T` | test selected / all strategies |
| `g` | toggle game filter |
| `v` | toggle Discord RTC desync |
| `m` | toggle Minecraft/Hypixel bypass |
| `s` | start / stop bypass |
| `r` | refresh status |
| `?`/`h` | help |
| `q` | quit |

Tests run outside the dashboard so you can see their full output, then return
to it and update the per-strategy scores. A non-TTY (piped input) falls back
to the numbered menu; a terminal smaller than 70x20 shows a resize notice and
only `q` is accepted. Colors use 256-color ANSI when available, then 16
colors, then monochrome; `NO_COLOR` and `ZAPRET_ASCII=1` are respected.

## Desktop GUI

### Download

The repository is private, so downloads need a GitHub account — `gh auth login`
once, or `$GH_TOKEN`.

```sh
# prebuilt GUI (no Rust needed; the engine must already be installed)
gh release download v0.2.0 --repo suwkie/zapret-bazzite \
  --pattern 'zapret-arch-gui-*' --dir /tmp/zapret-gui
tar -xzf /tmp/zapret-gui/zapret-arch-gui-*.tar.gz -C /tmp/zapret-gui
cd /tmp/zapret-gui/zapret-arch-gui-* && sudo ./install-gui.sh
```

```sh
# whole project, built here
gh repo clone suwkie/zapret-bazzite
cd zapret-bazzite/gui && cargo build --release
cd .. && sudo ./install.sh --with-gui
```

The GUI goes to `/usr/local/bin` and its root helper is authorised by
`/etc/sudoers.d/zapret-arch-gui`, written for the user who ran the installer.
There is no polkit action: polkit only reads actions from `/usr/share`, which
is read-only here.

### What it is

`gui/` is a small GTK4 client with the same information as the TUI: service
state, the strategy list with last test scores, the three global flags, a
probe, the journal, and a strategy test with live output. It never writes
state itself — reads come from `/usr/local/lib/zapret-arch/state`, and every
change goes through `/usr/local/bin/zapret-arch-helper`, the only command the
`/etc/sudoers.d/zapret-arch-gui` rule grants, so the GUI can only run the
helper's verbs.

```sh
cd gui && cargo build --release   # once, as yourself
sudo ./install.sh --with-gui      # engine + GUI; auto-detects a built binary
zapret-arch gui                   # or launch it from the app menu
```

`install.sh` installs the GUI on its own whenever `gui/target/release/zapret-arch-gui`
exists, so `sudo zapret-arch update` refreshes it too. `--no-gui` skips it,
`--with-gui` fails the install instead of skipping when the binary is missing.
The four files can be removed alone with `sudo gui/install-gui.sh --remove`.

Requires `gtk4` and `sudo`. The window uses Iosevka when it is installed and
falls back to DejaVu Sans Mono.
The icon is Lucide's `shield-check` (ISC), recoloured to the window palette. The first
action of each burst asks for the admin password; sudo keeps it for about
five minutes. Uninstall with:

```sh
sudo rm -f /usr/lib/zapret-arch/helper /usr/bin/zapret-arch-gui \
           /usr/local/bin/zapret-arch-helper \
           /etc/sudoers.d/zapret-arch-gui \
           /usr/share/applications/ru.suwkie.zapret-arch.desktop
```

## Autostart

The installer enables `zapret-arch.service`, so it starts at boot. Check it
with `zapret-arch status` or `systemctl is-enabled zapret-arch.service`.

- `sudo zapret-arch on` — enable at boot and start now.
- `sudo zapret-arch off` — stop now and disable at boot.
- `sudo zapret-arch autostart on|off` — change the boot setting only, without
  starting or stopping the service.

The TUI's `s` key starts/stops and also enables/disables boot.

## How it works

The installer keeps the upstream init script and config format, and adds a
small generated override block:

- nftables queues the first packets of matching connections (`ct original
  packets 1-9`, replies `1-3`) to NFQUEUE 201; `nfqws` desynchronizes them.
  Queue 201 and table `zapret_arch` are namespaced so an existing
  `/opt/zapret` installation (queue 200, table `zapret`) cannot collide.
- `MODE_FILTER=none` means the queued ports are defined by the selected
  strategy (`80,443,2053,2083,2087,2096,8443` TCP and `443,19294-19344,
  50000-50100` UDP, plus `1024-65535` when the game filter is on).
- Disabled features are removed from `NFQWS_OPT`, not just from the firewall
  ports: `games off` drops the `1024-65535` game profiles, and `voice off`
  drops the Discord voice/media profiles. This keeps game/voice ports out of
  nfqws entirely.
- Per-strategy hostlists and ipsets are embedded in `NFQWS_OPT`, exactly as in
  Flowseal's `.bat` files.
- nfqws marks desync packets with `0x40000000` so they are not queued again.

Layout:

```text
/usr/local/lib/zapret-arch/
├── engine/       upstream zapret v72.13 tree (init, config, binaries)
├── bats/         original Flowseal .bat strategies
├── profiles/     converted .tcp/.udp/.opt profiles
├── fakes/        Flowseal fake TLS/QUIC/STUN payloads
├── lists/        Flowseal domain and IP lists
├── state/        selected strategy, game/voice/minecraft flags
└── app/          this CLI and installer
```

## Strategies and game filter

Strategy names are slugs of the original files: `general`,
`general-alt10`, `general-fake-tls-auto`, `general-simple-fake-alt2`, etc.
Flowseal's own advice applies: strategies stop working over time and vary by
ISP, so test several.

`games on` adds `1024-65535` to the queued TCP and UDP ports. It is off by
default because it sends a lot of traffic through nfqws. When off, the game
profiles are removed from nfqws too, so they cannot touch Discord voice ports.
Turn it off again after gaming.

`voice on` is the default and keeps Flowseal's Discord RTC desync profiles
(UDP 19294-19344/50000-50100 and Discord media TCP ports). If voice or screen
share breaks, `voice off` removes those profiles and ports while web Discord
and YouTube stay bypassed.

## Minecraft / Hypixel

Hypixel runs through Cloudflare Spectrum. Russian DPI drops its ECH traffic,
so `mc.hypixel.net` shows **Disconnected** even when ordinary websites work.
Adding the domain to a list is not enough.

`sudo zapret-arch minecraft on` adds a dedicated first nfqws profile for
TCP 25565 (the Hypixel/Flowseal `multisplit` + seqovl fix) and queues port
25565. It works with `games on` and with any selected strategy. Turn it off
with `sudo zapret-arch minecraft off`; the flag persists across installs and
reboots. Java Edition only; Bedrock uses different ports.

If Hypixel still disconnects, try another strategy with Minecraft left on;
the fix depends on the ISP's DPI. It does not change your IP, so it does not
trip Hypixel's VPN/proxy IP checks; Hypixel's security system can still act on
other signals.

The profile is port-wide: any service on TCP 25565 receives the same
multisplit treatment, not only Hypixel. That is the trade-off of a port-based
toggle.

## Secure DNS

DPI bypass does not fix DNS poisoning. Enable DNS-over-HTTPS in Chrome/Firefox,
or use a trusted resolver (`https://dns.google/dns-query` is a common choice
in Flowseal's instructions). Without working DNS, even a correct strategy looks
broken.

## Troubleshooting

```bash
sudo zapret-arch status
journalctl -u zapret-arch -n 50 --no-pager
sudo nft list table inet zapret_arch
```

- **Service fails immediately**: the unit's `ExecStartPost` requires this
  install's `nfqws` and a queue rule in table `zapret_arch`. Check the journal
  for a rejected option or a missing list file.
- **Nothing loads**: run `sudo zapret-arch test`, try `general`, `general-alt*`,
  `general-simple-fake*`, `general-fake-tls-auto*`, and verify Secure DNS.
- **A site breaks**: try another strategy; the current strategy's hostlist or
  ipset may include that network. Exclusions live in Flowseal's lists.
- **Hypixel shows "Disconnected"**: run `sudo zapret-arch minecraft on`. If it
  still fails, keep it on and try other strategies. Adding `hypixel.net` to a
  domain list does not help; the block is on Cloudflare Spectrum/ECH at
  TCP 25565, not on the domain name.
- **Discord RTC broke**: run `sudo zapret-arch voice off`. That removes the
  Discord voice/media desync profiles and their ports while leaving web
  Discord and YouTube bypassed. If `games` is on, turn it off first — the game
  profile covers all high ports and can also touch RTC traffic.
- **YouTube/Google slow on first load**: the browser may be trying HTTP/3
  (QUIC) over UDP 443, which the bypass does not carry reliably; it waits for
  the QUIC timeout before falling back to TCP. In Firefox set
  `network.http.http3.enable` to `false` (`about:config`); in Chromium disable
  `chrome://flags/#enable-quic`. Also set `network.dns.disableIPv6` to `true`
  if the host has no working IPv6 route, and `network.dns.echconfig.enabled`
  to `false` because ECH is blocked by the same DPI. If it is still slow, try
  `sudo zapret-arch use general` (`multisplit`) instead of a `hostfakesplit`
  strategy such as `general-alt9`; use `zapret-arch probe` to compare.
- **YouTube Shorts stalls or shows a black player**: Shorts prefers HTTP/3.
  No shipped profile carries Google/YouTube QUIC: the UDP 443 blocks use
  `list-general.txt` (no Google entries), and `list-google.txt` is used only
  for TCP 443; `ipset-all.txt` is a placeholder. If UDP 443 is dropped by the
  ISP, disable HTTP/3 in the browser as above and retry. Switching strategies
  does not change this because their UDP 443 blocks are identical.
- **A single site is blocked (for example Modrinth)**: add its exact host to
  `lists/list-general-user.txt` with a leading `^` (`^modrinth.com`) and
  restart the service. `^` disables subdomain matching, so working endpoints
  such as `api.modrinth.com` and `cdn.modrinth.com` stay direct. The installer
  seeds `^modrinth.com`; the user list survives reinstalls. If a Cloudflare
  host still stalls with a `hostfakesplit` strategy, switch to `general`
  (`multisplit`) as above.
- **Steam Cloud sync fails on one file**: the client downloads cloud files from
  `steamcloud-*.s3.dualstack.eu-central-1.amazonaws.com`, and this ISP drops the
  connection after the TCP handshake - the TLS ClientHello is retransmitted and
  never answered, so every attempt ends in `HTTP download ... timed out` after
  60 s and the whole app's sync is reported failed. curl to the same IP and SNI
  works, so it is a segment/fingerprint drop; seed that host in
  `lists/list-general-user.txt` and let the split desync carry the handshake.
- **The Modrinth App cannot download Minecraft**: not a zapret case. These
  names (piston-meta, piston-data, resources.download, libraries,
  launchermeta, sessionserver) mostly resolve to the Azure Front Door address
  `150.171.109.53`, which this ISP drops at TCP 443 while sibling Front Door
  addresses (`.109.197`, `.109.198`, `.110.114`, `.110.118`) answer normally.
  Front Door routes by SNI/Host, so `sudo zapret-arch hosts on` pins the names
  to a working address in `/etc/hosts` (`hosts off` removes them, `hosts check`
  probes each one); the installer does this automatically for the default
  prefix. A DPI bypass cannot help an IP-level drop.
- **Roblox icons and thumbnails stay blank while the game itself works**: the
  ISP's resolver returns `tr.rbxcdn.com`'s CNAME but withholds the A records of
  `trns1.rbxcdn.com`, so `getaddrinfo()` yields nothing and every icon request
  dies before a socket opens. The name is served normally by every CloudFront
  edge, and port 53 is not touched by nfqws, so no strategy helps either.
  `sudo zapret-arch hosts roblox on` pins `tr.rbxcdn.com` to a verified edge;
  `hosts roblox check` probes it, `hosts roblox off` removes only that block.
  The edge list ages — if icons break again, re-read it with
  `dig +short A tr.rbxcdn.com @9.9.9.9` and pass the address:
  `sudo zapret-arch hosts roblox on <ip>`.
- **Spotify shows no icons and plays nothing**: the client's hosts match no
  zapret list, so `nfqws` never touches them; the ISP drops the ClientHello
  for `i.scdn.co` and stalls the `ap-*.spotify.com` access points from
  `apresolve`, while the audio CDNs answer. Two bare lines cover the family and
  the installer seeds them; on an existing install append `scdn.co` and
  `spotify.com` to `/usr/local/lib/zapret-arch/lists/list-general-user.txt`
  and restart the unit.
- **YouTube needs an immediate click when a preview appears**: the muted
  hover/feed preview starts a media connection; if that first connection
  stalls through the DPI path, the full player inherits it. Turn off YouTube
  **Settings → Playback and performance → Video previews** (desktop). On
  mobile, use **Settings → General → Playback in feeds → Off**. This makes
  each click start a clean connection instead of racing the preview.
- **OpenCode account/model blank or provider timeouts**: OpenCode talks to
  Cloudflare. Cloudflare ECH uses a public name such as `cloudflare-ech.com`,
  which Flowseal's list handles with `hostfakesplit` in strategies like
  `general-alt9`; that can break the ECH handshake. Switch to
  `sudo zapret-arch use general` (`multisplit`). Adding only `opencode.ai` is
  not enough because the outer SNI is the ECH name. To keep `alt9`, add
  `cloudflare-ech.com` (and the `opencode.ai` domains) to
  `list-exclude-user.txt` instead: nfqws then leaves only the ECH connections
  alone and `alt9` still handles everything else.
- **Long "Проверка маршрута" / RTC Connecting**: `sudo zapret-arch games off`
  first, then `sudo zapret-arch voice off` if it is still slow. A voice call
  should then connect directly and quickly. If it is still slow with
  `sudo systemctl stop zapret-arch` active, the cause is outside the bypass:
  Discord desktop uses the system DNS (browser Secure DNS does not apply),
  IPv6 may be attempted on a network without a working IPv6 route, or the
  ISP's UDP path is poor. Clear Discord's `Cache`, `Code Cache` and `GPUCache`
  while it is closed, and prefer IPv4 if `curl -6 https://discord.com` fails.
- **Another nfqws is running**: the CLI refuses to start while a foreign
  `nfqws` owns the queue. Stop the old install first
  (`sudo systemctl stop zapret.service`), or reboot.
- **Existing zapret install**: if it is already running, the installer refuses
  to fight it (stop it first: `sudo systemctl stop zapret.service`). After a
  successful install it stops and disables `zapret.service` and
  `zapret_discord_youtube.service`; their unit files are untouched. Both use a
  different queue/table now, but only one should run.
- **After editing the system firewall**: a global `flush ruleset` or
  `systemctl restart nftables` removes the queue rules. The unit is
  `PartOf=nftables.service`, so restarting nftables also restarts
  zapret-arch and re-applies them; otherwise run
  `sudo zapret-arch use <current>`. `zapret-arch status` reports a missing
  queue rule.
- **IPv6-only network**: unsupported; this port sets `DISABLE_IPV6=1` to match
  Flowseal's IPv4 lists.
- **Updates**: `sudo zapret-arch update` (or `sudo arch-zapret update`)
  re-runs the installer that created this tree, preserving the selected
  strategy, game/voice/minecraft flags and user lists. If the source tree
  moved, pass its directory: `sudo zapret-arch update /path/to/zapret-arch`.
  The installer re-installs the same pinned Flowseal commit; to update
  strategies, bump `FLOWSEAL_REF` and `FLOWSEAL_SHA256` in `install.sh` and
  re-run it. The service is restarted if it was running.

## Uninstall

```bash
sudo ./uninstall.sh       # or: sudo PREFIX=/custom/prefix ./uninstall.sh
```

Stops the service, verifies its `nfqws` is gone, removes the unit and
`/usr/local/bin/zapret-arch`, and deletes the install prefix. The installed
copy of `uninstall.sh` derives its prefix from its own location. The older
`/opt/zapret` install is untouched.

## Security notes

- The engine tarball is pinned to `v72.13` and verified with SHA-256. The
  Flowseal archive is pinned to a commit and verified with SHA-256.
- Flowseal archives are rejected if they contain symlinks; files are copied
  with `--no-same-owner --no-same-permissions`.
- `.bat` files are parsed as text, never executed. Extracted tokens are
  validated against a safe character set; file-valued options that contain a
  path (both `--opt=path` and `--opt path`) may only point under `fakes/` or
  `lists/`, so a malicious strategy cannot make root read `/etc/shadow` or an
  SSH key. `nfqws --dry-run` must accept every profile.
- The generated config is built from verified profiles and written with
  `0644`; it contains no secrets.
- `nfqws` is started by the upstream init script and drops privileges to the
  `tpws` user; lists and payloads are world-readable by design.

## Limitations

- IPv4 only, nftables only, systemd only.
- `lists/ipset-all.txt` ships as a placeholder; the IP-based profile blocks
  match nothing until it is populated.
- Google/YouTube QUIC (UDP 443) is not carried by the shipped profiles; when
  the ISP drops QUIC, disable HTTP/3 in the browser. This is not fixable by
  switching strategies.
- Effectiveness depends on ISP, region and time; no strategy is permanent.
- This is DPI evasion, not a VPN or proxy. It does not unblock services that
  ban regions at the account level (for example Spotify), and it does not
  replace DNS.
- The built-in probe counts any HTTP response (including 404/403) as
  reachable; only a missing response/TLS failure counts as a failed endpoint.
  Use `zapret-arch probe` to see the exact code and latency per endpoint.
  Endpoints can also be rate-limited for reasons unrelated to DPI.

## Credits and license

Strategies and payloads: [Flowseal/zapret-discord-youtube](https://github.com/Flowseal/zapret-discord-youtube) (MIT).
Engine and init scripts: [bol-van/zapret](https://github.com/bol-van/zapret) (MIT).
This wrapper is MIT licensed; see `LICENSE`.
