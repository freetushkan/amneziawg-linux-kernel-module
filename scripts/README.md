# deploy.sh

Builds and installs the module with DKMS for every installed kernel that has
headers. The DKMS version is `1.0.0+g<commit>`, so `dkms status` shows what is
built, updates need no `--force`, and older versions are removed once the new
one is in place.

First install (Debian, Ubuntu, Proxmox): installs git, build tools, DKMS and the
headers for the running kernel and its flavor, removes the packaged
`amneziawg`/`amneziawg-dkms`, clones into `/usr/src/amneziawg-linux-kernel-module`:

    curl -fsSL https://raw.githubusercontent.com/freetushkan/amneziawg-linux-kernel-module/master/scripts/deploy.sh | bash -s -- install

Update to the latest commit of the branch the checkout is on:

    /usr/src/amneziawg-linux-kernel-module/scripts/deploy.sh update

Switch the module now instead of at the next reboot. Every amneziawg interface
comes back the way it was brought up: `awg-quick@` units are restarted, configs
in `/etc/amnezia/amneziawg` go through `awg-quick down`/`up`, and interfaces set
up by hand or by other tools are saved (awg settings, addresses, MTU, routes in
all tables) and recreated; rules and firewall rules refer to them by name and
stay. The reload runs detached (`systemd-run`, or `setsid`), so an SSH session
through one of the tunnels freezes for a few seconds but the reload finishes
even if the session drops (log: `/run/amneziawg-reload/log` while it runs):

    /usr/src/amneziawg-linux-kernel-module/scripts/deploy.sh update --reload

Other commands and options:

    deploy.sh status                  checkout, DKMS builds, per-kernel modules, loaded build
    deploy.sh uninstall               remove every DKMS version (the checkout is kept)
    --ref BRANCH|TAG|COMMIT           what to build (default: current branch, or master)
    --repo URL                        where to clone from
    --dir DIR                         where the checkout lives
    --compat 0|1|2                    persist the 'compat' module parameter
    --no-deps                         do not touch packages

Kernels without headers are skipped with a warning; `update` fetches headers
for the running kernel if they are missing. With Secure Boot, DKMS signs the
module with its MOK key, which has to be enrolled once (`mokutil --import`).
