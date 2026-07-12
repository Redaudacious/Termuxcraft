# Termuxcraft — Minecraft servers inside containers on an Android phone

Run one or more isolated Minecraft servers on an Android phone using **Termux**
(the host) and **proot-distro Debian containers** (the VMs). Each server lives in
its own lightweight VM with its own SSH, its own Playit agent, and its own world —
create them, manage them, expose them, and tear them all down from a single
command center.

- **Host (Level 1):** Termux. Runs the per‑VM "nanny", an optional Cloudflare
  tunnel for remote admin, and the `Termuxcraft` command center.
- **Container (Level 2):** an isolated Debian system running Minecraft, its own
  `sshd`, and its own Playit agent.

Everything is driven by shell commands you type directly: `Termuxcraft` opens the
global menu; each VM you create gets its own command (e.g. `mc1`) that opens a
focused menu for just that VM.

> **Target platform:** Android / Termux, `aarch64`. Default game version
> **1.21.11** (Java 21). The container ships **without Java on purpose** — the
> installer downloads the right JDK locally into the server folder.

---

## Table of contents

1. [Requirements](#1-requirements)
2. [Quick start](#2-quick-start)
3. [Architecture: two levels, two admin tiers](#3-architecture-two-levels-two-admin-tiers)
4. [How state is stored (`vm.conf` + `vm.env`)](#4-how-state-is-stored-vmconf--vmenv)
5. [The command system](#5-the-command-system)
6. [Installing a server: Fabric vs Paper](#6-installing-a-server-fabric-vs-paper)
7. [The EULA gate and how processes are supervised](#7-the-eula-gate-and-how-processes-are-supervised)
8. [SSH authentication (key / password / both)](#8-ssh-authentication-key--password--both)
9. [Connecting from your PC (Cloudflare or LAN)](#9-connecting-from-your-pc-cloudflare-or-lan)
10. [Cloudflare in depth](#10-cloudflare-in-depth)
11. [Playit.gg (the door your players use)](#11-playitgg-the-door-your-players-use)
12. [The server console](#12-the-server-console)
13. [Changing RAM and ports after creation](#13-changing-ram-and-ports-after-creation)
14. [Deleting a single VM](#14-deleting-a-single-vm)
15. [FULL RESET (wipe everything)](#15-full-reset-wipe-everything)
16. [File & directory layout](#16-file--directory-layout)
17. [Design notes & safety (why no `killall java`)](#17-design-notes--safety-why-no-killall-java)
18. [Troubleshooting](#18-troubleshooting)
19. [Command quick reference](#19-command-quick-reference)

---

## 1. Requirements

- An Android phone with **Termux** installed (from F‑Droid or the Play Store).
- A little storage headroom per VM (a Debian rootfs + Java + world).
- **Optional, for remote admin from anywhere:** a domain on **Cloudflare**.
- **Optional, for players to join over the internet:** a free **playit.gg**
  account.

The bootstrap step can install everything else for you:
`proot-distro tmux openssh wget cloudflared nano jq iproute2`.

---

## 2. Quick start

```bash
# 1) Clone the project somewhere in Termux, then enter it
git clone <your-repo-url> termuxcraft
cd termuxcraft

# 2) One-time setup: installs packages (optional) and the shell commands
bash bootstrap.sh

# 3) From now on, just type:
Termuxcraft            # (or: termuxcraft) — opens the global menu
```

In the menu choose **"Create a new VM"** (or run `bash install.sh`). You'll be
asked only for a name, an SSH port, a Minecraft port, and RAM. When it finishes,
that VM has its own command too.

```bash
# 4) Start the VM and install a server inside it (once)
mc1                    # opens the mc1 menu  ->  Power  ->  Start
proot-distro login mc1
bash ~/fabric-installer.sh     # Fabric + performance mods
   #  or:  bash ~/paper-installer.sh    # Paper + plugins
nano ~/server/eula.txt         # change eula=false  ->  eula=true   (REQUIRED)
```

Within ~10–20 seconds the nanny starts the server automatically. Set up remote
access from `mc1 -> SSH auth / Cloudflare` and you're done.

---

## 3. Architecture: two levels, two admin tiers

### The two levels (Matryoshka)

```
Phone (Termux, Level 1)
 ├─ Termuxcraft        the command center (this project)
 ├─ nanny.sh           one per VM: supervises the container's boot loop
 └─ cloudflared        optional tunnel for remote SSH administration
      └─ Debian container (Level 2)
           ├─ sshd            the VM's own SSH server
           ├─ playit agent    optional, for player traffic
           └─ Minecraft       Fabric or Paper, launched with Aikar's flags
```

A proot-distro container isolates the **filesystem and processes** but **not the
network** — every container shares the phone's network stack. That's why each VM
needs a **unique SSH port and a unique Minecraft port**; the installer and menus
enforce this automatically.

### The two admin tiers

The same rich per‑VM menu is reached from two entry points:

| Tier | Command | Scope |
|------|---------|-------|
| **Phone admin** | `Termuxcraft` / `termuxcraft` | Everything: create/delete VMs, manage all VMs, the phone's own SSH, the Cloudflare account & tunnels, install commands, full reset. |
| **VM admin** | `<vm-name>` (e.g. `mc1`) | Only that one VM: console, power, its SSH auth/keys, its Playit key, its RAM/ports, its Cloudflare hostname, and deleting it. No path to global settings or other VMs. |

> **Honest note on the boundary:** because everything runs as the same Termux
> user, the two tiers are a **user‑interface separation, not OS‑enforced
> isolation**. Anyone who can open a VM's console can still reach files on the
> phone. For a single‑owner phone this is exactly the convenience you want; real
> isolation would require separate Linux users and a restricted shell.

The VM‑admin tier is also **deliberately limited on Cloudflare**: it can create,
change, or remove **its own** SSH hostname, but **only if the phone already has a
tunnel**, and it **never restarts the shared tunnel** (that stays a phone‑admin
action). If no tunnel exists, the option simply tells the VM admin to ask the
phone admin.

---

## 4. How state is stored (`vm.conf` + `vm.env`)

There is **no central registry file**. Each VM is a self‑describing directory.

**Host side —** `~/.containers/<name>/vm.conf`:

```
NAME=mc1
ROOTFS=/data/.../proot-distro/installed-rootfs/mc1
SSH_PORT=8023
MC_PORT=25565
RAM=2G
```

Also in that directory: `nanny.sh` (the boot loop) and, once you print it, a
ready‑to‑paste `ssh-config-snippet.txt` for your PC.

**Container side —** `/root/vm.env` (read at runtime by the boot script and both
installers):

```
RAM=2G
MC_PORT=25565
SSH_PORT=8023
MC_VERSION=1.21.11
```

When you change RAM or a port from the menus, **both** files are updated so the
change survives a restart. Discovery is filesystem‑based: any directory under
`~/.containers/` that contains a `vm.conf` is a VM. Port‑conflict checks read the
`SSH_PORT`/`MC_PORT` of every VM plus the phone's own SSH port.

---

## 5. The command system

### How commands get installed

`bootstrap.sh` writes tiny wrapper scripts into `$PREFIX/bin` (which is on your
`PATH`):

- `Termuxcraft` and `termuxcraft` → open the global menu.
- one wrapper per VM (`mc1`, `mc2`, …) → open that VM's menu (`vmadmin` mode).

Every wrapper carries a marker comment so the project can find and remove exactly
its own commands and never touch a real binary. **Name‑collision protection** is
built in: at VM‑creation time a name is refused if it would shadow an existing
command (`git`, `top`, a shell builtin, a function, …) or the reserved
`Termuxcraft`/`termuxcraft`. If you ever move the project folder, re‑run
`bash bootstrap.sh` (or menu → *Install / repair shell commands*) to relink.

### Global menu (`Termuxcraft`)

```
 1) Start a VM
 2) Stop a VM
 3) Restart a VM
 4) Start ALL VMs
 5) Stop ALL VMs
 6) VM settings (console, auth, Cloudflare, playit, RAM, ports)
 7) Phone (Termux host) SSH
 8) Cloudflare tunnel & account
 9) Generate PC ~/.ssh/config (phone + all VMs)
10) Create a NEW VM
11) Install / repair shell commands (Termuxcraft + per-VM)
12) Delete a VM (rootfs + world + config)
13) FULL RESET — delete everything this project made
 0) Exit
```

### Per‑VM menu (`mc1`, and global menu → *VM settings*)

```
1) Server console (attach)
2) Power (start / stop / restart)
3) SSH auth (key / password / keys / root pw)
4) Cloudflare exposure & PC ~/.ssh/config
5) Playit.gg secret
6) Change RAM
7) Change ports (SSH / Minecraft)
8) Delete this VM
0) Back
```

### Phone (host) SSH menu

```
1) Start sshd
2) Stop sshd
3) Auth: key only
4) Auth: password only
5) Auth: key + password
6) Manage keys (add / remove / replace)
7) Set Termux password (passwd)
8) Cloudflare exposure & PC config
0) Back
```

### Cloudflare account & tunnel menu

```
1) Link / re-login this phone to Cloudflare
2) List tunnels + current SSH routes
3) Create a new tunnel
4) Select the active tunnel
5) Start tunnel
6) Stop tunnel
7) Create/refresh DNS records (fix 'already exists')
0) Back
```

### One‑shot commands (no menu)

Everything is also scriptable — see the [quick reference](#19-command-quick-reference).

---

## 6. Installing a server: Fabric vs Paper

Each VM ships with **two** installers in `/root`. Pick **one per VM** — Fabric
(mods) and Paper (plugins) must not share a server folder, and each installer
warns you if it detects the other.

Both read the target version from `/root/vm.env` (default **1.21.11**), download
**JDK 21** (Eclipse Temurin, `aarch64`) locally into `~/server/jdk`, and create
`eula.txt` (`=false`) plus a starter `server.properties`.

### `fabric-installer.sh` — Fabric + performance mods

Resolves the Fabric loader/installer from `meta.fabricmc.net`, downloads the
Fabric server jar, then pulls these mods from Modrinth (a mod with no build for
the target version is marked `[SKIP]` instead of failing):

`fabric-api`, `lithium`, `ferrite-core`, `krypton`, `c2me-fabric`, `chunky`,
`servercore`, `spark`, `noisium`, `scalablelux`, `modernfix`, `clumps`,
`alternate-current`.

You can edit the `MODS` list in `~/fabric-installer.sh` (Modrinth slugs).

### `paper-installer.sh` — Paper + a couple of plugins

Resolves the latest **default‑channel** Paper build from the PaperMC v2 API and
downloads it. Paper already bundles most of what Fabric's performance mods
provide, so it only adds what Paper doesn't:

- `chunky` — a chunk pre‑generator
- `spark` — a profiler

It also seeds `config/paper-global.yml` with
`misc.redstone-implementation: ALTERNATE_CURRENT` (faster redstone).

### After either installer

```bash
nano ~/server/eula.txt      # eula=false  ->  eula=true   (MANDATORY)
```

The nanny detects the change and launches the server automatically. The boot
script auto‑detects the jar: Fabric's launch jar first, then a `paper*.jar`, then
any `*.jar` in the folder.

**Bring your own world/mods** by dropping files into `~/server/` and
`~/server/mods/` (Fabric) or `~/server/plugins/` (Paper).

---

## 7. The EULA gate and how processes are supervised

- **`nanny.sh`** runs on the phone (in a tmux session named after the VM). It
  reads the VM's `vm.conf`, then loops: launch the container's
  `boot-container.sh`, and if it ever exits, wait 5 seconds and relaunch.
- **`boot-container.sh`** runs inside the container each boot. It writes DNS
  resolvers, starts `sshd`, starts the Playit agent **if** `~/.playit-secret`
  exists, then waits until (a) a Java binary and a server jar are present **and**
  (b) `eula=true`. Only then does it launch Minecraft in a tmux session named
  `mc-server` (with Aikar's tuned G1GC flags; a heavier flag set kicks in at
  ≥ 12 GB of heap).

**Key behavior:** SSH and Playit **always** start — even with no server installed
and no EULA — so you can always connect and configure. Only the **game launch**
waits for `eula=true`. This avoids a crash‑loop and lets boot retry calmly every
20 seconds.

---

## 8. SSH authentication (key / password / both)

There are two kinds of SSH endpoint, each configured independently:

- **The phone** (Termux `sshd`, port **8022**): config in
  `$PREFIX/etc/ssh/sshd_config`, keys in `~/.ssh/authorized_keys`.
- **Each VM** (`sshd` inside the container, your chosen port, default **8023**):
  config in `<rootfs>/etc/ssh/sshd_config.d/container.conf`, keys in
  `<rootfs>/root/.ssh/authorized_keys`.

Every VM ships **key‑only** by default (`PasswordAuthentication no`,
`PubkeyAuthentication yes`, `PermitRootLogin prohibit-password`). From the menus
you can switch any endpoint between three modes:

| Mode | Effect |
|------|--------|
| **key** | password off, pubkey on — add your PC's public key |
| **password** | password on, pubkey off — set a password |
| **both** | password and pubkey both on |

You can also **add / remove / replace** authorized keys, set a **VM root
password** (applied via `chpasswd`), or set the **Termux password** (`passwd`).
The menu shows the live, effective mode for each endpoint, derived from the config
plus whether any keys are present. Applying a change offers to **reload the
`sshd`** without dropping your current session.

> Even in key‑only mode you can always get a root shell into a VM from the phone
> with `proot-distro login <name>` — handy if you lock yourself out over SSH.

---

## 9. Connecting from your PC (Cloudflare or LAN)

The menus generate a ready‑to‑paste `~/.ssh/config` for your PC and save a copy
(per‑VM under `~/.containers/<name>/ssh-config-snippet.txt`, or the combined one
under `~/.containers/ssh-config-snippet.txt`). Two block styles are produced
automatically:

**Cloudflare** (when the endpoint has a hostname) — reachable from anywhere:

```
Host mc1
    HostName mc1.yourdomain.com
    User root
    ProxyCommand cloudflared access tcp --hostname %h
    IdentityFile ~/.ssh/YOUR_PRIVATE_KEY
```

**LAN** (no Cloudflare hostname) — phone and PC on the same Wi‑Fi. The phone's IP
is auto‑detected (with `<PHONE_LAN_IP>` as a fallback to fill in):

```
Host mc1
    HostName 192.168.1.50
    Port 8023
    User root
    IdentityFile ~/.ssh/YOUR_PRIVATE_KEY
```

For password‑auth endpoints the block omits `IdentityFile` and notes that SSH
will prompt for the password. Then it's just `ssh mc1` from your PC. (For
Cloudflare, make sure the tunnel is up first — global menu → *Cloudflare* →
*Start tunnel*.)

---

## 10. Cloudflare in depth

Cloudflare (with a domain you own and a **named tunnel**) gives your SSH a fixed
address like `mc1.yourdomain.com`, reachable without port forwarding. **One
tunnel serves many VMs** — each VM adds one ingress rule (hostname → local SSH
port) in `~/.cloudflared/config.yml`, plus one DNS record.

The hostname for a given port is derived from `config.yml` itself, so there's no
separate bookkeeping to drift out of sync.

**Phone‑admin actions** (global menu → *Cloudflare*): log in, list tunnels and
routes, create a tunnel, select the active tunnel, start/stop the tunnel process
(a tmux session named `cf`), and **create/refresh DNS records**. That last one is
the fix for Cloudflare's *"An A, AAAA, or CNAME record with that host already
exists"* (code 1003): it can pass `--overwrite-dns` to repoint a stale record at
the current tunnel.

**Per‑VM (VM‑admin) exposure** (a VM's menu → *Cloudflare*): create, change, or
remove **that VM's own** hostname, and print its PC config block — but only when a
tunnel already exists, and **without** restarting the shared tunnel. New/changed
routes take effect the next time the phone admin restarts the tunnel.

> Deleting a DNS record entirely isn't something `cloudflared` can do — remove
> leftover CNAMEs from the Cloudflare dashboard's DNS section if you stop using a
> hostname.

---

## 11. Playit.gg (the door your players use)

Playit.gg is a free reverse tunnel that makes your **game** server reachable from
the internet without opening router ports or exposing your home IP. The agent
runs inside the container and authenticates with a secret key stored at
`/root/.playit-secret`, used automatically at boot.

**Get a secret key:** playit.gg → *Setup / New Account Wizard* → choose *Docker*
(the method is identical under proot) → name the agent → copy the secret string.

**Add it to a VM:** the VM's menu → *Playit.gg secret* → paste the key. It offers
to restart the VM so the agent picks it up. Remove it the same way.

**Point players at the server:** playit.gg → *Tunnels* → *Add Tunnel* →
*Minecraft Java* → Local IP `127.0.0.1`, Local Port = your VM's Minecraft port
(e.g. `25565`). Players connect to the address playit gives you.

Flow: `Player → public playit address → playit → agent on your phone → local
Minecraft (127.0.0.1:<mc-port>)`.

---

## 12. The server console

From a VM's menu → **Server console (attach)**, or:

```bash
proot-distro login mc1 -- tmux attach -t mc-server
```

Inside the console: `Ctrl+B` then `D` to **detach** (leaves the server running),
or type `stop` to shut it down cleanly (saves the world). Standard server commands
like `list`, `say <msg>`, `op <player>` work as usual. If the console isn't there
yet, the server is still starting (watch the boot log with
`tmux attach -t mc1`) or has stopped.

---

## 13. Changing RAM and ports after creation

All from a VM's menu — no reinstall needed:

- **Change RAM** — updates `vm.conf` and `vm.env`; offers to restart the VM so the
  new heap takes effect. Accepts `2`, `4G`, `3072M`, … (a plain number means GB;
  minimum 512M).
- **Change SSH port** — updates `vm.conf`, `vm.env`, and the container's
  `sshd` drop‑in; re‑points the Cloudflare ingress if one exists; reloads the
  VM's `sshd` (keeping sessions). Regenerate your PC config afterward with
  `Termuxcraft ssh-config`.
- **Change Minecraft port** — updates `vm.conf`, `vm.env`, and
  `server.properties`; reminds you to update the port in your playit.gg dashboard
  if you use it.

Port changes are checked against every other VM and the phone's own SSH port.

---

## 14. Deleting a single VM

A VM's menu → **Delete this VM** (or `Termuxcraft delete <name>`). After a typed
confirmation it stops the VM, runs `proot-distro remove` (removing the rootfs and
world), strips its Cloudflare ingress, removes its shell command, and deletes its
`~/.containers/<name>` directory.

Two things it can't do for you: the **DNS record** may still exist in the
Cloudflare dashboard (delete it there if unused), and the VM's **playit tunnel**
should be removed from the playit.gg dashboard. Want a backup first? From the
phone: `proot-distro login <name> -- tar czf /root/backup-<name>.tgz -C /root
server`, then copy that file out.

---

## 15. FULL RESET (wipe everything)

Global menu → **FULL RESET** (or `Termuxcraft reset`). This returns the phone to a
clean state. It requires you to type `RESET`, then:

**Always removes:** stops every VM and the tunnel, `proot-distro remove` on each
VM, deletes `~/.containers`, removes all `Termuxcraft`/per‑VM shell commands, and
strips this project's ingress from `config.yml`.

**Then asks individually** (each is optional):

- **Log out of Cloudflare** — delete `~/.cloudflared` (cert + tunnel creds).
  *Tunnels and DNS records remain in the Cloudflare dashboard — remove them there.*
- **Reset the phone's SSH** — clear `~/.ssh/authorized_keys` and re‑enable
  password login.
- **Delete the project folder** — remove the clone itself so you can `git clone`
  fresh. This is the very last step and exits.

To set everything up again later, just `bash bootstrap.sh`.

---

## 16. File & directory layout

**In the repo:**

```
bootstrap.sh                 one-time: install shell commands (+ optional packages)
install.sh                   create one VM (also reachable from the menu)
commands.sh                  the command center (global + per-VM menus, CLI)
lib/
  config.sh                  global constants (ports, paths, versions, names)
  ui.sh                      prompts, colors, RAM/port validation, hidden input
  vm_helpers.sh              vm.conf / vm.env read-write, discovery, port checks
  cloudflare.sh              account, tunnels, ingress, DNS, zone detection
  ssh.sh                     auth modes, key management, PC ~/.ssh/config, LAN IP
  launcher.sh                install/remove the Termuxcraft + per-VM commands
templates/
  boot-container.sh          in-VM boot: sshd, playit, jar autodetect, Aikar flags
  nanny.sh                   host-side supervisor loop (reads vm.conf)
  sshd_container.conf        the VM sshd drop-in (key-only by default)
  fabric-installer.sh        Fabric + performance mods
  paper-installer.sh         Paper + Chunky/spark + alternate-current
  README.txt                 the in-VM tutorial copied to each container
```

**On the phone at runtime:**

```
~/.containers/<name>/vm.conf                 host-side VM state
~/.containers/<name>/nanny.sh                the boot loop for this VM
~/.containers/<name>/ssh-config-snippet.txt  saved PC config block (per VM)
~/.containers/ssh-config-snippet.txt         saved PC config (phone + all VMs)
~/.cloudflared/config.yml                    tunnel + ingress rules
$PREFIX/bin/Termuxcraft, termuxcraft, <name> the shell-command wrappers
```

**Inside a container:**

```
/root/vm.env                          runtime config (RAM, ports, MC_VERSION)
/root/boot-container.sh               boot script the nanny runs
/root/fabric-installer.sh             Fabric installer
/root/paper-installer.sh              Paper installer
/root/README.txt                      in-VM tutorial
/root/.playit-secret                  playit key (if set)
/root/server/                         world + config
/root/server/jdk/bin/java             the local Java used at startup
/root/server/mods/  or  /plugins/     Fabric mods / Paper plugins
/root/server/eula.txt                 must contain eula=true
/root/server/server.properties        port, motd, etc.
```

---

## 17. Design notes & safety (why no `killall java`)

A proot-distro container **shares the host's PID namespace**. Naïvely running
`killall java` from one container would kill **every** VM's Java. This project
avoids that everywhere:

- **Stopping a VM** sends `stop` to its `mc-server` console, waits `SAVE_WAIT`
  (6s) for the world to save, kills the **host** nanny session, then runs
  `proot-distro login <name> -- tmux kill-server`. proot-distro gives each
  container its **own** tmux server, so this ends only that VM's Java.
- **The phone's `sshd`** is stopped via its pidfile (with a clearly‑labeled
  `pkill` fallback), never by a blind name match that could also hit a
  container's `sshd`.
- **A VM's `sshd`** is reloaded by `HUP`‑ing the exact pid it wrote to
  `/run/sshd.pid` inside the container — so a port/auth change rebinds the
  listener **without dropping your current session**.
- **Host `sshd` detection** uses a port check (`ss -tln`) instead of `pgrep -x
  sshd`, which would false‑positive on containers' `sshd` processes.

`commands.sh` also deliberately avoids `set -e`, so one failing sub‑command (say,
a VM missing its `nanny.sh`) never crashes the whole menu.

---

## 18. Troubleshooting

- **`Termuxcraft: command not found`** — run `bash bootstrap.sh` once (it installs
  the command). If you moved the folder, run it again.
- **A VM won't take a name** — it collides with an existing command or is
  reserved; pick another. (This is on purpose, to avoid shadowing real binaries.)
- **Server never starts** — check the EULA (`nano ~/server/eula.txt` →
  `eula=true`), or watch the boot log: `tmux attach -t <name>`. The boot script
  prints exactly what it's waiting for (missing jar/Java vs EULA).
- **A mod shows `[SKIP]`** — no build exists for the target version yet; the rest
  still install.
- **Cloudflare says the DNS record already exists** — global menu → *Cloudflare* →
  *Create/refresh DNS records* and accept overwrite.
- **A new Cloudflare hostname doesn't connect** — give DNS a minute and make sure
  the tunnel is running; a VM‑admin change needs the phone admin to restart the
  tunnel.
- **Garbled characters in the console** — the container already ships
  `~/.tmux.conf` with `set -g mouse on`; re‑create it if needed.
- **See everything at a glance** — `Termuxcraft list`.

---

## 19. Command quick reference

Run these as `Termuxcraft <cmd>` (or `bash commands.sh <cmd>`):

```text
# VMs
list                     show all VMs + running state + tunnel state
start   <name>           start one VM
stop    <name>           stop one VM cleanly (saves the world first)
restart <name>           stop then start one VM
start-all | stop-all     every VM at once
create  (alias: new)     create a NEW VM (runs install.sh)
delete  <name>           permanently delete a VM
vm      [name]           per-VM settings menu (phone-admin tier)
vmadmin <name>           per-VM menu (VM-admin tier; what '<name>' runs)
console <name>           attach to the server console

# Phone host SSH
phone                    phone (Termux host) SSH menu

# Cloudflare
cf         (alias: tunnel)   start the tunnel (+ host SSH if needed)
cf-stop                      stop the tunnel
cloudflare (alias: account)  Cloudflare account & tunnel menu
login                        link this phone to Cloudflare
new-tunnel                   create a new named tunnel
select-tunnel                choose the active tunnel
routes     (alias: tunnels)  list tunnels + current SSH routes
dns                          (re)create DNS records (+ overwrite)

# Connections & maintenance
ssh-config               print/save the PC ~/.ssh/config (phone + all VMs)
link                     install / repair the shell commands
reset      (alias: nuke) FULL RESET — delete everything this project made
```

Per‑VM commands run the VM‑admin menu directly:

```bash
mc1          # opens the mc1 menu (console, power, auth, Cloudflare, playit, RAM, ports, delete)
```

---

*This project turns a phone into a small, tidy Minecraft host. Create a VM, pick
Fabric or Paper, accept the EULA, expose it over Cloudflare or LAN — and tear it
all down just as cleanly when you're done.*
