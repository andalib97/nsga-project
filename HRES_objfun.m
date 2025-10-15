function [f, cons] = HRES_objfun(x)
% HRES_objfun (rev C)  Objective wrapper for NGPM/NSGA-II
%   Inputs:
%     x = [ PV_kW, WT_kW, AA_E_kWh, AA_P_kW, VR_E_kWh, VR_P_kW, DG_P_kW, scheme_idx ]
%   Outputs:
%     f    = [ CC(x), LPSP_m(x) ]
%     cons = []  (add custom inequality/equality constraints here if needed)
%
% Notes:
%   - Robust to missing Statistics Toolbox (no prctile dependency).
%   - Clamps x to bounds and sanitizes outputs to keep NSGA stable.
%   - Optional lightweight sampler logger (disabled by default).

% ------------------- Load shared data -------------------
if ~exist('HRES_DATA','var') || ~isstruct(HRES_DATA)
    if exist('HRES_DATA.mat','file')
        load HRES_DATA.mat
    else
        error('HRES_objfun: HRES_DATA not found. Run HRES_setup.m first.');
    end
end
global HRES_DATA
params    = HRES_DATA.params;
costs     = HRES_DATA.costs;
tech      = HRES_DATA.tech;
diesel    = HRES_DATA.diesel;
scenarios = HRES_DATA.scenarios;
bounds    = HRES_DATA.bounds;

% ------------------- Unpack & sanitize decision vector -------------------
% Ensure correct length
if numel(x) < 8
    error('HRES_objfun: decision vector length is %d, expected 8.', numel(x));
end

% Clamp to bounds (belt-and-braces even though NGPM enforces lb/ub)
lb = bounds.lb(:)'; ub = bounds.ub(:)';
x  = min(max(x(:)'.*1.0, lb), ub);  % preserve orientation

% Extract and coerce types
PV_kW = max(0, x(1));
WT_kW = max(0, x(2));
AA_E  = max(0, x(3));
AA_P  = max(0, x(4));
VR_E  = max(0, x(5));
VR_P  = max(0, x(6));
DG_P  = max(0, x(7));
scheme = max(1, min(3, round(x(8))));  % integer 1..3

design = struct( ...
    'PV_kW', PV_kW, 'WT_kW', WT_kW, ...
    'AA_E',  AA_E,  'AA_P',  AA_P, ...
    'VR_E',  VR_E,  'VR_P',  VR_P, ...
    'DG_P',  DG_P,  'scheme', scheme);

% ------------------- Objective 1: Capital Cost --------------------------
CC = economics(design, costs);

% ------------------- Objective 2: Reliability (LPSP_m) ------------------
% Prefer 2-output signature; if not supported, fall back to 1-output.
have_info = false;
try
    [LPSP_m, info] = reliability_metrics(design, params, tech, diesel, scenarios);
    have_info = true;
catch ME1
    try
        LPSP_m = reliability_metrics(design, params, tech, diesel, scenarios);
    catch ME2
        % Rethrow the FIRST error so we don't hide real bugs
        rethrow(ME1);
    end
end

% ------------------- Sanitize outputs (keep NSGA stable) ----------------
if ~isfinite(CC) || ~isfinite(LPSP_m) || isnan(CC) || isnan(LPSP_m)
    % Penalize catastrophic evaluations
    CC      = max(CC, 1e12);   % big cost
    LPSP_m  = 1;               % worst reliability
end
% Bound LPSP_m to [0,1] just in case of minor numeric noise
LPSP_m = min(max(LPSP_m, 0), 1);

% ------------------- Package objectives for NGPM ------------------------
f    = [CC, LPSP_m];
cons = [];   % Add inequality/equality constraints here if needed

% ------------------- Optional sampler logger (very light) ---------------
% Disabled by default. Turn on by setting params.log_interval > 0.
log_interval    = get_field(params, 'log_interval', 0);
log_max_records = get_field(params, 'log_max_records', 200);
if log_interval > 0
    persistent eval_counter
    if isempty(eval_counter), eval_counter = 0; end
    eval_counter = eval_counter + 1;

    if mod(eval_counter, log_interval) == 0
        rec = struct();
        rec.tstamp = now;
        rec.x      = x(:)';   %#ok<STRNU>
        rec.CC     = CC;
        rec.LPSP_m = LPSP_m;

        if have_info
            if isfield(info,'diesel_share_years')
                ds = info.diesel_share_years(:);
                rec.diesel_share_mean = mean(ds,'omitnan');
                rec.diesel_share_p90  = pctile_fallback(ds, 90);
            end
            if isfield(info,'RE_share_years')
                rs = info.RE_share_years(:);
                rec.RE_share_mean = mean(rs,'omitnan');
            end
            if isfield(info,'E_diesel_years')
                rec.E_diesel_mean_kWh = mean(info.E_diesel_years,'omitnan');
            end
            if isfield(info,'E_load_years')
                rec.E_load_mean_kWh = mean(info.E_load_years,'omitnan');
            end
        end

        % Append to a small global ring buffer for quick post-run inspection
        global HRES_MON
        if ~isstruct(HRES_MON) || ~isfield(HRES_MON,'records')
            HRES_MON.records = rec;
        else
            HRES_MON.records(end+1) = rec;  %#ok<AGROW>
            if numel(HRES_MON.records) > log_max_records
                HRES_MON.records = HRES_MON.records(end-log_max_records+1:end);
            end
        end
    end
end
end

% ------------------------ local helpers ---------------------------------
function v = get_field(s, f, d)
if isstruct(s) && isfield(s,f) && ~isempty(s.(f)), v = s.(f); else, v = d; end
end

function p = pctile_fallback(v, q)
% Returns percentile q (0..100) without requiring Statistics Toolbox.
v = v(:);
v = v(isfinite(v));
if isempty(v), p = NaN; return; end
try
    % If prctile exists, use it
    if exist('prctile','file') ~= 0
        p = prctile(v, q);
        return;
    end
catch
end
% Manual fallback (nearest-rank)
v = sort(v);
k = max(1, min(numel(v), round((q/100)*numel(v))));
p = v(k);
end
