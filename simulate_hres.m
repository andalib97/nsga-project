function sim = simulate_hres(design, params, tech, diesel, sc, opts)
% SIMULATE_HRES (rev C)  Per-year simulation for one scenario, with optional
% energy-mix accounting for diesel-reduction analysis.
%
% Inputs/Outputs: same as rev B. Key differences:
%  - No cloned constants in fallback path (parasitics always defined)
%  - Start-up gating hook: pass previous-step storage activity to dispatcher
%  - Optionally bridge tech.aa_startup_h to dispatcher (if present)
%  - NaN/Inf guards and minor sanitization

% -------------------- Defaults & checks --------------------
if nargin < 6, opts = struct(); end
opts.store_timeseries  = getf(opts,'store_timeseries',false);
opts.vr_soc0           = getf(opts,'vr_soc0',0.5);
opts.aa_soc0           = getf(opts,'aa_soc0',0.5);
if ~isfield(opts,'metrics_energy')
    if isfield(params,'metrics_energy_breakdown') && ~isempty(params.metrics_energy_breakdown)
        opts.metrics_energy = logical(params.metrics_energy_breakdown);
    else
        opts.metrics_energy = false;
    end
end

H  = params.hours_year;
dt = params.dt_hours;

if numel(sc.GHI) ~= H || numel(sc.WS) ~= H || numel(sc.LOAD) ~= H
    error('simulate_hres: scenario vectors must be length H = %d', H);
end
if design.VR_E < 0 || design.AA_E < 0
    error('simulate_hres: storage energy capacities must be nonnegative.');
end

% -------------------- Pre-allocate --------------------
store_ts = logical(opts.store_timeseries);
if store_ts
    P_pv     = zeros(H,1);
    P_wt     = zeros(H,1);
    P_diesel = zeros(H,1);
    P_unmet  = zeros(H,1);
end
E_vr = zeros(H+1,1);
E_aa = zeros(H+1,1);

% Initial SOCs
E_vr(1) = max(0, min(design.VR_E, opts.vr_soc0 * design.VR_E));
E_aa(1) = max(0, min(design.AA_E, opts.aa_soc0 * design.AA_E));

% Totals
E_diesel_total    = 0;   % kWh
E_unserved_total  = 0;   % kWh
diesel_used_hours = 0;

% Always define constant parasitics for fallback math
P_parasitics_const = 0;
if isfield(tech,'vr_parasitic_kw'), P_parasitics_const = P_parasitics_const + max(0,tech.vr_parasitic_kw); end
if isfield(tech,'aa_parasitic_kw'), P_parasitics_const = P_parasitics_const + max(0,tech.aa_parasitic_kw); end

% Optional energy-mix accumulator
if opts.metrics_energy
    acc = struct('E_pv',0,'E_wt',0,'E_load',0,'E_curt',0, ...
                 'E_vr_dis',0,'E_aa_dis',0,'E_vr_ch',0,'E_aa_ch',0, ...
                 'E_RE_direct',0);
end

