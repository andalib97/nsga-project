% *** Script 1: Microgrid Data Setup and Single-Design Simulation ***
% HRES_Data_and_Model_Setup_Script
% 1. Load input data for one year (8760 hours)
hours = 8760;
% Example hourly load profile (kW) – here assumed roughly constant for demo.
% In practice, use actual mine data or a representative daily curve.
P_load = 8000 * ones(hours,1);                 % 8 MW constant demand (placeholder)

% === Build/Load Weipa resource data (GHI, wind_speed) ===
if ~exist('weipa_solar_wind.mat','file')
    if exist('build_weipa_resource_file.m','file') == 2
        % Weipa Aero (QLD) approx coords:
        yr = year(datetime('now'));           % pick the year you want
        build_weipa_resource_file(yr, -12.68, 141.92, 'weipa_solar_wind.mat');
        % (Helper fetches NASA POWER Hourly API: ALLSKY_SFC_SW_DWN & WS10M,
        % converts GHI W/m^2 -> kW/m^2 for PV scaling, then saves MAT.)
    else
        warning('weipa_solar_wind.mat missing and builder not found; using synthetic resources.');
        hours = 8760; t=(1:hours)'; 
        GHI = max(0, sin(2*pi*(t/24)));          % simple daily proxy (0..1)
        wind_speed = 6 + 2*sin(2*pi*(t/24));     % m/s proxy
        save('weipa_solar_wind.mat','GHI','wind_speed');
    end
end
S = load('weipa_solar_wind.mat','GHI','wind_speed');
GHI = S.GHI(:); wind_speed = S.wind_speed(:);

% Example solar irradiance profile (kW/m^2) and wind speed (m/s) for each hour
load('weipa_solar_wind.mat','GHI','wind_speed');  % (Assume we have site data arrays)
% If actual data not available, could generate synthetic profiles.

% --- Financial settings (real terms) ---
discount_rate = 0.08;  % 8% real WACC (example; see notes below)

% === Build/Load mine demand (hourly) ===
if ~exist('P_load.mat','file')
    P_load = build_synthetic_P_load(struct( ...
        'base_MW',8,'diurnal_pct',5,'weekly_pct',2,'seasonal_pct',3, ...
        'noise_pct',1.5,'shift_hours',[6 18],'shift_pct',2,'save_mat',true));
else
    S = load('P_load.mat','P_load'); 
    P_load = S.P_load;
end

% 2. Define technology parameters and costs
diesel_capacity = 26000;    % 26 MW diesel capacity available (kW)
diesel_efficiency = 0.4;    % 40% efficiency (~3.6 kWh/L) 
diesel_fuel_cost = 1.2;     % $1.2 per liter diesel (example)
% Capital cost coefficients (example values)
cost_PV_per_kW   = 1500;    % $1500/kW for PV 
cost_Wind_per_kW = 2000;    % $2000/kW for wind 
cost_VRFB_per_kWh   = 400;  % $400/kWh for VRFB energy capacity
cost_VRFB_per_kW    = 300;  % $300/kW for VRFB power capacity (stacks)
cost_AA_per_kWh = 50;   % $50/kWh for AACAES storage (cavern)
cost_AA_per_kW  = 700;  % $700/kW for AACAES machinery

% 3. Choose a test design (decision variables) for simulation
PV_capacity    = 5000;   % 5 MW PV
Wind_capacity  = 5000;   % 5 MW Wind
VRFB_E_capacity = 20000; % 20 MWh VRFB
VRFB_P_capacity = 5000;  % 5 MW max VRFB charge/discharge
AACAES_E_capacity = 100000; % 100 MWh AACAES
AACAES_P_capacity = 5000;   % 5 MW max AACAES charge/discharge

% 4. Initialize storage states (state of charge)
soc_VRFB  = 0.5 * VRFB_E_capacity;   % start at 50% charge
soc_AACAES = 0.5 * AACAES_E_capacity;
diesel_used_energy = 0;  % kWh supplied by diesel over the year
% --- Storage efficiencies (keep consistent with objfun & analysis) ---
etaV_ch  = 0.95;   % VRFB charge efficiency
etaV_dis = 0.95;   % VRFB discharge efficiency
etaA_ch  = 0.85;   % AACAES charge efficiency
etaA_dis = 0.65;   % AACAES discharge efficiency

