# Windows Server 2025 - Hetzner Automated Installer

Fully automated Windows Server 2025 deployment for Hetzner dedicated servers. **No SCP or file uploads needed** — users only need PuTTY SSH and a single command.

---

## One-Liner Install (PuTTY Users)

SSH into your Hetzner rescue system and run **one command**:

```bash
wget -qO- https://raw.githubusercontent.com/LeilaSchooley/hetznerWindowsOSinstaller/main/install.sh | bash
```

That's it. Everything is downloaded and executed automatically.

### With Custom Password

```bash
wget -qO- https://raw.githubusercontent.com/LeilaSchooley/hetznerWindowsOSinstaller/main/install.sh | bash -s -- --password "YourPass123!"
```

### Force Full Reinstall / Clear Resume State

```bash
wget -qO- https://raw.githubusercontent.com/LeilaSchooley/hetznerWindowsOSinstaller/main/install.sh | bash -s -- --force
```

### Optional Telegram / Discord Notify (on success, before reboot)

```bash
wget -qO- https://raw.githubusercontent.com/LeilaSchooley/hetznerWindowsOSinstaller/main/install.sh | bash -s -- \
  --telegram-token "BOT_TOKEN" --telegram-chat "CHAT_ID"

# or
wget -qO- https://raw.githubusercontent.com/LeilaSchooley/hetznerWindowsOSinstaller/main/install.sh | bash -s -- \
  --discord-webhook "https://discord.com/api/webhooks/..."
```

### Check Version

```bash
wget -qO- https://raw.githubusercontent.com/LeilaSchooley/hetznerWindowsOSinstaller/main/install-windows.sh | bash -s -- --version
```

### Interactive Wizard (Recommended for First-Time Users)

```bash
wget -O /root/install.sh https://raw.githubusercontent.com/LeilaSchooley/hetznerWindowsOSinstaller/main/install.sh
bash /root/install.sh --interactive
```

Interactive mode requires a real terminal and cannot be launched through a piped one-liner. The two-step command above walks you through IP, gateway, disk selection, and password step by step.

---

## How It Works (User Perspective)

```
1. Go to Hetzner Robot → Activate Rescue Mode → Reboot
2. Open PuTTY → Connect to your server IP with rescue credentials
3. Paste the one-liner command above
4. Wait 15-30 minutes
5. Connect via RDP to your server IP on port 3389
```

No files to download to your PC. No SCP. No uploads. Just one SSH command.

---

## Features

- **Zero-Upload Workflow** — Everything downloads directly on the server, no SCP needed
- **Official Microsoft ISO** — Downloads directly from Microsoft's evaluation center
- **Hetzner ISO Mirror Fallback** — Retries from Hetzner's hosted Windows ISO mirror if the Microsoft CDN fails
- **Interactive Wizard** — Step-by-step guided setup via `--interactive` flag
- **Fully Automated** — ISO download, partitioning, image extraction, boot setup
- **Hetzner Network Ready** — Auto-configures /32 point-to-point routing, static IP, Hetzner DNS
- **UEFI + Legacy BIOS** — Auto-detects boot mode and configures accordingly
- **Two-Disk Workflow** — Uses one disk for Windows and one disk for workspace/downloads
- **Stable disk IDs** — Resume stores `/dev/disk/by-id` so `sda`/`sdb` letter swaps cannot retarget disks
- **Equal-size guard** — Refuses ambiguous auto-select when top disks are the same size
- **VirtIO boot-start** — Registers `viostor`/`vioscsi` in the offline SYSTEM hive (Cloud-safe)
- **UEFI preferred / Legacy guaranteed** — Auto-uses UEFI when firmware is EFI; on Legacy Cloud, installs GRUB `ntldr` on **both** instance + Volume disks so BIOS disk-0 order cannot miss Windows
- **Legacy preflight** — Requires `grub-install` + `hivexsh` before wiping disks; verifies bootmgr/BCD/GRUB/MBR before reboot
- **RDP Pre-configured** — Remote Desktop enabled and firewall rules applied on first boot
- **Built-in Network Repair** — `C:\fix-network.cmd` auto-placed on Windows drive for KVM use
- **Unattended Install** — Full OOBE bypass, auto-login for setup, and post-install hardening
- **Self-healing deps** — apt with retries, Debian `.deb` fallback, then wimlib source build
- **Resume support** — state file + log; skips workspace wipe / WIM apply when safe (`--force` to reset)
- **Pre-flight checks** — RAM, disks, network/DNS, Cloud vs Dedicated detection
- **Optional notify** — Telegram / Discord message with RDP credentials on success

