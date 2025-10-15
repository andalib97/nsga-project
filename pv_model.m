function P_pv = pv_model(GHI_Wm2, PV_kW, tech)
% PV_MODEL (rev C)  PV AC power from GHI with temp derate & inverter eff.
%
% Assumes PV_kW is the **AC nameplate** (inverter-limited). If you instead
% pass a DC rating, set tech.pv_rating_is_ac=false and the function will
% cap at eta_inv*PV_kW (simple inverter limit).
%
% tech fields (optional, defaults in parentheses):
%   pv_tilt_gain        (1.10)    % POA ≈ pv_tilt_gain * GHI
%   pv_pr               (0.90)    % DC-side performance ratio
%   pv_inverter_eff     (0.96)    % DC→AC efficiency
%   pv_temp_coeff_Pmp   (-0.0045) % per °C (≈ -0.45%/°C)
%   pv_NOCT_C           (45)      % °C
%   pv_T_amb_C          (25)      % °C, scalar OR vector same size as GHI
%   pv_availability     (1.00)    % uptime/availability factor 0..1
%   pv_rating_is_ac     (true)    % true: PV_kW is AC rating; false: DC rating

% ----- defaults if missing -----
tilt_gain  = getf(tech,'pv_tilt_gain',      1.10);
PR_dc      = getf(tech,'pv_pr',             0.90);
eta_inv    = getf(tech,'pv_inverter_eff',   0.96);
alpha_Pmp  = getf(tech,'pv_temp_coeff_Pmp', -0.0045); % 1/°C
NOCT       = getf(tech,'pv_NOCT_C',         45);      % °C
T_amb      = getf(tech,'pv_T_amb_C',        25);      % °C (scalar or vector)
avail      = max(0, min(1, getf(tech,'pv_availability', 1.00)));
rating_is_ac = isfield(tech,'pv_rating_is_ac') && ~isempty(tech.pv_rating_is_ac) && logical(tech.pv_rating_is_ac);

% ----- shape & NaN handling -----
GHI = max(0, double(GHI_Wm2));                % W/m^2, vector or scalar
if ~isscalar(T_amb)
    % allow T_amb to be a vector matching GHI
    if ~isequal(size(T_amb), size(GHI))
        error('pv_model: T_amb vector must match GHI size.');
    end
else
    T_amb = T_amb + zeros(size(GHI));        % expand to size
end
PV_kW = max(0, double(PV_kW));               % capacity (scalar)

% ----- irradiance & temperature model -----
POA    = tilt_gain .* GHI;                   % simple POA ≈ tilt*GHI
cf_irr = min(1, POA/1000);                   % normalized to 1 at 1000 W/m^2

% NOCT cell-temperature estimate: T_cell ≈ T_amb + (POA/800)*(NOCT-20)
T_cell = T_amb + (POA/800) * (NOCT - 20);

% Temperature derate (relative to 25°C), never negative
temp_factor = max(0, 1 + alpha_Pmp * (T_cell - 25));

% DC production and AC conversion
Pdc_cf = cf_irr .* PR_dc .* temp_factor;     % relative to nameplate
Pdc    = PV_kW .* Pdc_cf;                    % if PV_kW is DC, see below
Pac    = eta_inv .* Pdc;

% Availability
Pac = avail .* Pac;

% Clip to rating
if rating_is_ac
    % PV_kW interpreted as AC nameplate (default)
    Pac_max = PV_kW;
else
    % PV_kW interpreted as DC nameplate; simple inverter cap
    Pac_max = eta_inv * PV_kW;
end
P_pv = min(max(Pac, 0), max(0, Pac_max));

% NaN/Inf guard
P_pv(~isfinite(P_pv)) = 0;
end

% ----------------- local helper -----------------
function v = getf(s, f, d)
if nargin < 3, d = []; end
if ~isstruct(s) || ~isfield(s,f) || isempty(s.(f)), v = d; else, v = s.(f); end
end
