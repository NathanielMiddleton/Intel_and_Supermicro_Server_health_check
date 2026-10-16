# smc_ipmi_health.sh

Hardware health check for Supermicro servers, run from inside the OS. It is the in-band counterpart of
`hpe_ilorest_health.sh`: same flags, same exit codes, same "grep the report for the verdict" design, but it
talks to the BMC with `ipmitool` instead of Redfish and adds disk, RAID and GPU checks from local tools.

bash + coreutils/grep/sed/awk only. No jq, no Python, no vendor agents.

## What it checks

| Section | Source | What is flagged |
|---|---|---|
| System | `dmidecode`, `ipmitool fru/chassis/mc` | chassis fault flags (power, fan, drive), intrusion, BMC self-test |
| Processors | `dmidecode -t processor` + `CPUn Temp` sensor | socket not `Populated, Enabled` |
| Memory | `dmidecode -t 17`, EDAC sysfs | per-controller and per-DIMM CE/UE counters (inventory lines carry no verdict) |
| Temperatures, Fans, Voltages, Other | `ipmitool sdr elist` (one call) | status `nc` → WARNING, `cr`/`nr` → CRITICAL; discrete readings matched against keyword lists |
| Power | `PSn Status` sensors, `ipmitool dcmi power reading`, `ipmicfg -pminfo` | PSU failure / AC lost, PMBus status not OK, fewer PSUs than `MIN_PSUS` |
| Storage | `/proc/mdstat`, `zpool`, `storcli64`/`perccli64`, `smartctl --scan-open` | degraded/rebuilding arrays, VD/PD states, media and predictive-failure counts, SMART health, NVMe wear/spare/critical warning, ATA reallocated/pending/offline sectors and SSD life, SAS grown defects and uncorrected errors |
| GPUs | `lspci`, `nvidia-smi`, kernel log | GPUs missing from the driver, volatile ECC UE/CE, row-remap failure/pending, retired pages, PCIe width degradation, hw/thermal/power-brake slowdown, temperature, reset required, fabric state, infoROM corruption, NVLink error counters, Xids per bus id |
| SEL | `ipmitool sel elist last N`, `sel info`, `sel time get` | asserted events in the look-back window matched against keyword lists, log ≥ 90 % full or overflowed, BMC clock off by more than a day |
| Kernel log | `journalctl -k` (fallback `dmesg -T`) | MCE/EDAC hardware errors, disk I/O errors, PCIe AER errors |

Each tool is optional except `ipmitool`; a missing tool just drops that part of the report (and says so).

## Requirements

- Root: `/dev/ipmi0`, `dmidecode`, `smartctl` and the kernel journal all need it.
- `ipmitool` and the `ipmi_si`/`ipmi_devintf` kernel modules (the script tries `modprobe` itself).
- Optional: `dmidecode`, `smartmontools`, `pciutils`, `storcli64` or `perccli64`, Supermicro `ipmicfg`,
  `zfsutils`, the NVIDIA driver (`nvidia-smi`).
- bash 4.x or newer, GNU `date`, `timeout`, `awk`.

## Usage

```
smc_ipmi_health.sh [-q] [-d DAYS] [-n N]

  -q        only print what is not OK; prints nothing at all when healthy
  -d DAYS   look-back window for the SEL and the kernel log (default 7)
  -n N      scan only the newest N SEL entries (default 500; 0 = whole SEL, slow over KCS)
```

Environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `IPMITOOL_OPTS` | empty | extra `ipmitool` arguments, e.g. `-I open`, or `-H bmc -U admin -f pwfile` to query the BMC out of band |
| `DIMM_CE_WARN` | `1` | WARNING when EDAC corrected errors reach this count (0 disables) |
| `GPU_CE_WARN` | `100` | WARNING when a GPU's volatile corrected ECC count reaches this (0 disables) |
| `GPU_TEMP_WARN` | `90` | WARNING at or above this GPU core temperature in °C (0 disables) |
| `MIN_FANS` | `0` | WARNING when fewer fans report a reading (0 disables) |
| `MIN_PSUS` | `0` | WARNING when fewer PSUs report `Presence detected` (0 disables) |

Exit codes follow the Nagios convention: `0` OK, `1` WARNING, `2` CRITICAL, `3` UNKNOWN (BMC unreachable,
or a check could not run and nothing worse was found).

## Output

Every item line ends in `: OK`, `: WARNING`, `: CRITICAL` or `: ERROR`, with the reasons in brackets just
before the verdict. The `Summary:` line gives the worst verdict per section (`n/a` means nothing in that
section produced a verdict, e.g. memory without EDAC loaded). The final `RESULT:` line and the exit code are
derived from the same text, so what you see is exactly what was judged.