## File Structure

| File | Where | Purpose |
|---|---|---|
| `install.sh` | Cloud (GitHub/your hosting) | Bootstrap one-liner — downloads & launches installer |
| `install-windows.sh` | Cloud (GitHub/your hosting) | Main installer — fully self-contained, does everything |
| `fix-network.cmd` | Auto-generated on `C:\` | Network repair tool — run from KVM if RDP fails |
| `README.md` | Cloud (GitHub/your hosting) | This documentation |
| `details.txt` | Local only | Your server connection details (not uploaded) |
| `quick-start.sh` | Optional/local | Pre-configured launcher for a specific server |

## Prerequisites

1. **Hetzner dedicated server** in rescue mode (Linux 64-bit)
2. **PuTTY or any SSH client** (just SSH — no SCP, no file transfers)
3. **2 physical drives** — 1 for Windows, 1 for temp workspace/downloads
4. **Target disk**: at least 40 GB
5. **Work disk**: at least 8 GB free for ISO + temp files
6. **Minimum 4GB RAM**

---

## Hosting Setup (For Maintainers)

### Option 1: GitHub (Recommended)

1. Create a GitHub repo (for example, `hetznerWindowsOSinstaller`)
2. Upload `install.sh` and `install-windows.sh`
3. Update `INSTALLER_API_URL` and `INSTALLER_RAW_URL` in `install.sh`:
   ```
   https://api.github.com/repos/<owner>/<repo>/contents/install-windows.sh?ref=main
   https://raw.githubusercontent.com/<owner>/<repo>/main/install-windows.sh
   ```
4. Users run: `wget -qO- https://raw.githubusercontent.com/LeilaSchooley/hetznerWindowsOSinstaller/main/install.sh | bash`

### Option 2: Any Web Server

Upload both files to any HTTPS server and update the URL in `install.sh`.

### Option 3: Cloudflare Workers / R2

Great for fast global delivery. Upload files and use the worker URL.

---

## Advanced Usage

```bash
# Download and run directly (no bootstrap)
wget -O /root/install-windows.sh https://raw.githubusercontent.com/LeilaSchooley/hetznerWindowsOSinstaller/main/install-windows.sh
bash /root/install-windows.sh

# Full manual control (disks auto-picked by size if omitted)
bash install-windows.sh \
  --password "YourSecurePass123!" \
  --uefi \
  --confirm

# Custom ISO
bash install-windows.sh --iso-url "https://example.com/your-windows.iso"

# Use Hetzner's hosted Windows ISO directly
bash install-windows.sh --iso-url "https://download.hetzner.com/bootimages/windows/SW_DVD9_Win_Server_STD_CORE_2025_24H2_64Bit_English_DC_STD_MLF_X23-81891.ISO"

# Interactive wizard
bash install-windows.sh --interactive

# Safe validation only (no disk changes)
bash install-windows.sh --dry-run
```

### Hetzner Cloud notes

- Attach a **Volume** as workspace (ISO download). The installer picks the **largest** disk for Windows and the **second-largest** for work — never by `sda`/`sdb` letter order.
- VirtIO storage + network drivers are injected and registered boot-start on KVM/Cloud (`viostor` + `NetKVM` required).
- **UEFI preferred** in Cloud Console when available. If rescue shows Legacy/CSM, the installer auto-enables the guaranteed GRUB→`bootmgr` path (no `--bios` flag needed) and also puts GRUB on the Volume so firmware disk-0 still finds Windows.
- If the two largest disks are the same size, pass `--target-disk` / `--work-disk` (prefer `/dev/disk/by-id/...`).

### Command-Line Options

