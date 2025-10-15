function P_wt = wind_model(WS_ms, WT_kW, tech)
% WIND_MODEL (rev C)  OEM-like curve: sub-rated ramp → rated plateau → cut-out.
%
% Required in tech: wind_cut_in, wind_rated_ms, wind_cut_out
% Optional in tech (defaults): wind_curve_k=3, wind_availability=0.97, wind_rho=1.225
% WS_ms can be scalar or vector. WT_kW is the total AC nameplate (farm rating).

% ---- required params ----
must = {'wind_cut_in','wind_rated_ms','wind_cut_out'};
if any(~isfield(tech, must))
    error('wind_model: tech.wind_* parameters are required.');
end
v_ci = tech.wind_cut_in;
v_r  = tech.wind_rated_ms;
v_co = tech.wind_cut_out;
if ~(v_ci > 0 && v_r > v_ci && v_co > v_r)
    error('wind_model: need 0 < cut-in < rated < cut-out (got %.2g, %.2g, %.2g)', v_ci, v_r, v_co);
end

% ---- options / defaults ----
kexp  = get_field(tech, 'wind_curve_k',      3);
avail = get_field(tech, 'wind_availability', 0.97);
rho   = get_field(tech, 'wind_rho',          1.225);

% ---- inputs & shapes ----
v      = max(0, double(WS_ms));             % m/s, vectorized
WT_kW  = max(0, double(WT_kW));             % scalar total rating

% availability can be scalar or vector matching v
if isscalar(avail)
    avail_v = repmat(max(0,min(1,avail)), size(v));
else
    if ~isequal(size(avail), size(v))
        error('wind_model: wind_availability vector must match WS size.');
    end
    avail_v = max(0,min(1,double(avail)));
end

% ---- piecewise capacity factor ----
cf = zeros(size(v));

% sub-rated region
idx_sub = (v >= v_ci) & (v < v_r);
if any(idx_sub)
    denom = max(1e-6, (v_r - v_ci));
    cf0   = ((v(idx_sub) - v_ci) ./ denom) .^ kexp;   % smooth ramp
    rho_factor = (rho/1.225);                         % density scaling (simple)
    cf(idx_sub) = cf0 .* rho_factor;
end

% rated region
idx_r  = (v >= v_r) & (v < v_co);
cf(idx_r) = 1.0;

% cut-in/out already zero by initialization
cf = max(0, min(1, cf)) .* avail_v;                  % apply availability 0..1

% ---- AC power, clipped to nameplate ----
P_wt = min(max(WT_kW .* cf, 0), WT_kW);
P_wt(~isfinite(P_wt)) = 0;                            % NaN/Inf guard
end

function x = get_field(s, f, d)
if isfield(s,f) && ~isempty(s.(f)), x = s.(f); else, x = d; end
end
