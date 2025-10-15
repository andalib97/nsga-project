function [LPSP_m, info] = reliability_metrics(design, params, tech, diesel, scenarios)
% RELIABILITY_METRICS (rev E)
% Computes between-years reliability:
%   LPSP_m = (#failed_years) / n_years
%
% Modes (params.reliability_mode):
%   'diesel'        : fail if E_diesel_kWh > diesel_tol_kWh
%   'unserved'      : fail if E_unserved_kWh > unserved_tol_kWh
%   'either'        : fail if ('diesel' OR 'unserved')           [recommended default]
%   'diesel_share'  : fail if diesel_share > target (+tol)  OR  E_unserved_kWh > tol
%   'diesel_hours'  : fail if diesel_hour_frac > diesel_hour_frac_target
%
% Optional 2nd output (returned only if nargout>1):
%   info.diesel_share_years       [NY x 1]
%   info.RE_share_years           [NY x 1]   (requires metrics_energy)
%   info.E_diesel_years           [NY x 1]   (kWh)
%   info.E_unserved_years         [NY x 1]   (kWh)
%   info.E_load_years             [NY x 1]   (kWh)
%   info.diesel_hour_frac_years   [NY x 1]
%   info.mode, thresholds…        (echo params used)

% ----------- Defaults / mode selection -----------
mode = 'diesel';
if isfield(params,'reliability_mode') && ~isempty(params.reliability_mode)
    mode = lower(string(params.reliability_mode));
end

diesel_tol   = get_param(params,'diesel_tol_kWh',0);
unserved_tol = get_param(params,'unserved_tol_kWh',0);
share_tgt    = get_param(params,'diesel_share_target',0.35);
share_tol    = get_param(params,'diesel_share_tol',0.0);
dh_frac_tgt  = get_param(params,'diesel_hour_frac_target',0.50);
store_ts     = logical(get_param(params,'reliability_store_timeseries',false));

% ----------- Scenario basic checks -----------
H  = scenarios.hours_year;
NY = scenarios.n_years;
dt = get_param(params,'dt_hours',1);
if H <= 0 || NY <= 0
    error('reliability_metrics: invalid scenario dimensions.');
end
if numel(scenarios.GHI) ~= H*NY || numel(scenarios.WS) ~= H*NY || numel(scenarios.LOAD) ~= H*NY
    error('reliability_metrics: scenario vectors must be length H*n_years.');
end

% ----------- Pre-allocations -----------
fail_year = false(1, NY);
want_info = (nargout > 1);

if want_info
    E_diesel_years          = zeros(NY,1);
    E_unserved_years        = zeros(NY,1);
    E_load_years            = zeros(NY,1);
    diesel_share_years      = nan(NY,1);
    RE_share_years          = nan(NY,1);
    diesel_hour_frac_years  = zeros(NY,1);
end

% Determine if we must enable energy accounting
need_energy_metrics = want_info || strcmp(mode, "diesel_share");

% ----------- Evaluate each synthetic year -----------
for y = 1:NY
    sc = extract_scenario(scenarios, y);

    opts = struct();
    opts.store_timeseries = store_ts;             % optional, for debugging
    opts.metrics_energy   = need_energy_metrics;  % ensures E_load/E_RE when needed

    sim = simulate_hres(design, params, tech, diesel, sc, opts);

    % Ensure required tallies exist
    if ~isfield(sim,'E_diesel_kWh'),   sim.E_diesel_kWh   = 0; end
    if ~isfield(sim,'E_unserved_kWh'), sim.E_unserved_kWh = 0; end

    % --- Failure rule by mode ---
    switch mode
        case "diesel"
            fail_year(y) = sim.E_diesel_kWh > diesel_tol;

        case "unserved"
            fail_year(y) = sim.E_unserved_kWh > unserved_tol;

        case "either"
            fail_year(y) = (sim.E_diesel_kWh  > diesel_tol) || ...
                           (sim.E_unserved_kWh > unserved_tol);

        case "diesel_share"
            % Prefer simulator's energy accounting
            if isfield(sim,'energy') && isfield(sim.energy,'E_load')
                E_load   = sim.energy.E_load;
                E_diesel = sim.energy.E_diesel;
            else
                % Fallback: scenario load energy for the year
                E_load   = sum(sc.LOAD(:))*dt;
                E_diesel = sim.E_diesel_kWh;
            end
            diesel_share = E_diesel / max(E_load, eps);
            % IMPORTANT: also fail on unmet load to prevent "zero-system" pass
            fail_year(y) = (diesel_share > (share_tgt + share_tol)) || ...
                           (sim.E_unserved_kWh > unserved_tol);

        case "diesel_hours"
            dhf =  diesel_hour_frac_fallback(sim, sc, dt);
            fail_year(y) = dhf > dh_frac_tgt;

        otherwise
            error('reliability_metrics: unknown reliability_mode "%s"', mode);
    end

    % --- Collect per-year info if requested ---
    if want_info
        E_diesel_years(y)          = sim.E_diesel_kWh;
        E_unserved_years(y)        = sim.E_unserved_kWh;

        % Load energy (prefer simulator's energy accounting)
        if isfield(sim,'energy') && isfield(sim.energy,'E_load')
            E_load_years(y) = sim.energy.E_load;
        else
            E_load_years(y) = sum(sc.LOAD(:))*dt;
        end

        % Diesel share (robust)
        diesel_share_years(y) = E_diesel_years(y) / max(E_load_years(y), eps);

        % RE share (requires energy breakdown to count storage discharge)
        if isfield(sim,'energy') && isfield(sim.energy,'E_RE_to_load')
            RE_share_years(y) = sim.energy.E_RE_to_load / max(E_load_years(y), eps);
        else
            RE_share_years(y) = NaN;
        end

        % Diesel hour fraction
        diesel_hour_frac_years(y) = diesel_hour_frac_fallback(sim, sc, dt);
    end
end

% ----------- Final metric -----------
LPSP_m = sum(fail_year) / NY;
LPSP_m = min(max(LPSP_m,0),1);  % clamp for safety

% ----------- Optional info struct -----------
if want_info
    info = struct();
    info.mode                      = char(mode);
    info.diesel_tol_kWh            = diesel_tol;
    info.unserved_tol_kWh          = unserved_tol;
    info.diesel_share_target       = share_tgt;
    info.diesel_share_tol          = share_tol;
    info.diesel_hour_frac_target   = dh_frac_tgt;

    info.E_diesel_years            = E_diesel_years;
    info.E_unserved_years          = E_unserved_years;
    info.E_load_years              = E_load_years;
    info.diesel_share_years        = diesel_share_years;
    info.RE_share_years            = RE_share_years;
    info.diesel_hour_frac_years    = diesel_hour_frac_years;
end
end

% ========================= Local helpers ================================
function sc = extract_scenario(scenarios, y)
H = scenarios.hours_year;
idx = (y-1)*H + (1:H);
sc = struct('GHI',scenarios.GHI(idx), 'WS',scenarios.WS(idx), 'LOAD',scenarios.LOAD(idx));
end

function v = get_param(s, field, default)
if isfield(s, field) && ~isempty(s.(field)), v = s.(field); else, v = default; end
end

function dhf = diesel_hour_frac_fallback(sim, sc, dt)
% Returns diesel-hour fraction with fallbacks:
% 1) sim.diesel_hour_frac if provided by simulator
% 2) if timeseries exists and has P_diesel, compute fraction(P_diesel>0)
% 3) binary proxy: double(E_diesel_kWh>tol)  (very conservative)
if isfield(sim, 'diesel_hour_frac') && ~isempty(sim.diesel_hour_frac)
    dhf = sim.diesel_hour_frac;
    return;
end
if isfield(sim, 'ts') && isfield(sim.ts, 'P_diesel')
    v = sim.ts.P_diesel(:);
    dhf = mean(v > 1e-6);
    return;
end
% proxy (keeps algorithm robust even if simulator is minimal)
tol = 1e-6; % kWh
dhf = double(sim.E_diesel_kWh > tol);
end
