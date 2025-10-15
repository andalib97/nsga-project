%% HRES_make_scenarios.m  (rev B)
% Generate synthetic solar/wind/load scenarios for a typical AU remote mine.
% RUN AFTER: HRES_setup.m  (uses HRES_DATA.site and HRES_DATA.params)

clearvars -except HRES_DATA; clc;

%% -------- Load shared data --------------------------------------------
if ~exist('HRES_DATA','var') || ~isstruct(HRES_DATA)
    if exist('HRES_DATA.mat','file')
        load HRES_DATA.mat
    else
        error('HRES_DATA not found. Run HRES_setup.m first.');
    end
end
global HRES_DATA
params = HRES_DATA.params;
site   = HRES_DATA.site;

H  = params.hours_year;
DT = params.dt_hours;
NY = params.n_years;

if H <= 0 || NY <= 0 || DT <= 0
    error('Invalid params in HRES_DATA (hours_year, n_years, dt_hours).');
end
steps_per_day = round(24/DT);
if steps_per_day*365 ~= H
    warning('hours_year (%d) != 365*(24/dt)=%d. Adjusting to 365 days x %.2f h steps.', ...
            H, steps_per_day*365, DT);
    H = steps_per_day*365;
end

% Master seed (we'll derive per-year seeds so years are NOT clones)
if isfield(params,'scenario_seed') && ~isempty(params.scenario_seed)
    master_seed = params.scenario_seed;
else
    master_seed = 42;
end
rng(master_seed);

%% -------- Knobs reflecting AU remote-mine conditions -------------------
cfg = struct();

% Solar (GHI) shape & noise
cfg.ghi_peak_wm2       = 950;   % clear-sky-ish peak
cfg.season_amp         = 0.35;  % ± seasonal swing in GHI
cfg.cloud_step_noise   = 90;    % W/m^2 step noise (hourly)
cfg.cloud_day_corr     = 0.85;  % persistence 0..1 (higher = longer cloudy spells)
cfg.interannual_solar  = 0.12;  % ±12% year-to-year variability

% Wind: nocturnal & winter uplift (typical in many AU interiors)
cfg.wind_mean_ms       = 7.0;   % average m/s
cfg.wind_diurnal_ms    = 1.8;   % day–night swing
cfg.wind_winter_boost  = 0.8;   % +m/s in winter months
cfg.wind_step_noise    = 1.0;   % m/s step noise
cfg.interannual_wind   = 0.10;  % ±10% year-to-year variability

% Load: 24/7 process plant; modest diurnal; occasional maintenance dips
cfg.load_avg_kW        = site.P_avg_kW;
cfg.load_diurnal_frac  = 0.10;  % ±10% around average
cfg.load_noise_kW      = 0.03*site.P_avg_kW;  % random fluctuations
cfg.maintenance_prob   = 0.02;  % ~2% of days with minor dip
cfg.maintenance_drop   = 0.08;  % -8% on maintenance days
cfg.interannual_load   = 0.05;  % ±5% year-to-year variability
cfg.load_floor_kW      = 0.35*site.P_avg_kW; % never below 35% of avg

% Stress years (dunkelflaute-like): a subset of years with poorer renewables
cfg.stress_year_frac   = 0.15;  % ~15% of years
cfg.stress_solar_mult  = 0.80;  % solar scaled to 80% in those years
cfg.stress_wind_mult   = 0.85;  % wind scaled to 85% in those years

%% -------- Deterministic seasonal backbones (reused each year) ----------
t          = (1:H)';                       % step index
day_idx    = floor((t-1)/steps_per_day);   % 0..364
hour_in_d  = (mod(t-1, steps_per_day))*DT; % 0..24-DT
season_phi = 2*pi*(day_idx/365);

% Daylight window: soft half-sine peaking ~13:00 local time
daylight = max(0, sin(pi*(hour_in_d - 6)/14));  % ~6:00..20:00
% Seasonal modulation (higher in austral summer)
season   = 1 + cfg.season_amp*sin(season_phi - pi/2); % Dec/Jan higher

% Wind deterministic components
wind_diurnal = cfg.wind_diurnal_ms * sin(2*pi*(hour_in_d/24) - pi/2);
winter       = cfg.wind_winter_boost * cos(season_phi);  % max in winter

% Load deterministic component
load_diurnal = 1 + cfg.load_diurnal_frac * sin(2*pi*(hour_in_d/24));

%% -------- Build N independent years (stochastic parts differ) ----------
GHI  = zeros(H*NY,1);
WS   = zeros(H*NY,1);
LOAD = zeros(H*NY,1);
is_stress_year = false(NY,1);

for y = 1:NY
    idx = (y-1)*H + (1:H);

    % Per-year RNG seed so each year is unique but reproducible
    rng(master_seed + 10*y);

    % --- Solar: AR(1) cloudiness per year ---
    epsi = randn(H,1);
    % AR(1): x_t = rho*x_{t-1} + e_t
    rho  = max(0,min(0.999, cfg.cloud_day_corr));
    ar1  = filter(1, [1, -rho], epsi);
    % normalize and scale
    ar1  = ar1 - mean(ar1);
    s    = std(ar1); if s < 1e-6, s = 1; end
    cloud = cfg.cloud_step_noise * (ar1 / s);

    % --- Wind: step noise per year ---
    wind_noise = cfg.wind_step_noise * randn(H,1);

    % --- Load: noise and maintenance days per year ---
    load_noise = cfg.load_noise_kW * randn(H,1);
    is_new_day = [true; diff(day_idx) > 0];
    maint_flag = false(H,1);
    for k = 1:H
        if is_new_day(k) && rand() < cfg.maintenance_prob
            d0 = k; d1 = min(k + steps_per_day - 1, H);
            maint_flag(d0:d1) = true;
        end
    end

    % Inter-annual scalars
    solar_mult = 1 + cfg.interannual_solar*(2*rand()-1);
    wind_mult  = 1 + cfg.interannual_wind *(2*rand()-1);
    load_mult  = 1 + cfg.interannual_load *(2*rand()-1);

    % Stress years: depress solar & wind jointly
    if rand() < cfg.stress_year_frac
        solar_mult = solar_mult * cfg.stress_solar_mult;
        wind_mult  = wind_mult  * cfg.stress_wind_mult;
        is_stress_year(y) = true;
    end

    % Compose year t=1..H
    GHI_y  = max(0, solar_mult * (cfg.ghi_peak_wm2 * daylight .* season + cloud));
    WS_y   = max(0, wind_mult  * (cfg.wind_mean_ms + wind_diurnal + winter + wind_noise));
    LOAD_y = load_mult * (cfg.load_avg_kW * load_diurnal + load_noise);
    LOAD_y(maint_flag) = LOAD_y(maint_flag) * (1 - cfg.maintenance_drop);
    LOAD_y = max(cfg.load_floor_kW, LOAD_y);

    % Write into concatenated arrays
    GHI(idx)  = GHI_y;
    WS(idx)   = WS_y;
    LOAD(idx) = LOAD_y;
end

%% -------- Save into HRES_DATA and persist ------------------------------
scenarios = struct();
scenarios.hours_year   = H;
scenarios.n_years      = NY;
scenarios.dt_hours     = DT;
scenarios.GHI          = GHI(:);
scenarios.WS           = WS(:);
scenarios.LOAD         = LOAD(:);
scenarios.source.mode  = 'synthetic_au_mine_revB';
scenarios.source.seed  = master_seed;
scenarios.meta.is_stress_year = is_stress_year;

HRES_DATA.scenarios = scenarios;
save('HRES_DATA.mat','HRES_DATA');

%% -------- Summaries & cross-year variability ---------------------------
H  = scenarios.hours_year; NY = scenarios.n_years;
GHI_y  = reshape(scenarios.GHI,  H, NY);
WS_y   = reshape(scenarios.WS,   H, NY);
LOAD_y = reshape(scenarios.LOAD, H, NY);

Eghi  = sum(GHI_y,  1);
Ews   = sum(WS_y,   1);
Eload = sum(LOAD_y, 1);

cv = @(v) std(v,1)/max(mean(v),1e-9);
fprintf('[HRES_make_scenarios] %d year(s), %d steps/year (Δt=%.2fh)\n', NY, H, DT);
fprintf('  Solar  GHI: mean=%5.1f W/m^2  max=%5.1f  (CV across years=%.3f)\n', mean(GHI),  max(GHI),  cv(Eghi));
fprintf('  Wind   WS : mean=%4.2f m/s    max=%4.2f  (CV across years=%.3f)\n', mean(WS),   max(WS),   cv(Ews));
fprintf('  Load   kW : mean=%6.1f        max=%6.1f  (CV across years=%.3f)\n', mean(LOAD), max(LOAD), cv(Eload));
fprintf('  Stress years (low RE): %d of %d (%.1f%%)\n', sum(is_stress_year), NY, 100*mean(is_stress_year));
