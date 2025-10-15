%% -------- Meta & provenance ---------------------------------------------
clearvars -except HRES_DATA; clc;
global HRES_DATA
HRES_DATA = struct();
HRES_DATA.meta.created = datestr(now, 'yyyy-mm-dd HH:MM:SS');

% Provenance (for reproducibility / reporting)
HRES_DATA.meta.case_name   = 'DeGrussa copper-gold mine (WA) – diesel baseline';
HRES_DATA.meta.case_notes  = ['24/7 critical process load ~11–13 MW; diesel station provides ' ...
                              'spinning reserve and minimum generator loading constraints.'];

%% -------- Site scale & operating schemes --------------------------------
site = struct();
site.P_avg_MW     = 12.0;      % average electrical demand (MW)
site.peak_to_avg  = 1.10;      % peak ≈ 1.10 × average (constant-process mine)
% Derived (kW)
site.P_avg_kW  = site.P_avg_MW * 1000;
site.P_peak_kW = site.P_avg_kW * site.peak_to_avg;

% Dispatch scheme selector (integer in decision vector)
params = struct();
params.scheme_names = {'VRFB-first','AA-CAES-first','Balanced'};

%% -------- Horizon & reliability settings (Amusat et al.) ----------------
params.dt_hours        = 1.0;       % Δt (h)
params.hours_year      = 8760;      % steps per synthetic year
params.n_years         = 30;        % multi-annual variability

% Reliability is evaluated year-by-year (LPSP_m = fraction of failed years).
% Failure rule: exceed diesel-share target OR any unmet load in a year.
params.reliability_mode        = 'diesel_share';  % see reliability_metrics.m
params.unserved_tol_kWh        = 0;               % any unmet load fails the year
params.diesel_share_target     = 0.25;            % ≤25% of annual load from diesel (retrofit aim)
params.diesel_share_tol        = 0.00;            % no slack
params.diesel_hour_frac_target = 0.60;            % (used only in 'diesel_hours' mode)

% Scenario reproducibility & energy-mix accounting
params.scenario_seed               = 42;
params.metrics_energy_breakdown    = true;        % record mix for diesel-share calc

% (Optional) lightweight logging from HRES_objfun
params.log_interval     = 0;        % set >0 to enable periodic sampler records
params.log_max_records  = 200;

HRES_DATA.params = params;
HRES_DATA.site   = site;

%% -------- Microgrid operational constraints (DeGrussa-style) ------------
% Dynamic spinning reserve requirement: 1 MW + 85% of instantaneous PV output
params.spin_reserve = struct();
params.spin_reserve.enable     = true;
params.spin_reserve.base_kW    = 1000;   % constant component (kW)
params.spin_reserve.pv_coeff   = 0.85;   % multiplicative on PV_kW(t)

% Minimum diesel loading when online (site-level approximation)
% Note: dispatch_step supports diesel.diesel_min_on_kw (absolute kW).
% Use a site-linked constant as a coarse proxy (DG_P clamp is inside dispatcher).
diesel = struct();
diesel.diesel_min_on_kw = 0.50 * site.P_avg_kW;   % ≥50% of avg load when deficit>0

% Optional: enforce PV ramp/smoothing cap (leave numeric to simulator)
params.pv_smoothing = struct();
params.pv_smoothing.enable      = true;
params.pv_smoothing.max_ramp_kw_per_s = NaN;  % fill if you implement a ramp filter

HRES_DATA.diesel = diesel

%% -------- Technology parameters (dispatch & models) ---------------------
tech = struct();
% --- VRFB ---
tech.eta_vr_ch = 0.92;  tech.eta_vr_dis = 0.92;
tech.vr_parasitic_kw = 0.0;

% --- AA-CAES (include start-up lag per Amusat et al.) ---
tech.eta_aa_ch = 0.70;  tech.eta_aa_dis = 0.75;
tech.aa_parasitic_kw = 0.0;
tech.aa_startup_h = 0.25;   % 15 min start-up response (design-stage constraint)

% --- PV model ---
tech.pv_tilt_gain = 1.10; tech.pv_pr = 0.90; tech.pv_inverter_eff = 0.96;
tech.pv_temp_coeff_Pmp = -0.0045; tech.pv_NOCT_C = 45; tech.pv_T_amb_C = 25;

% --- Wind model ---
tech.wind_curve_k = 3; tech.wind_availability = 0.97; tech.wind_rho = 1.225;
tech.wind_cut_in = 3; tech.wind_rated_ms = 12; tech.wind_cut_out = 25;

