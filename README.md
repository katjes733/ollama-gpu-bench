# ollama-gpu-bench

A PowerShell script for benchmarking [Ollama](https://ollama.com) token generation speed alongside GPU power/clock/thermal telemetry, so you can compare MSI Afterburner overclocking profiles on a **tokens/sec-per-watt** basis instead of raw speed alone.

## Requirements

- Windows PowerShell, with a local [Ollama](https://ollama.com) instance running and the model you want to test already pulled
- `nvidia-smi` on `PATH` (NVIDIA driver install)
- [MSI Afterburner](https://www.msi.com/Landing/afterburner/graphics-cards) running, if you want core/mem clock offsets read automatically (see below)

## Usage

Short benchmark — a handful of fixed-length bursts, averaged:

```powershell
.\ollama-gpu-bench.ps1 -Model "llama3:8b" -ProfileLabel "Ollama-Efficient" -Runs 3
```

Soak test — one continuous run for a set duration, to validate a profile is stable for hours of unattended use (a short burst can pass cleanly and still fail later under sustained load):

```powershell
.\ollama-gpu-bench.ps1 -Model "llama3:8b" -ProfileLabel "Gaming-OC" -SoakMode -SoakDurationMinutes 120
```

Run `Get-Help .\ollama-gpu-bench.ps1 -Full` for the complete parameter list.

### Reasoning models

Models with a "thinking" phase (e.g. Qwen3) can spend most or all of a low `-NumPredict` budget on hidden reasoning before writing anything to the actual response, which the script will (correctly) flag as `EMPTY_OUTPUT`. If you're benchmarking one of these, raise `-NumPredict` to a few thousand so there's room for both the reasoning and a real answer.

## What gets recorded

Each run captures:

- **Speed**: tokens/sec, tokens/sec-per-watt
- **Power/OC**: power limit (read from `nvidia-smi`), core/mem clock offsets (read live from Afterburner's own profile file), temp limit and curve-edited status (passed manually via `-TempLimitC` / `-CurveEdited`, since neither is exposed by any API)
- **Telemetry**: average/peak watts, SM/mem clock, temperature
- **Stability**: crashes, timeouts, and output corruption (garbled/repeated/truncated text)

Results append to `ollama-gpu-bench-log.csv` (short-burst mode) or `ollama-gpu-bench-soak-log.csv` (soak mode) so you can build a comparison table across profiles over time. Any run with a corrupted response dumps the raw output to `ollama-bench-suspect-output_<profile>_*.txt` for inspection.
