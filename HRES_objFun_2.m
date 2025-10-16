function [y, cons] = HRES_objFun_2(x, varargin)
% HRES_objFun_2: NGPM/NSGA-II objective for the mine HRES.
% x = [PV_kW, Wind_kW, VRFB_E_kWh, VRFB_P_kW, AACAES_E_kWh, AACAES_P_kW, Diesel_kW]
% y = [Annualized_Total_Cost_$, Diesel_Energy_Fraction]; cons = [].

    % ------- 0) Input sanity -------
    assert(numel(x)==7, 'HRES_objFun_2: x must have 7 decision variables.');
    x = max(0, x(:)');  % clamp tiny negative floats to 0

    % ------- 1) Load (once) the hourly data -------
    persistent INIT GHI wind_speed P_load total_d_kWh
    if isempty(INIT)
        try
            S = load('weipa_solar_wind.mat','GHI','wind_speed');
            GHI = S.GHI(:); wind_speed = S.wind_speed(:);
        catch
            hours = 8760; t = (1:hours)';
            GHI = max(0, sin(2*pi*(t/24)));          % proxy 0..1
            wind_speed = 6 + 2*sin(2*pi*(t/24));     % m/s proxy
        end
        if evalin('base','exist(''P_load'',''var'')')
            P_load = evalin('base','P_load');
        else
            P_load = 8000*ones(numel(GHI),1);        % 8 MW placeholder
        end
        assert(numel(GHI)==numel(P_load) && numel(wind_speed)==numel(P_load), ...
            'GHI, wind_speed, and P_load must be same length.');
        total_d_kWh = sum(P_load);
        INIT = true;
    end

    % ------- 2) Decision variables -------
    PV_kW     = x(1);
    Wind_kW   = x(2);
    VE_kWh    = x(3);  VP_kW  = x(4);    % VRFB energy/power
    AE_kWh    = x(5);  AP_kW  = x(6);    % AACAES energy/power
    Diesel_kW = x(7);

    % ------- 3) Tech & economic parameters -------
    project_life_yr      = 15;    % keep same across scripts
    % CAPEX ($/kW or $/kWh)
    cost_PV_per_kW       = 1500;
    cost_Wind_per_kW     = 2000;
    cost_VRFB_per_kWh    = 400;
    cost_VRFB_per_kW     = 300;
    cost_AA_per_kWh      = 50;
    cost_AA_per_kW       = 700;
    cost_Diesel_per_kW   = 700;
    % O&M (fraction of relevant capex per year)
    OMfrac_PV     = 0.02; OMfrac_Wind   = 0.03;
    OMfrac_VRFB   = 0.02; OMfrac_AA     = 0.02;
    OMfrac_Diesel = 0.05;
    % Diesel fuel
    eta_diesel     = 0.40;              % electrical efficiency
    kWh_per_L_fuel = 9.0*eta_diesel;    % ≈3.6 kWh_e/L at 40%
    fuel_USD_per_L = 1.2;

    % ------- 4) Chronological dispatch (Δt = 1 h) -------
    H = numel(P_load);                  % allow non-8760 if needed
    socV = 0.5*VE_kWh;  socA = 0.5*AE_kWh;
    diesel_kWh = 0;  unserved_kWh = 0;
% Storage efficiencies (round-trip split)
etaV_ch  = 0.95;  etaV_dis = 0.95;   % VRFB
etaA_ch  = 0.85;  etaA_dis = 0.65;   % AACAES (tune to design)
curtail_kWh = 0;

    
    for t = 1:H
        PV_gen  = PV_kW * GHI(t);             % kW
        wind_cf = min(1, wind_speed(t)/12);   % simple CF to 12 m/s
        W_gen   = Wind_kW * wind_cf;          % kW
        renew   = PV_gen + W_gen;
        loadt   = P_load(t);

        if renew >= loadt
            surplus = renew - loadt;
            dV = min([surplus, VP_kW, (VE_kWh - socV)]);
            socV = socV + dV;  surplus = surplus - dV;

            dA = min([surplus, AP_kW, (AE_kWh - socA)]);
            socA = socA + dA;  surplus = surplus - dA;
            % curtail any remaining surplus
        else
            deficit = loadt - renew;

            dV = min([deficit, VP_kW, socV]);
            socV = socV - dV;  deficit = deficit - dV;

            dA = min([deficit, AP_kW, socA]);
            socA = socA - dA;  deficit = deficit - dA;

            if deficit > 0
                dD = min([deficit, Diesel_kW]);
                diesel_kWh = diesel_kWh + dD;
                deficit = deficit - dD;
            end
            if deficit > 1e-6
                unserved_kWh = unserved_kWh + deficit;   % should not occur
            end
        end
    end

    % ------- 5) Objectives -------
    diesel_frac = diesel_kWh / total_d_kWh;

    capex = PV_kW*cost_PV_per_kW + Wind_kW*cost_Wind_per_kW ...
          + VE_kWh*cost_VRFB_per_kWh + VP_kW*cost_VRFB_per_kW ...
          + AE_kWh*cost_AA_per_kWh   + AP_kW*cost_AA_per_kW ...
          + Diesel_kW*cost_Diesel_per_kW;

    % Annualize CAPEX: use CRF if 'discount_rate' exists in base; else straight-line
    ann_capex = [];
    if evalin('base','exist(''discount_rate'',''var'')')
        r = evalin('base','discount_rate');
        if ~isempty(r) && r > 0
            CRF = r*(1+r)^project_life_yr / ((1+r)^project_life_yr - 1);
            ann_capex = capex * CRF;   % standard capital recovery factor
        end
    end
    if isempty(ann_capex), ann_capex = capex / project_life_yr; end  % fallback

    ann_OM = OMfrac_PV*(PV_kW*cost_PV_per_kW) ...
           + OMfrac_Wind*(Wind_kW*cost_Wind_per_kW) ...
           + OMfrac_VRFB*(VE_kWh*cost_VRFB_per_kWh + VP_kW*cost_VRFB_per_kW) ...
           + OMfrac_AA*(AE_kWh*cost_AA_per_kWh + AP_kW*cost_AA_per_kW) ...
           + OMfrac_Diesel*(Diesel_kW*cost_Diesel_per_kW);

    fuel_L   = diesel_kWh / kWh_per_L_fuel;
    fuel_cost = fuel_L * fuel_USD_per_L;

    annual_total_cost = ann_capex + ann_OM + fuel_cost;
    alpha_curtail = 0.005;  % $/kWh (e.g., $5/MWh). Tune in sensitivity.
    annual_total_cost = annual_total_cost + alpha_curtail * curtail_kWh;

    % Hard penalty for any unmet load (keeps NGPM in feasible region)
    if unserved_kWh > 1e-6
        annual_total_cost = annual_total_cost + 1e9*(1+unserved_kWh);
        diesel_frac = 1;
    end

    y    = [annual_total_cost, diesel_frac];
    cons = [];   % explicit constraints not used (penalty handles feasibility)
end