HRES_DATA.tech = tech;

%% -------- Unit costs (AUD, still placeholders — update per vendor) ------
costs = struct();
costs.U_pv_kw     = 1200;  % $/kW PV (installed AC) – remote premium likely higher
costs.U_wt_kw     = 1700;  % $/kW Wind (installed)
costs.U_aa_e_kwh  = 45;    % $/kWh AA-CAES energy block
costs.U_aa_p_kw   = 320;   % $/kW  AA-CAES power block
costs.U_vr_e_kwh  = 260;   % $/kWh VRFB energy
costs.U_vr_p_kw   = 360;   % $/kW  VRFB power
costs.U_dg_kw     = 600;   % $/kW Diesel genset rating (CAPEX only)
HRES_DATA.costs = costs;

%% -------- Decision vector & bounds -------------------------------------
% x = [ PV_kW, WT_kW, AA_E_kWh, AA_P_kW, VR_E_kWh, VR_P_kW, DG_P_kW, scheme_idx ]
bounds = struct();
bounds.names = {'PV_kW','WT_kW','AA_E_kWh','AA_P_kW','VR_E_kWh','VR_P_kW','DG_P_kW','scheme_idx'};

% Lower bounds (keep a small diesel floor; avoid "zero-system")
lb_PV = 0; lb_WT = 0; lb_AA_E = 0; lb_AA_P = 0; lb_VR_E = 0; lb_VR_P = 0;
lb_DG = max(0.10*site.P_peak_kW, 1000);     % keep your robust floor
lb_scheme = 1;

% Upper bounds tied to site scale (allow high RE; diesel headroom for reserve)
ub_PV   = 1.6 * site.P_peak_kW;   % PV ≤ 160% of peak (PV curtail/ reserve will bind)
ub_WT   = 1.5 * site.P_peak_kW;   % Wind ≤ 150% of peak
ub_AA_P = 1.0 * site.P_peak_kW;   % AA-CAES power ≤ 100% of peak
ub_VR_P = 1.0 * site.P_peak_kW;   % VRFB power ≤ 100% of peak
ub_DG   = 1.6 * site.P_peak_kW;   % Diesel ≤ 160% of peak (gives room for reserve policy)

% Energy capacities as hours of coverage
ub_AA_E = 24 * site.P_avg_kW;     % AA-CAES up to ~24 h of average load
ub_VR_E =  6 * site.P_peak_kW;    % VRFB up to ~6 h of peak

bounds.lb = [lb_PV, lb_WT, lb_AA_E, lb_AA_P, lb_VR_E, lb_VR_P, lb_DG, lb_scheme];
bounds.ub = [ub_PV, ub_WT, ub_AA_E, ub_AA_P, ub_VR_E, ub_VR_P, ub_DG, 3];

% Hints for NGPM coding
bounds.vartype = [1 1 1 1 1 1 1 2];  % 1=real, 2=integer
bounds.nameVar = bounds.names;

HRES_DATA.bounds = bounds;

%% -------- Diesel (external energy) model flags --------------------------
diesel = struct();
diesel.max_ramp_kw = inf;     % not enforced in scaffold
diesel.efficiency  = 1.0;     % bookkeeping only (diesel energy = power*Δt)
HRES_DATA.diesel = diesel;
%% -------- Scenarios placeholder (filled by HRES_make_scenarios) ----------
HRES_DATA.scenarios = struct();

%% -------- Persist & confirm ---------------------------------------------
save('HRES_DATA.mat','HRES_DATA');
fprintf('[HRES_setup] Case: %s\n', HRES_DATA.meta.case_name);
fprintf('[HRES_setup] Site average %.1f MW, peak ~%.1f MW\n', site.P_avg_MW, site.P_peak_kW/1000);
fprintf('[HRES_setup] Reliability: %s (diesel_share≤%.2f; unserved=0 per year)\n', ...
        params.reliability_mode, params.diesel_share_target);
fprintf('[HRES_setup] DeGrussa-style reserve: base %g kW + %.0f%% of PV(t)\n', ...
        params.spin_reserve.base_kW, 100*params.spin_reserve.pv_coeff);
fprintf('[HRES_setup] AA-CAES start-up: %.2f h\n', tech.aa_startup_h);
fprintf('[HRES_setup] Bounds set relative to site scale. Next: run HRES_make_scenarios.m\n');