% Start-up gating: previous-step storage activity flag (papers' c_{t-1})
c_prev_any = true; % default "ready" at t=1 so no artificial block on the first step

% Bridge tech.aa_startup_h to dispatcher if it expects it in diesel struct
if isstruct(tech) && isfield(tech,'aa_startup_h') && ~isempty(tech.aa_startup_h)
    diesel.aa_startup_h = tech.aa_startup_h;
end

% -------------------- Main hourly loop --------------------
for t = 1:H
    % Renewable generation models (kW)
    Ppv   = max(0, pv_model(sc.GHI(t), design.PV_kW, tech));
    Pwt   = max(0, wind_model(sc.WS(t), design.WT_kW, tech));
    Pgen  = Ppv + Pwt;
    Pload = max(0, sc.LOAD(t));

    % One-timestep dispatch (rev C supports flags; pass activity gating)
    flags = struct('c_prev_any', c_prev_any);  % minimal gating (previous step)
    try
        [E_vr(t+1), E_aa(t+1), Pdg, unmet, flows] = dispatch_step( ...
            Pgen, Pload, ...
            E_vr(t), design.VR_E, design.VR_P, tech.eta_vr_ch, tech.eta_vr_dis, getf(tech,'vr_parasitic_kw',0), ...
            E_aa(t), design.AA_E, design.AA_P, tech.eta_aa_ch, tech.eta_aa_dis, getf(tech,'aa_parasitic_kw',0), ...
            design.DG_P, diesel, design.scheme, dt, flags);
    catch
        % Fallback: old dispatcher without flows (approximate energy splits)
        [E_vr(t+1), E_aa(t+1), Pdg, unmet] = dispatch_step( ...
            Pgen, Pload, ...
            E_vr(t), design.VR_E, design.VR_P, tech.eta_vr_ch, tech.eta_vr_dis, getf(tech,'vr_parasitic_kw',0), ...
            E_aa(t), design.AA_E, design.AA_P, tech.eta_aa_ch, tech.eta_aa_dis, getf(tech,'aa_parasitic_kw',0), ...
            design.DG_P, diesel, design.scheme, dt);
        P_net_gen = max(0, Pgen - P_parasitics_const);
        flows = struct();
        flows.P_ren_to_load = min(P_net_gen, Pload);
        flows.P_vr_ch = 0; flows.P_vr_dis = 0;
        flows.P_aa_ch = 0; flows.P_aa_dis = 0;
        flows.P_curtail = max(0, P_net_gen - Pload);
        flows.P_diesel = Pdg;
        flows.P_gen_net = P_net_gen;
        flows.c_active  = false;
    end

    % Update next-step gating flag from this step’s activity
    c_prev_any = logical(getf(flows,'c_active', (flows.P_vr_dis>0)||(flows.P_aa_dis>0)));

    % Tally energy
    E_diesel_total   = E_diesel_total   + Pdg   * dt;
    E_unserved_total = E_unserved_total + unmet * dt;
    if Pdg > 0, diesel_used_hours = diesel_used_hours + 1; end

    % Store time series if requested
    if store_ts
        P_pv(t)     = Ppv;
        P_wt(t)     = Pwt;
        P_diesel(t) = Pdg;
        P_unmet(t)  = unmet;
    end

    % ----- Energy-mix accounting (optional) -----
    if opts.metrics_energy
        acc.E_pv        = acc.E_pv        + Ppv                   * dt;
        acc.E_wt        = acc.E_wt        + Pwt                   * dt;
        acc.E_load      = acc.E_load      + Pload                 * dt;
        acc.E_curt      = acc.E_curt      + max(0,flows.P_curtail)* dt;

        acc.E_vr_dis    = acc.E_vr_dis    + flows.P_vr_dis        * dt;
        acc.E_aa_dis    = acc.E_aa_dis    + flows.P_aa_dis        * dt;
        acc.E_vr_ch     = acc.E_vr_ch     + flows.P_vr_ch         * dt;
        acc.E_aa_ch     = acc.E_aa_ch     + flows.P_aa_ch         * dt;

        acc.E_RE_direct = acc.E_RE_direct + flows.P_ren_to_load   * dt;
    end
end

% -------------------- Summaries --------------------
E_load_total = sum(sc.LOAD(:)) * dt;  % kWh
served_frac  = 1 - (E_unserved_total / max(E_load_total, eps));
diesel_hour_frac = diesel_used_hours / H;

sim.E_diesel_kWh     = E_diesel_total;
sim.E_unserved_kWh   = E_unserved_total;
sim.diesel_hour_frac = diesel_hour_frac;
sim.served_frac      = served_frac;

if store_ts
    sim.P_pv     = P_pv;
    sim.P_wt     = P_wt;
    sim.P_diesel = P_diesel;
    sim.P_unmet  = P_unmet;
    sim.E_vr     = E_vr;
    sim.E_aa     = E_aa;
end

if opts.metrics_energy
    sim.energy = acc;
    sim.energy.E_diesel   = E_diesel_total;
    sim.energy.E_unserved = E_unserved_total;
    sim.energy.E_RE_to_load = acc.E_RE_direct + acc.E_vr_dis + acc.E_aa_dis;
    sim.energy.RE_fraction  = sim.energy.E_RE_to_load / max(acc.E_load, eps);
    sim.energy.DG_fraction  = E_diesel_total          / max(acc.E_load, eps);
end
end

% -------------------- helpers --------------------
function v = getf(s, f, d)
if isstruct(s) && isfield(s,f) && ~isempty(s.(f)), v = s.(f); else, v = d; end
end
