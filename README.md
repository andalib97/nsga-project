# HRES NSGA-II (VRFB + AA-CAES) for Australian Remote Mines

This repo contains MATLAB scripts to size a hybrid renewable energy system (PV, Wind, AA-CAES, VRFB, Diesel backup) using NSGA-II (NGPM). Objectives: (1) Capital Cost, (2) Reliability (LPSP_m), with explicit tracking/minimization of diesel reliance over years.

## Repo Structure
- `HRES_setup.m` – site/tech parameters, bounds.
- `HRES_make_scenarios.m` – synthetic AU mine solar/wind/load series.
- `pv_model.m`, `wind_model.m` – generation models.
- `dispatch_step.m` – per-step dispatch (VRFB/AA-CAES/diesel).
- `simulate_hres.m` – yearly simulation + energy accounting.
- `reliability_metrics.m` – computes LPSP_m over multiple years.
- `economics.m` – CAPEX objective.
- `HRES_objfun.m` – wraps objectives for NGPM.
- `TP_run_nsga.m` – optimizer driver, Pareto, filters, knee pick.
- `HRES_energy_mix_years.m` – post-process energy mix across years.

## Requirements
- MATLAB (R2021a+ recommended). Statistics toolbox **not required**.
- NGPM (NSGA-II) on MATLAB path: `nsgaopt.m`, `nsga2.m`, etc.

## Quick Start
1. Ensure NGPM is on path.
2. Run `HRES_setup` then `HRES_make_scenarios`.
3. Optionally sanity check: `HRES_objfun((bounds.lb+bounds.ub)/2)`.
4. Run `TP_run_nsga`.
5. Post-process knee design: `HRES_energy_mix_years(design,true)`.

## Outputs
- Pareto figure(s)
- `NSGA_result_w_knee_*.mat`
- Energy mix PNG + CSV per knee design

## Notes
- Diesel is allowed as backup; reliability metric can be `diesel_share`, `unserved`, or `either` (see `HRES_setup` and `reliability_metrics`).
- Site load and resource parameters approximate remote Australian mines and can be swapped for real data when available.

## License
MIT

## Citation / References
- Core methodology follows “Optimal design of hybrid energy systems incorporating stochastic renewable resources fluctuations”, 
  “Optimal integrated energy systems design incorporating variable renewable energy sources”, 
  and “On the design of complex energy systems: Accounting for renewables variability in systems sizing”.