```
Summary: system OK, processors OK, memory OK, temperatures OK, fans CRITICAL, power CRITICAL, voltages OK, ...
System: Supermicro SYS-1029U-TN10RT SN S1234..., board X11DPU SN ZM18..., BIOS 3.4 11/19/2020
  power on, chassis fault flags none: OK
  intrusion inactive: OK
  BMC Supermicro firmware 1.73, selftest passed: OK
Fans: 7 reporting
  FAN1 6300 RPM: OK
  FAN3 0 RPM: CRITICAL
Power: 312 Watts in use, 2 PSU present
  PS2 Status Presence detected, Failure detected, Power Supply AC lost: CRITICAL
Storage:
  raid c0 vd 1/1 RAID5 7.276 TB data Dgrd [Dgrd]: CRITICAL
  /dev/nvme0 SAMSUNG MZQL23T8HCLS SN S64H... 36C: PASSED, life 97%, spare 100%, media errors 0, critical warning 0x00: OK
GPUs: 3 NVIDIA, 0 AMD on the PCI bus
  driver 535.129.03, 2 of 3 GPUs answer nvidia-smi [1 GPU(s) not visible to the driver (fallen off the bus?)]: CRITICAL
  GPU1 NVIDIA A100-PCIE-40GB SN ... D8:00.0: 52C/48C hbm, 61/250W, ..., pcie gen1/4 x8/x16 [pcie x8 of x16, xid 31(x2)]: WARNING
  GPU at 0000:af:00: not visible to the driver, xid 79(x1): CRITICAL
RESULT: CRITICAL
```

With `-q` the output is just `hostname VERDICT` followed by the offending lines, which makes it cron-mail friendly:

```
# every hour, mail only when something is wrong
0 * * * * root /usr/local/sbin/smc_ipmi_health.sh -q
```

As a Nagios/Icinga/check_mk local check, run it without `-q` and let the plugin framework keep the long output.

## How the verdicts are decided

- **Sensors**: the `sdr elist` status column decides for threshold sensors (`nc` warning, `cr`/`nr` critical).
  Discrete sensors (PSU status, drive slots, intrusion) keep status `ok` even when they report a fault, so
  their reading text is matched against `S_CRIT` and `S_WARN` at the top of the script. Sensors with status
  `ns` (no reading) are dropped: that is how Supermicro reports empty fan headers and DIMM slots.
- **SEL**: only `Asserted` events inside the window count (a `Deasserted` means it recovered). Events are
  classified by `SEL_CRIT`/`SEL_WARN`; anything else is informational and only counted. `Pre-Init` entries
  (logged before the BMC had a clock) are skipped. The first 20 flagged events are printed.
- **GPUs**: hardware-class Xids (`XID_CRIT`: 48, 64, 74, 79, 94, 95, 119, 120, 140) are CRITICAL, any other Xid
  is WARNING. Volatile (since boot) ECC counters are judged; lifetime aggregates are shown but not judged.
  Fields the installed driver does not support are shown as `-` and skipped.
- **Disks**: SMART overall health FAILED is CRITICAL. Reallocated/pending/offline-uncorrectable sectors,
  grown defects, media errors, ≤ 10 % SSD life or NVMe `Percentage Used` ≥ 90 % are WARNING. NVMe
  `Critical Warning != 0x00` or spare below threshold is CRITICAL.
- **Precedence** everywhere: CRITICAL > WARNING > ERROR > OK.

All keyword lists and thresholds sit together at the top of the script; adjusting them is the expected first
step after the first run on a new platform.

## Known gaps and caveats

- Written against stubbed tool output, not against a lab of Supermicro boxes. Expect a tuning pass on
  real output, especially the SEL event wording, which varies between X9/X10/X11/X12/X13 firmware.
- Sensor and locator naming is assumed to be the usual Supermicro scheme (`PS1 Status`, `Presence detected`,
  `CPU1 Temp`, `P1-DIMMA1`). Boards that deviate still get checked, but a few cross-references (CPU temp on
  the CPU line, PSU presence count) will come out empty.
- A fan or PSU that was present and is now gone cannot be detected from the SDR alone; use `MIN_FANS` and
  `MIN_PSUS` for that.
- EDAC per-DIMM counters are reported with the EDAC label (`CPU_SrcID#0_MC#0_Chan#0_DIMM#0`), not the
  `P1-DIMMA1` locator; mapping between the two is platform specific and is not attempted.
- AMD GPUs are counted but not inspected. NVIDIA GPUs in MIG mode are fine. Checks that need a newer
  driver (row remapping, `clocks_event_reasons`, fabric/reset status) degrade silently on old ones.
- Broadcom HBAs in IR mode (`sas3ircu`), Intel VROC and Adaptec controllers are not parsed; disks behind them
  still show up through `smartctl` if the driver exposes them.
- Kernel-log pattern matching counts lines, not events; a chatty AER source can inflate the counts.
  Corrected AER errors are shown but never raise the verdict.
- Timings: `sdr elist` and `sel elist` go over the slow KCS interface and take a few seconds each; the whole
  SEL (`-n 0`) on a full log can take a minute or more. `smartctl` is run once per disk.

## Files

- `smc_ipmi_health.sh` — the check
- `README.md` — this file