% 5. Time-step simulation over one year
for t = 1:hours
    % Renewable generation available at hour t
    % (Assume PV output = capacity * GHI (kW/m^2), and Wind output by a factor)
    PV_gen = PV_capacity * GHI(t);   % PV power (kW)
    % Simple wind model: use capacity * capacity factor from wind speed
    cf = min(1, wind_speed(t)/12);   % crude capacity factor (linear till 12 m/s)
    Wind_gen = Wind_capacity * cf;   % Wind power (kW)
    % Total renewable power available this hour
    renew_power = PV_gen + Wind_gen;
    
    % Load and supply difference
if renew_power >= P_load(t)
        % Case 1: surplus renewable energy after meeting load
        surplus = renew_power - P_load(t);
        % Charge VRFB with surplus if not full
        charge_V = min([surplus, VRFB_P_capacity, (VRFB_E_capacity - soc_VRFB)]);
        soc_VRFB = soc_VRFB + etaV_ch * charge_V;
        surplus   = surplus - charge_V;
        % Charge AACAES with remaining surplus if not full
        charge_C = min([surplus, AACAES_P_capacity, (AACAES_E_capacity - soc_AACAES)]);
        soc_AACAES = soc_AACAES + etaA_ch * charge_C;
        surplus    = surplus - charge_C;
        % Any remaining surplus is curtailed (unused).
        curtail_kWh = curtail_kWh + max(0, surplus);
        % Diesel not needed as load is fully met by renewables.
    else
    % Case 2: renewable power is insufficient – deficit needs storage or diesel
    deficit = P_load(t) - renew_power;

    % Discharge VRFB
    discharge_V_out = min([deficit, VRFB_P_capacity, soc_VRFB * etaV_dis]);
    soc_VRFB  = soc_VRFB - discharge_V_out / etaV_dis;
    deficit   = deficit - discharge_V_out;

    % Discharge AACAES  (typo fixed + consistent variable name)
    discharge_C_out = min([deficit, AACAES_P_capacity, soc_AACAES * etaA_dis]);
    soc_AACAES = soc_AACAES - discharge_C_out / etaA_dis;
    deficit    = deficit - discharge_C_out;

    % Diesel last (use lowercase name you defined at top)
    if deficit > 0
        diesel_output = min([deficit, diesel_capacity]);
        deficit = deficit - diesel_output;
        diesel_used_energy = diesel_used_energy + diesel_output;
    end
        % (In this backup scenario, diesel_output covers all remaining deficit;
        % 'deficit' should end at 0, ensuring load met.)
end
    
    % (Optional: impose end-of-day or periodic checks, e.g., no year-end net deficit.
    % Here, we allow storages to carry charge through year continuously.)
end

% 6. Compute performance metrics for this design
total_load_energy = sum(P_load);  % total demand in kWh for the year
diesel_fuel_L = diesel_used_energy / (diesel_efficiency * 9.0);  % ≈ 3.6 kWh/L at 40%
% ^ diesel_used_energy (kWh) / (0.4 kWh per kWh fuel) = kWh of fuel, /1000 ~ liters
renewable_fraction = 1 - (diesel_used_energy / total_load_energy);
fprintf('Test Design Results: Diesel supplied %.1f kWh (%.1f%% of load), fuel used ~%.0f L\n', ...
    diesel_used_energy, 100*(1-renewable_fraction), diesel_fuel_L);

% 7. Compute approximate annual cost for this design
capex = PV_capacity*cost_PV_per_kW + Wind_capacity*cost_Wind_per_kW ...
      + VRFB_E_capacity*cost_VRFB_per_kWh + VRFB_P_capacity*cost_VRFB_per_kW ...
      + AACAES_E_capacity*cost_AA_per_kWh + AACAES_P_capacity*cost_AA_per_kW;
opex_fuel = diesel_fuel_L * diesel_fuel_cost;  % fuel cost per year
% (For simplicity, ignore O&M or convert all to annualized cost if needed)
total_annual_cost = opex_fuel + capex/15;  % assume 15-year life for capital to annualize
fprintf('Annualized Cost: $%.1fM, Diesel cost: $%.1fM per year\n', ...
    total_annual_cost/1e6, opex_fuel/1e6);
