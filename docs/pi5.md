# Raspberry Pi 5 support

The Pi 5 needed more than the Pi 4 did, and none of it was driver work. This is
the whole account: what works, what does not, what the image does differently
for that board, and how to recognise it when it goes wrong.

The requirement side is [requirements.md](requirements.md) §8; the decision and
its rationale are in [design-decisions.md](design-decisions.md). This file is
the detail both of those point at.

## What works, and what does not

Which of these currently hold on hardware is tracked in
[CLAUDE.md](../CLAUDE.md#status); the gap list is
[requirements.md](requirements.md) §8. Neither is repeated here — this file is
the mechanism, and three copies of a status list is three things to drift.

Worth stating here because it is a consequence of *this* change rather than an
upstream gap: **wireless does not work on a Pi 5.** Under the upstream device
tree the second MMC controller does not come up —
`sdhci-brcmstb 1001100000.mmc: error -EINVAL: invalid resource` — so
`brcmfmac` has nothing to bind to. The `PI_WIFI_*` keys in `pi-core.conf` are
Pi 4 only.

**Pi 500 and the CM5 variants are not covered.** The kernel ships upstream
device trees only for the two Pi 5 Model B steppings, so those boards keep the
downstream tree and keep the RP1 fault below. They boot to a login prompt with
no ethernet and no USB.

## The two faults

Both were found on hardware, and both are device-tree problems rather than
anything missing from the image.

### 1. `rp1_pci` would not bind, so there was no ethernet and no USB

```
rp1_pci 0002:01:00.0: Missing of_node for device
rp1_pci 0002:01:00.0: probe with driver rp1_pci failed with error -22
```

RP1 is the Pi 5's southbridge: ethernet and USB both hang off it. The chip
enumerates fine on PCIe (`1de4:0001`, link up 5.0 GT/s x4) — the driver refuses
it for want of a device-tree node.

`rp1_pci` binds against a DT description of RP1's children. The **firmware's**
`bcm2712*` trees do not carry one: no `clk_rp1_xosc`, no `pci-ep-bus`. The
**kernel's** trees for the same boards carry both. The image therefore replaces
the firmware's with the kernel's.

This is the Pi 5 shape of something Fedora already does for the Pi 4, where
`config.txt` carries `[pi4] dtoverlay=upstream-pi4` — *"Allow usage of
downstream .dtb with upstream kernel on Pi 4"*. There is no `upstream-pi5`
overlay to do the same job, which is why the trees are swapped wholesale.

On a headless board this fault is indistinguishable from a machine that never
booted: it reaches a login prompt, but nothing can reach it and a USB keyboard
is dead because the USB controller is.

### 2. `vc4-drm` probe-looped the board to death

```
vc4-drm axi:gpu: bound 107c580000.hvs (ops vc4_hvs_ops [vc4])
input: vc4-hdmi-0 as .../rc/rc0/input11589
vc4_hdmi 107c701400.hdmi: Could not register PCM component: -517
systemd-logind[1006]: Failed to open /dev/input/event0: No such device
```

`vc4_hdmi` cannot register its PCM component, returns `-EPROBE_DEFER` forever,
and the driver binds, registers an input device, fails, unbinds and retries.
Measured: **11,587 cycles in 400 seconds**, with `systemd-logind` chasing a new
input device each time.

The board never panics — it drowns. That is what blanks HDMI and silences the
activity LED a few seconds after login, and it is why the failure reads as a
crash when it is really saturation.

The trigger is `[pi5] dtoverlay=vc4-kms-v3d-pi5,cma-256` in Fedora's stock
`config.txt`. The image comments it out. A headless server has no use for KMS,
and downstream overlays would not apply cleanly to an upstream tree anyway.

## What the image does

`build_files/build.sh` overwrites the stashed firmware device trees with the
kernel's, **under the firmware's own filenames**, and disables the `[pi5]`
display overlay.

| firmware filename | stepping | replaced with (from the kernel) |
|---|---|---|
| `bcm2712-rpi-5-b.dtb` | C0 | `bcm2712-rpi-5-b.dtb` |
| `bcm2712d0-rpi-5-b.dtb` | D0 | `bcm2712-d-rpi-5-b.dtb` |
| `bcm2712-d-rpi-5-b.dtb` | D0 | `bcm2712-d-rpi-5-b.dtb` |

The Pi 4 tree is deliberately untouched, and tier 1 fails if it is ever
replaced too.

### Why not `device_tree=` in `config.txt`

Because the firmware picks the device tree **by board revision**, and that is
what gets the silicon stepping right. Forcing `device_tree=<file>` overrides
that selection, and `config.txt` has no conditional for the stepping — so no
single filename can serve both C0 and D0 boards. Replacing the files under
their existing names keeps the firmware's own selection working.

Tier 1 asserts that `device_tree=` does **not** appear in the shipped
`config.txt`, because reintroducing it brings the stepping bug back.

## The stepping trap

**`bcm2712-rpi-5-b.dtb` is C0 silicon. `bcm2712d0-rpi-5-b.dtb` is D0. A Pi 5
Rev 1.1 is D0.** The kernel's two upstream trees are `bcm2712-rpi-5-b.dtb` (C0)
and `bcm2712-d-rpi-5-b.dtb` (D0) — filenames that differ by one letter for a
difference that is fatal.

Giving D0 silicon the C0 tree does not degrade gracefully. `gpio_keys` probes
the power button, pinctrl writes a pull-config register at the C0 offset, the
write faults, and the board dies about three seconds in:

```
SError Interrupt on CPU0, code 0x00000000be000011
Kernel panic - not syncing: Asynchronous SError Interrupt
pc : brcmstb_pull_config_set+0x64/0xe8
  brcmstb_pinconf_set -> pinconf_apply_setting -> pinctrl_commit_state
  -> pinctrl_bind_pins -> really_probe -> gpio_keys_init [gpio_keys]
```

If you see that backtrace, the device tree does not match the silicon. Check
the tree's `compatible` strings rather than its filename:

```bash
# on the ESP, or on any copy of the tree
grep -ao 'bcm2712[cd]0-pinctrl' bcm2712d0-rpi-5-b.dtb | sort -u   # bcm2712d0-pinctrl
grep -ac 'clk_rp1_xosc'        bcm2712d0-rpi-5-b.dtb            # 1, not 0
```

`build.sh` does exactly those two greps before copying each tree, and fails the
build rather than shipping a mismatch.

## Diagnosing on hardware

```bash
# did RP1 bind?  "enabling device" = yes, "Missing of_node" = no
sudo dmesg | grep rp1_pci

# ethernet and USB, both behind RP1
ip -br addr show
ls /sys/bus/usb/devices/          # expect usb1..usb4

# is the display driver looping?  expect 0
sudo dmesg | grep -c "Could not register PCM component"

# which tree is actually live — this path only exists on the upstream one
ls /proc/device-tree/axi/pcie@1000120000/pci@0,0
```

If the board panics before any of that, the panic screen's QR code carries the
backtrace; nothing will be on the card, because journald's default
`SyncIntervalSec` is five minutes and a board that dies in seconds never syncs.

## What it costs

The ESP now carries **kernel** artifacts. A kernel bump therefore makes the
ESP and the image diverge, where previously the stash only moved when a
firmware package did.

The existing machinery handles it — `pi-core-firmware-check.service` reports
the drift at boot and `sudo pi-core-firmware sync` applies it — but it now
fires far more often. Reconciliation stays manual for the same reason it always
was: a bad firmware write bricks the boot and there is no rollback for it.

One consequence worth stating plainly: **after a kernel update, a Pi 5 keeps
booting the device tree already on its ESP** until you sync. That is usually
harmless, and is the safe default, but it means the tree and the kernel can be
a release apart.

And one trap in the other direction: **`sync` deliberately keeps an existing
`config.txt`**, so it will write the new device trees but leave an old, active
`dtoverlay=vc4-kms-v3d-pi5` line in place — upstream tree, downstream overlay,
straight back into the probe loop. A card flashed before this change therefore
cannot be repaired by `sync` alone; it needs a reflash, or a `sync` *followed
by* commenting that line out by hand on the ESP. Commenting it out on its own
is not a repair either — the card would still be carrying the firmware's
device trees, so RP1 would stay unbound.
