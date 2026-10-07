# Hardware baseline — MacBook Pro 16" M4 Max (Mac16,5), macOS 26.6

Tags: **[M]** measured on this machine (experiment ID, date). **[?]** external source, unverified.
Raw outputs are in `docs/data/`. Procedure: `docs/m0-test-plan.md`.

## AlDente (E0)

## SMC inventory (E1)

- [M] E1 2026-10-07: 3386 keys (`docs/data/smc-keys-m4max.txt`). All reads unprivileged except a few keys
  (e.g. `CH0J`, `CHLS`) that return `notPrivileged` without root.
- [M] **Byte order: SMC integers are little-endian on this machine**, not big-endian. Evidence: `B0AC [si16] 27 FD`
  = 0xFD27 = −729 mA against `fwprobe battery` −741 mA; `B0AV 5E 2C` = 11358 mV against 11374 mV; `B0AT DF 0B` =
  3039 = 30.39 °C against 30.39 °C; `B0CT 90 00` = 144 cycles. Exception: `#KEY [ui32] 00 00 0D 3A` is big-endian
  (3386). `flt ` is little-endian. `SMCValue.number` currently decodes ui16/ui32/si16 as big-endian — wrong for
  these keys; fix in M1. Writes are raw bytes and unaffected.
- [M] Charge control candidates: `CHTE [ui32] 4B 00 00 00 00`; `CHIE [hex_] 1B 00`; `CH0B`, `CH0C` absent;
  `CH0J` exists (needs root to read). `ACLC [ui8] 04` (MagSafe LED candidate, not in scope). `BCLM`, `CHWA` absent.
- [M] Fans: `FNum` 2; `F0Md`/`F1Md [ui8] 03` at rest; `Ftst [ui8] 00`; `F0Tg`/`F1Tg [flt ] 0.0`;
  `F0Mn`/`F1Mn` 1350 RPM; `F0Mx`/`F1Mx` 5777 RPM; `F0Ac`/`F1Ac` 0.0 at idle (fans stopped).
- [M] Battery temperature keys: `TB0T`, `TB1T`, `TB2T [flt ]` ≈ 30.6–30.7 °C, matching AppleSmartBattery 30.39 °C.

## Charge inhibit (E2)
## Adapter inhibit (E3)
## Fans (E4)
## Temperatures (E5)
## IOReport power and clocks (E6)
## Power modes (E7)
## FPS (E8)
## Open questions
