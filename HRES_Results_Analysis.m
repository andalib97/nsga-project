function HRES_Results_Analysis()
% HRES_Results_Analysis.m
% Post-processing for NSGA-II results (NGPM) for the mine HRES problem.
% - Loads the most recent nsga_result.mat (from HRES_Run_Optimization.m)
% - Visualizes Pareto (Annualized Cost vs Diesel Fraction)
% - Extracts representative designs (min-cost, min-diesel, knee)
% - Re-simulates each design for energy mix & cost breakdown
% - Plots a one-week dispatch check
%
% Notes:
%   P_load  : hourly mine demand [kW], length = H (typically 8760)
%   GHI     : hourly irradiance factor used to scale PV [~kW/kW_rated]
%   wind_speed : hourly 10 m wind speed [m/s]
% If P_load / resource series are not present, the loader falls back to
% building them (or to simple synthetic profiles) so analysis can still run.

%% 0) Locate and load latest NSGA result
clc;
S = dir(fullfile(pwd,'HRES_NSJ_*','nsga_result.mat'));   % older driver tag
S2 = dir(fullfile(pwd,'HRES_NSGA_*','nsga_result.mat')); % current driver tag
S = [S; S2]; 
if isempty(S)
    if exist(fullfile(pwd,'HRES_NSGAII_result.mat'),'file')
        load(fullfile(pwd,'HRES_NSGAII_result.mat'),'result');  % legacy single-file save
    else
        error('No NSGA results found. Run HRES_Run_Optimization.m first.');
    end
else
    [~,ix] = sort([S.datenum]); S = S(ix); % newest last
    R = load(fullfile(S(end).folder,S(end).name),'result');
    result = R.result;
end

% Prefer explicit pareto fields; else use final generation (F,V)
if isfield(result,'paretoF') && isfield(result,'paretoV') && ~isempty(result.paretoF)
    pfF = result.paretoF;        % [Cost, DieselFrac]
    pfV = result.paretoV;        % [PV, Wind, VRFB_E, VRFB_P, AACAES_E, AACAES_P, Diesel_kW]
else
    % If pareto not stored, extract the final generation
    lastPop = result.pops(end,:);
    pfF = cat(1,lastPop.obj);
    pfV = cat(1,lastPop.var);
end

%% 1) Pareto-front visualization (Cost vs Diesel Fraction)
figdir = new_outdir('HRES_Analysis');
figure('Color','w'); 
scatter(pfF(:,2), pfF(:,1)/1e6, 28, 'filled'); grid on;
xlabel('Diesel Energy Fraction (-)'); ylabel('Annualized Cost (Million $)');
title('Pareto Front: Cost vs Diesel Fraction');
saveas(gcf, fullfile(figdir,'pareto_cost_vs_diesel.png'));

%% 2) Select representative designs: min-cost, min-diesel, knee
[~,iMinCost]   = min(pfF(:,1));
[~,iMinDiesel] = min(pfF(:,2));
Fn    = normalize_columns(pfF);          % 0..1 per objective
utop  = [min(Fn(:,1)), min(Fn(:,2))];    % utopia point in normalized space
[~,iKnee] = min(vecnorm(Fn - utop, 2, 2));


order = [iMinCost; iMinDiesel; iKnee];
[~,ia] = unique(order,'stable');   % keep first occurrence, preserve order
idx    = order(ia);

baseNames = {'MinCost','MinDiesel','Knee'};
names     = baseNames(ia);
fprintf('\n--- Selected Pareto Designs ---\n');
for k = 1:numel(idx)
    fprintf('%-9s  Cost=$%.2fM  Diesel=%.3f\n', names{k}, pfF(idx(k),1)/1e6, pfF(idx(k),2));
end

%% 3) Re-simulate selected designs for energy mix & cost breakdown
[Data, Params] = load_data_and_params();   % robust loader (falls back if missing)
Params.etaV_ch=0.95; Params.etaV_dis=0.95;
Params.etaA_ch=0.85; Params.etaA_dis=0.65;

