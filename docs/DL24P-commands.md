# DL24P command survey

What is known about the commands of one ATORCH DL24P with a CH340 USB serial port (`1a86:7523`, 9600 8N1) and Bluetooth peripheral `DL24-BLE`. Other DL24 hardware differs: newer boards use USB HID and a different protocol.

**This list is not proven complete.** It covers every command code with all-zero values on the protocols below, but most non-zero values are untested, and the firmware was not read.

## Confirmed working

`B1 B2 cmd d1 d2 B6`:

| Code | Purpose |
|---|---|
| `01` | Load: `01 00` on, `00 00` off |
| `02` | Set current: `d1` whole amps, `d2` hundredths |
| `03` | Set cutoff: `d1` whole volts, `d2` hundredths |
| `04` | Set timer: seconds, big-endian |
| `10`–`19` | Query load, mV, mA, run time, mAh, mWh, temperature, set current, cutoff, timer |

Writes are acknowledged with `6F`. Queries reply `CA CB d1 d2 d3 CE CF`.

`FF 55 11 02 cmd 00 00 00 00 checksum`, where the checksum is the sum of bytes 2 to 8, masked to 8 bits, XOR `44`:

| Code | Purpose |
|---|---|
| `01`, `02`, `03`, `05` | Reset Wh, Ah, time, all |
| `31`, `32`, `33`, `34` | Panel buttons Setup, OK, plus, minus |

Replies are `FF 55 02 01 s 00 00 checksum`, where `s` is 1 for OK, 2 for failed and 3 for unsupported.

## Tested with no effect

| Test | Result |
|---|---|
| `FF 55`, device type `02`, all other codes, zero values | Replied unsupported. Includes `21` backlight and `22` price |
| `B1 B2`, all other codes, zero values | No reply and no readable change |
| `B1 B2 06 00 01 B6`, the DL24M's "set CV" | No reply, panel stayed in CC |
| 9-byte `B1 B2 cmd 00 00 00 00 00 B6` reads `17`, `21`, `32`–`3C` | No reply, including the control `17` |

Not tested: `B1 B2 05` (published as reset counters), `FF 55` device types `01` and `03`, and most non-zero values.

The panel's CC, CV, CR and CP mode, its calibration and its menu settings could not be read or set over the link. DL-X Control runs CP, CR and CC-CV by adjusting the current from the computer.

## Do not send

On the closely related DL24M, in its 9-byte format, these codes are documented by [labbridge](https://github.com/nobodypb/labbridge) as changing calibration or settings with no way to restore them: `46`, `4B`, `4F`. Its handbook also marks `07`, `08`, `51` and `52` as uncertain. The scan above sent the zero-value 6-byte forms of these codes with no visible effect, but calibration values cannot be read over the link.

## Other projects

Further protocol notes, especially for HID boards, are in [tshaddack/dl24](https://github.com/tshaddack/dl24), [syssi/esphome-atorch-dl24](https://github.com/syssi/esphome-atorch-dl24), [misdoro/Electronic_load_px100](https://github.com/misdoro/Electronic_load_px100), [sophusand/atorch-dl24p-python](https://github.com/sophusand/atorch-dl24p-python) and [RobThree/LibAtorch](https://github.com/RobThree/LibAtorch).
