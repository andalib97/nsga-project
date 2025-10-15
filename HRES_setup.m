%% HRES_setup.m  (rev B)
% Shared parameter setup for a typical Australian remote mine microgrid.
% Run this FIRST.

clearvars -except HRES_DATA; clc;
global HRES_DATA
HRES_DATA = struct();
HRES_DATA.meta.created = datestr(now, 'yyyy-mm-dd HH:MM:SS');

%% -------- Site scale & operating schemes --------------------------------
site = struct();
site.P_avg_MW    = 10.0;      % avg electrical demand (MW)
site.peak_to_avg = 1.4;       % peak ≈ 1.4 × average (tune if you have data)

% Derived (kW)
site.P_avg_kW  = site.P_avg_MW * 1000;
site.P_peak_kW = site.P_avg_kW * site.peak_to_avg;

% Dispatch scheme selector (integer in decision vector)
params = struct();
params.scheme_names = {'VRFB-first','AA-CAES-first','Balanced'};

%% -------- Horizon & reliability settings --------------------------------
params.dt_hours   = 1.0;        % Δt (h)
params.hours_year = 8760;       % steps in a synthetic year
params.n_years    = 30;         % >=30 so LPSP_m isn’t binary

% Reliability per the papers: evaluate each full year as a “trial”.
% Use a PRACTICAL rule that prevents “zero system” from passing:
params.reliability_mode     = 'either';  % fail if unmet load > 0 OR diesel share > target
params.unserved_tol_kWh     = 0;         % any unmet load fails the year
params.diesel_share_target  = 0.35;      % ≤35% of annual load from diesel (tune for study)
params.diesel_share_tol     = 0.00;      % optional slack band on the share
params.diesel_hour_frac_target = 0.60;   % (used only in 'diesel_hours' mode)

params.reliability_store_timeseries = false; % set true only when debugging

% Scenario reproducibility & downstream metrics
params.scenario_seed            = 42;    % HRES_make_scenarios should NOT clone years
params.metrics_energy_breakdown = true;  % let simulate_hres tally yearly energy flows

HRES_DATA.params = params;
HRES_DATA.site   = site;

%% -------- Unit costs (AUD, placeholders—replace with your AU values) ----
costs = struct();
costs.U_pv_kw    = 1200;   % $/kW PV (installed AC)
costs.U_wt_kw    = 1700;   % $/kW Wind (installed)
costs.U_aa_e_kwh = 45;     % $/kWh AA-CAES energy block (effective)
costs.U_aa_p_kw  = 320;    % $/kW  AA-CAES power block
costs.U_vr_e_kwh = 260;    % $/kWh VRFB energy
costs.U_vr_p_kw  = 360;    % $/kW  VRFB power
costs.U_dg_kw    = 600;    % $/kW  Diesel genset rating (CAPEX only)
HRES_DATA.costs  = costs;

%% -------- Technology parameters (dispatch & models) ---------------------
tech = struct();

% --- VRFB ---
tech.eta_vr_ch       = 0.92;
tech.eta_vr_dis      = 0.92;
tech.vr_parasitic_kw = 0.0;

% --- AA-CAES (effective lumped store; TES can be split later) ---
tech.eta_aa_ch       = 0.70;
tech.eta_aa_dis      = 0.75;
tech.aa_parasitic_kw = 0.0;
tech.aa_startup_h    = 0.0;   % set >0 to enforce start-up lag in dispatch_step

% --- PV model (rev B) ---
tech.pv_tilt_gain      = 1.10;     % POA ≈ tilt_gain * GHI
tech.pv_pr             = 0.90;     % DC performance ratio
tech.pv_inverter_eff   = 0.96;     % DC→AC efficiency
tech.pv_temp_coeff_Pmp = -0.0045;  % 1/°C
tech.pv_NOCT_C         = 45;       % °C
tech.pv_T_amb_C        = 25;       % °C (constant; swap for T_amb(t) if available)

% --- Wind model (rev B) ---
tech.wind_curve_k      = 3;        % ramp exponent
tech.wind_availability = 0.97;     % uptime
tech.wind_rho          = 1.225;    % kg/m^3

% OEM-style curve points
tech.wind_cut_in   = 3;            % m/s
tech.wind_rated_ms = 12;           % m/s
tech.wind_cut_out  = 25;           % m/s

HRES_DATA.tech = tech;

%% -------- Diesel (external energy) model flags --------------------------
diesel = struct();
diesel.max_ramp_kw = inf;     % not enforced in scaffold
diesel.efficiency  = 1.0;     % bookkeeping only (diesel energy = power*Δt)
HRES_DATA.diesel = diesel;

%% -------- Decision vector & bounds -------------------------------------
% Decision vector order:
%   x = [ PV_kW, WT_kW,  AA_E_kWh, AA_P_kW,  VR_E_kWh, VR_P_kW,  DG_P_kW,  scheme_idx ]
bounds = struct();
bounds.names = {'PV_kW','WT_kW','AA_E_kWh','AA_P_kW','VR_E_kWh','VR_P_kW','DG_P_kW','scheme_idx'};

% Lower bounds (set a SMALL >0 diesel so CC can’t be zero and “no-system” can’t pass)
lb_PV = 0;  lb_WT = 0;
lb_AA_E = 0; lb_AA_P = 0;
lb_VR_E = 0; lb_VR_P = 0;
lb_DG   = max(0.10*site.P_peak_kW, 1000);  % ≥10% peak or ≥1 MW (tune to site reality)
lb_scheme = 1;

% Upper bounds tied to site peak
ub_PV   = 1.5 * site.P_peak_kW;   % PV ≤ 150% of peak
ub_WT   = 1.5 * site.P_peak_kW;   % Wind ≤ 150% of peak
ub_AA_P = 1.0 * site.P_peak_kW;   % AA-CAES power ≤ 100% of peak
ub_VR_P = 1.0 * site.P_peak_kW;   % VRFB power ≤ 100% of peak
ub_DG   = 1.2 * site.P_peak_kW;   % Diesel ≤ 120% of peak

% Energy capacities (hours of coverage)
ub_AA_E = 24  * site.P_avg_kW;    % AA-CAES up to ~24 h of average load
ub_VR_E = 6   * site.P_peak_kW;   % VRFB up to ~6 h of peak

bounds.lb = [lb_PV, lb_WT, lb_AA_E, lb_AA_P, lb_VR_E, lb_VR_P, lb_DG, lb_scheme];
bounds.ub = [ub_PV, ub_WT, ub_AA_E, ub_AA_P, ub_VR_E, ub_VR_P, ub_DG, 3];

% Hints for the driver (NGPM): coding & labels
bounds.vartype = [1 1 1 1 1 1 1 2]; % 1=real, 2=integer (scheme)
bounds.nameVar = bounds.names;

HRES_DATA.bounds = bounds;

%% -------- Scenarios placeholder (filled by HRES_make_scenarios) ----------
HRES_DATA.scenarios = struct();

%% -------- Persist & confirm ---------------------------------------------
save('HRES_DATA.mat','HRES_DATA');
fprintf('[HRES_setup] Site average %.1f MW, peak ~%.1f MW\n', site.P_avg_MW, site.P_peak_kW/1000);
fprintf('[HRES_setup] Reliability: %s (diesel_share≤%.2f OR unserved=0)\n', ...
    params.reliability_mode, params.diesel_share_target);
fprintf('[HRES_setup] Bounds set relative to site scale. Next: run HRES_make_scenarios.m\n');