summary = table;
for k = 1:numel(idx)
    x = pfV(idx(k),:);                     % decision vector
    sim = simulate_design(x, Data, Params);

    fprintf('\n[%s] Mix(%% of demand): PV=%.1f  Wind=%.1f  VRFB=%.1f  AACAES=%.1f  Diesel=%.1f  | Curtail(of gen)=%.1f\n', ...
        names{k}, 100*sim.mix.PV, 100*sim.mix.Wind, 100*sim.mix.VRFB, 100*sim.mix.AACAES, 100*sim.mix.Diesel, 100*sim.mix.CurtailOfGen);
    fprintf('[%s] Cost: Capex_ann=$%.2fM, O&M=$%.2fM, Fuel=$%.2fM, Total=$%.2fM (DieselFrac=%.3f)\n', ...
        names{k}, sim.cost.ann_capex/1e6, sim.cost.annual_OM/1e6, sim.cost.fuel/1e6, sim.cost.total/1e6, sim.metrics.diesel_frac);

    % Append to summary table
    summary = [summary; pack_row(names{k}, x, sim, pfF(idx(k),:))]; %#ok<AGROW>

    % Energy mix bar chart
    figure('Color','w');
    bvals = [sim.mix.PV, sim.mix.Wind, sim.mix.VRFB, sim.mix.AACAES, sim.mix.Diesel]*100;
    bar(bvals,'FaceColor',[0.2 0.5 0.8]); grid on;
    set(gca,'XTickLabel',{'PV','Wind','VRFB','AACAES','Diesel'});
    ylabel('% of Annual Demand'); ylim([0 100]);
    title(sprintf('Energy Mix — %s', names{k}));
    saveas(gcf, fullfile(figdir, sprintf('mix_%s.png',names{k})));

    % One-week dispatch check (change t0/T as needed)
    t0 = 24*90+1;  T = 24*7;     
    plot_timeseries(sim.ts, Data, t0, T, fullfile(figdir, sprintf('timeseries_%s.png',names{k})));
end

% Save CSV summary
writetable(summary, fullfile(figdir,'selected_designs_summary.csv'));
fprintf('\nAnalysis complete. Outputs saved to: %s\n', figdir);
end

%% ----------------- Helpers -----------------
function figdir = new_outdir(prefix)
ts = char(datetime('now','Format','yyyyMMdd_HHmmss'));   % modern timestamp
figdir = fullfile(pwd, sprintf('%s_%s', prefix, ts));
if ~exist(figdir,'dir'); mkdir(figdir); end
end

function Fn = normalize_columns(F)
Fn = F;
for j = 1:size(F,2)
    mn = min(F(:,j)); mx = max(F(:,j));
    if mx>mn, Fn(:,j) = (F(:,j)-mn)/(mx-mn); else, Fn(:,j) = zeros(size(F,1),1); end
end
end

function T = pack_row(name, x, sim, f)
T = table(string(name), x(1),x(2),x(3),x(4),x(5),x(6),x(7), ...
    f(1), f(2), ...
    sim.cost.ann_capex, sim.cost.annual_OM, sim.cost.fuel, sim.cost.total, ...
    sim.mix.PV, sim.mix.Wind, sim.mix.VRFB, sim.mix.AACAES, sim.mix.Diesel, ...
    'VariableNames', {'Label','PV_kW','Wind_kW','VRFB_E_kWh','VRFB_P_kW','AACAES_E_kWh','AACAES_P_kW','Diesel_kW', ...
                      'ObjCost','ObjDieselFrac', ...
                      'AnnCapex','OM','Fuel','TotalCost', ...
                      'MixPV','MixWind','MixVRFB','MixAACAES','MixDiesel'});
end

function [Data,Params] = load_data_and_params()
% Robust loader: base → MAT files → build helper → synthetic fallback.
Data = struct();

% ---- P_load (hourly mine demand in kW) ----
if evalin('base','exist(''P_load'',''var'')')
    Data.P_load = evalin('base','P_load');
elseif exist('P_load.mat','file')
    tmp = load('P_load.mat'); 
    if isfield(tmp,'P_load'), Data.P_load = tmp.P_load; end
end

% ---- GHI & wind_speed (resource) ----
if evalin('base','exist(''GHI'',''var'')'),         Data.GHI = evalin('base','GHI'); end
if evalin('base','exist(''wind_speed'',''var'')'),  Data.wind_speed = evalin('base','wind_speed'); end