| Option | Description | Default |
|---|---|---|
| `--ip <IP>` | Server IPv4 address | Auto-detected from rescue env |
| `--gateway <GW>` | Gateway address | Auto-detected |
| `--password <PASS>` | Administrator password | Auto-generated (16 char) |
| `--iso-url <URL>` | Windows ISO download URL | Built-in URL |
| `--target-disk <DEV>` | Disk for Windows install | Largest disk |
| `--work-disk <DEV>` | Disk for temp workspace | Second-largest disk |
| `--skip-confirm` | Skip all confirmation prompts | On when stdin is not a TTY |
| `--confirm` | Require typing `yes` before wiping disks | Off |
| `--uefi` | Force UEFI boot mode | Auto-detect |
| `--bios` | Force Legacy BIOS boot mode | Auto-detect |
| `--interactive`, `-i` | Interactive wizard | Off |
| `--dry-run` | Validate detection and config only | Off |
| `--force`, `--clean` | Clear resume state and force full wipe/reinstall | Off |
| `--version` | Print installer version and exit | — |
| `--telegram-token` | Telegram bot token (or `TELEGRAM_BOT_TOKEN`) | Off |
| `--telegram-chat` | Telegram chat id (or `TELEGRAM_CHAT_ID`) | Off |
| `--discord-webhook` | Discord webhook URL (or `DISCORD_WEBHOOK_URL`) | Off |

---

## What Happens Under the Hood

1. **Bootstrap** (`install.sh`) downloads the main installer to `/root/` and launches it
2. **Detection** — Identifies disks, boot mode (UEFI/BIOS), network config, and gateway
3. **Workspace** — Formats the secondary disk as temp workspace for ISO download
4. **Download** — Downloads Windows Server 2025 ISO and VirtIO drivers (required on Cloud)
5. **Partitioning** — Creates proper partition layout on the target disk:
   - UEFI: EFI (512MB) + MSR (16MB) + Windows (rest)
   - BIOS: System Reserved (500MB) + Windows (rest)
6. **Extraction** — Applies Standard Desktop WIM image via wimlib (robust index selection)
7. **Configuration** — Injects:
   - VirtIO storage/network drivers for KVM/Cloud
   - `unattend.xml` — Fully unattended Windows setup
   - `setup-network.cmd` — Hetzner /32 network config (runs on first boot)
   - `post-install.cmd` — RDP, firewall, power plan, optimization
   - `fix-network.cmd` — Network repair tool (for KVM console use)
8. **Boot Setup** — Configures bootloader (UEFI boot entry or MBR boot code)
9. **Reboot** — Server boots into Windows Setup, runs fully unattended

## Hetzner Network Configuration

Hetzner uses a unique /32 point-to-point routing setup:

- **Subnet mask**: 255.255.255.255 (/32)
- **Gateway**: Requires a host route before default route works
- **DNS**: 185.12.64.1, 185.12.64.2
- **Routing**: `route add <gateway>/32` then `route add 0.0.0.0/0 via <gateway>`

All handled automatically. If network fails post-install, open KVM console and run `C:\fix-network.cmd`.

---

## Troubleshooting

### Can't connect via RDP after install
- Wait 10-15 minutes for Windows Setup to complete
- Use KVM console to check progress
- Run `C:\fix-network.cmd` from KVM console if network is misconfigured

### Interactive install fails immediately
- `--interactive` must be run from a real terminal, not through `wget ... | bash`
- Download `install.sh` first, then run `bash /root/install.sh --interactive`

### Windows stuck at "Getting ready"
- Normal for first boot — can take 10-15 minutes

### Boot failure (0xc000000f) after install
This means the BCD boot configuration has stale device references. Fix via KVM:
1. Mount the Windows Server ISO in Hetzner KVM virtual media
2. Boot from the ISO → **Repair your computer** → **Command Prompt**
3. Run:
   ```bat
   diskpart
   list vol
   ```
4. Identify the EFI partition (small FAT32) and the Windows partition (large NTFS)
5. Assign drive letters and rebuild:
   ```bat
   select volume <EFI_VOL>
   assign letter=S
   select volume <WIN_VOL>
   assign letter=C
   exit
   bcdboot C:\Windows /s S: /f UEFI
   ```
6. Detach the ISO and reboot

### Only one disk available
- This version does not support single-disk installs safely
- Add a second disk before running the installer

---

## Security Notes

- Admin password stored in `/root/windows-credentials.txt` (chmod 600) in rescue system
- Change the password after first login
- Consider hardening RDP (change port, enable NLA)
- 180-day evaluation period starts from first boot

## License

Repository code is MIT-licensed. Windows Server media and activation remain subject to Microsoft's evaluation and licensing terms; a production deployment requires a valid Windows Server license.