if ~isfield(Data,'GHI') || ~isfield(Data,'wind_speed')
    if exist('weipa_solar_wind.mat','file')
        S = load('weipa_solar_wind.mat','GHI','wind_speed');
        Data.GHI = S.GHI; Data.wind_speed = S.wind_speed;
    elseif exist('build_weipa_resource_file.m','file')
        warning('weipa_solar_wind.mat not found; calling NASA POWER helper to build it...');
        build_weipa_resource_file(year(datetime('today')), -12.68, 141.92);  % Weipa Aero
        S = load('weipa_solar_wind.mat','GHI','wind_speed');
        Data.GHI = S.GHI; Data.wind_speed = S.wind_speed;
    else
        % Synthetic fallback (same as objfun fallback)
        hours = 8760; t = (1:hours)';
        Data.GHI        = max(0, sin(2*pi*(t/24)));
        Data.wind_speed = 6 + 2*sin(2*pi*(t/24));
        warning('Using synthetic GHI/wind (fallback).');
    end
end

% If P_load still missing, create constant 8 MW fallback to proceed
if ~isfield(Data,'P_load')
    Data.P_load = 8000 * ones(numel(Data.GHI),1);
    warning('P_load not found; using constant 8 MW fallback.');
end

Params.etaV_ch  = 0.95;  Params.etaV_dis = 0.95;
Params.etaA_ch  = 0.85;  Params.etaA_dis = 0.65;


% Length sanity (trim to shortest)
L = min([numel(Data.P_load), numel(Data.GHI), numel(Data.wind_speed)]);
Data.P_load     = Data.P_load(:);     Data.P_load     = Data.P_load(1:L);
Data.GHI        = Data.GHI(:);        Data.GHI        = Data.GHI(1:L);
Data.wind_speed = Data.wind_speed(:); Data.wind_speed = Data.wind_speed(1:L);
assert(L>=24, 'Insufficient data length.');

% ---- Parameters (mirror HRES_objFun_2) ----
Params.project_life_yr     = 15;
Params.cost_PV_per_kW      = 1500;
Params.cost_Wind_per_kW    = 2000;
Params.cost_VRFB_per_kWh   = 400;
Params.cost_VRFB_per_kW    = 300;
Params.cost_AA_per_kWh     = 50;
Params.cost_AA_per_kW      = 700;
Params.cost_Diesel_per_kW  = 700;

Params.OMfrac_PV           = 0.02;
Params.OMfrac_Wind         = 0.03;
Params.OMfrac_VRFB         = 0.02;
Params.OMfrac_AA           = 0.02;
Params.OMfrac_Diesel       = 0.05;

Params.eta_diesel          = 0.40;
Params.kWh_per_L           = 9.0 * Params.eta_diesel;  % ≈3.6 kWh_e per liter at 40% η
Params.fuel_USD_per_L      = 1.2;

Params.wind_full_ms        = 12;   % linear CF to 12 m/s (cap at 1.0)
end

function sim = simulate_design(x, Data, P)
% simulate_design: re-runs the dispatch (same logic as objective).
PV = x(1); Wind = x(2); VE = x(3); VP = x(4); AE = x(5); AP = x(6); DG = x(7);

socV = 0.5*VE; socA = 0.5*AE;
H = numel(Data.P_load);

% time-series capture
ts.PV=zeros(H,1); ts.Wind=zeros(H,1); ts.Load=Data.P_load(:);
ts.DisV=zeros(H,1); ts.DisA=zeros(H,1); ts.Diesel=zeros(H,1);

diesel_kWh = 0; curtail_kWh = 0; unserved = 0;
pv_used = 0; wind_used = 0; v_used = 0; a_used = 0;

for t=1:H
    % --- Renewables available this hour ---
    PVgen   = PV * Data.GHI(t);
    wind_cf = min(1, Data.wind_speed(t)/P.wind_full_ms);
    Wgen    = Wind * wind_cf;
    renew   = PVgen + Wgen;
    loadt   = Data.P_load(t);

    % 1) Serve load directly from renewables
    servRen  = min(renew, loadt);
    pv2load  = servRen * PVgen/(renew + eps);
    w2load   = servRen * Wgen /(renew + eps);
    remLoad  = loadt - servRen;

    % 2) Discharge storage for remaining load (respect efficiencies)
    % VRFB (deliver dV_out to load; SOC drops by dV_out/eta_dis)
    dV_out = min([remLoad, VP, socV * P.etaV_dis]);
    socV   = socV - dV_out / P.etaV_dis;
    remLoad= remLoad - dV_out;

    % AACAES
    dA_out = min([remLoad, AP, socA * P.etaA_dis]);
    socA   = socA - dA_out / P.etaA_dis;
    remLoad= remLoad - dA_out;

    % 3) Diesel for any residual
    dD = min(remLoad, DG);
    remLoad = remLoad - dD;

    % 4) Charge storages with *surplus* renewables (after serving load)
    surplus = renew - servRen;
    if surplus > 0
        % charge VRFB first
        cV_in = min([surplus, VP, (VE - socV)]);
        socV  = socV + P.etaV_ch * cV_in;
        surplus = surplus - cV_in;

        % then AACAES
        cA_in = min([surplus, AP, (AE - socA)]);
        socA  = socA + P.etaA_ch * cA_in;
        surplus = surplus - cA_in;

        curtail_kWh = curtail_kWh + max(0, surplus);
    end

    % --- Accumulate contributions (no double counting) ---
    pv_used    = pv_used    + pv2load;
    wind_used  = wind_used  + w2load;
    v_used     = v_used     + dV_out;
    a_used     = a_used     + dA_out;
    diesel_kWh = diesel_kWh + dD;

    % time-series (optional)
    ts.PV(t)    = PVgen;
    ts.Wind(t)  = Wgen;
    ts.DisV(t)  = dV_out;
    ts.DisA(t)  = dA_out;
    ts.Diesel(t)= dD;

    if remLoad > 1e-6
        unserved = unserved + remLoad;  % should be ~0 with adequate DG
    end

    ts.PV(t)=PVgen; ts.Wind(t)=Wgen;
end

Eload = sum(Data.P_load);
mix = struct();
mix.PV     = pv_used   / Eload;
mix.Wind   = wind_used / Eload;
mix.VRFB   = v_used    / Eload;
mix.AACAES = a_used    / Eload;
mix.Diesel = diesel_kWh/ Eload;
mix.CurtailOfGen = curtail_kWh / max(eps, (pv_used+wind_used+curtail_kWh));

% Annual cost (same structure as objective)
capex = PV*P.cost_PV_per_kW + Wind*P.cost_Wind_per_kW ...
      + VE*P.cost_VRFB_per_kWh + VP*P.cost_VRFB_per_kW ...
      + AE*P.cost_AA_per_kWh   + AP*P.cost_AA_per_kW ...
      + x(7)*P.cost_Diesel_per_kW;

% --- Annualized CAPEX (CRF if discount_rate available) ---
r_exists = evalin('base','exist(''discount_rate'',''var'')');
if r_exists
    r = evalin('base','discount_rate');
else
    r = [];
end
if ~isempty(r) && r > 0
    n   = P.project_life_yr;
    CRF = r*(1+r)^n / ((1+r)^n - 1);   % capital recovery factor
    ann_capex = capex * CRF;           % use CRF annualization
else
    ann_capex = capex / P.project_life_yr;  % straight-line fallback
end

ann_OM = P.OMfrac_PV*(PV*P.cost_PV_per_kW) + P.OMfrac_Wind*(Wind*P.cost_Wind_per_kW) ...
       + P.OMfrac_VRFB*(VE*P.cost_VRFB_per_kWh + VP*P.cost_VRFB_per_kW) ...
       + P.OMfrac_AA*(AE*P.cost_AA_per_kWh + AP*P.cost_AA_per_kW) ...
       + P.OMfrac_Diesel*(x(7)*P.cost_Diesel_per_kW);

fuel_L   = diesel_kWh / P.kWh_per_L;
fuel_cost = fuel_L * P.fuel_USD_per_L;

cost = struct('ann_capex',ann_capex,'annual_OM',ann_OM,'fuel',fuel_cost, ...
              'total',ann_capex+ann_OM+fuel_cost);

metrics = struct('diesel_frac', mix.Diesel, 'unserved_kWh', unserved);
sim = struct('mix',mix,'cost',cost,'metrics',metrics,'ts',ts);
end

function plot_timeseries(ts, Data, t0, T, outfile)
idx = t0:min(t0+T-1, numel(ts.Load));
figure('Color','w');
yyaxis left; 
plot(idx, ts.Load(idx),'k-','LineWidth',1.2); hold on;
plot(idx, ts.PV(idx),'--','LineWidth',1.0);
plot(idx, ts.Wind(idx),':','LineWidth',1.0);
ylabel('Power (kW)');
yyaxis right;
plot(idx, ts.DisV(idx),'-','LineWidth',1.0);
plot(idx, ts.DisA(idx),'-','LineWidth',1.0);
plot(idx, ts.Diesel(idx),'-','LineWidth',1.0);
ylabel('Power (kW)'); grid on;
legend('Load','PV','Wind','VRFB Dis','AACAES Dis','Diesel','Location','best');
title('One-Week Dispatch Check'); xlabel('Hour');
saveas(gcf,outfile);
end
